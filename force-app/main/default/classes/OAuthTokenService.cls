/**
 * Obtains OAuth 2.0 access tokens from the partner's authorization server using the client
 * credentials grant, and caches them so most transactions never call the token endpoint.
 *
 * Lookup order:
 *   1. Token already resolved in this transaction (static, survives cache outages)
 *   2. Org Platform Cache (shared across transactions and users)
 *   3. New token request through the PartnerAuth Named Credential
 *
 * A token counts as usable only until (expiry - EXPIRY_SKEW_SECONDS), so a request never leaves
 * Salesforce with a token that expires mid-flight. Client id and secret live in the PartnerAuth
 * External Credential and reach the wire only through merge fields; Apex never reads them.
 *
 * @example
 * String bearer = new OAuthTokenService().getAccessToken();
 */
public with sharing class OAuthTokenService {
    public static final String TOKEN_ENDPOINT = 'callout:PartnerAuth/oauth/token';
    @TestVisible
    private static final String CACHE_KEY = 'partnerApiAccessToken';
    @TestVisible
    private static final Integer EXPIRY_SKEW_SECONDS = 60;
    @TestVisible
    private static final Integer DEFAULT_EXPIRES_IN_SECONDS = 3600;
    private static final Integer TOKEN_TIMEOUT_MS = 10000;
    private static final String TOKEN_REQUEST_BODY = 'grant_type=client_credentials'
        + '&client_id={!$Credential.PartnerAuth.ClientId}'
        + '&client_secret={!$Credential.PartnerAuth.ClientSecret}';

    private static CachedToken transactionToken;

    private final TokenCache cache;

    /**
     * Uses the Org Platform Cache partition local.IntegrationCache.
     */
    public OAuthTokenService() {
        this(new PlatformCacheTokenCache());
    }

    /**
     * Creates the service with a specific cache implementation.
     *
     * @param cache Cache implementation; pass a test double in unit tests
     */
    public OAuthTokenService(TokenCache cache) {
        this.cache = cache == null ? new PlatformCacheTokenCache() : cache;
    }

    /**
     * Returns a usable access token, requesting a new one only when no cached token is valid.
     *
     * @return Bearer token value
     * @throws PartnerApiException When the authorization server rejects or fails the request
     */
    public String getAccessToken() {
        Long nowMillis = System.currentTimeMillis();
        if (transactionToken != null && transactionToken.isUsableAt(nowMillis)) {
            return transactionToken.accessToken;
        }
        CachedToken cached = readCache();
        if (cached != null && cached.isUsableAt(nowMillis)) {
            transactionToken = cached;
            return cached.accessToken;
        }
        return refresh();
    }

    /**
     * Forces a new token request and stores the result in both cache layers.
     *
     * @return Fresh bearer token value
     * @throws PartnerApiException When the authorization server rejects or fails the request
     */
    public String refresh() {
        TokenGrant grant = requestToken();
        Long nowMillis = System.currentTimeMillis();
        CachedToken fresh = new CachedToken(grant.accessToken, nowMillis + grant.expiresInSeconds * 1000L);
        transactionToken = fresh;
        Integer ttlSeconds = grant.expiresInSeconds - EXPIRY_SKEW_SECONDS;
        if (ttlSeconds > 0) {
            cache.put(CACHE_KEY, JSON.serialize(fresh), ttlSeconds);
        }
        return fresh.accessToken;
    }

    /**
     * Drops the current token everywhere. Call this when the partner answers 401 so the next
     * getAccessToken() requests a new token instead of reusing a revoked one.
     */
    public void invalidate() {
        if (transactionToken != null) {
            IntegrationLog.warn('Invalidating access token ' + IntegrationLog.mask(transactionToken.accessToken));
        }
        transactionToken = null;
        cache.remove(CACHE_KEY);
    }

    private CachedToken readCache() {
        String serialized = cache.get(CACHE_KEY);
        if (String.isBlank(serialized)) {
            return null;
        }
        try {
            return (CachedToken) JSON.deserialize(serialized, CachedToken.class);
        } catch (JSONException parseError) {
            // A shape change after a deploy must not break callouts; treat it as a miss.
            cache.remove(CACHE_KEY);
            return null;
        }
    }

    private TokenGrant requestToken() {
        String correlationId = IntegrationLog.newCorrelationId();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(TOKEN_ENDPOINT);
        request.setMethod('POST');
        request.setTimeout(TOKEN_TIMEOUT_MS);
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        request.setHeader('Accept', 'application/json');
        request.setHeader('X-Correlation-Id', correlationId);
        request.setBody(TOKEN_REQUEST_BODY);

        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException calloutError) {
            throw new PartnerApiException('Token request failed before a response was received.', calloutError)
                .withCorrelationId(correlationId)
                .markRetryable(null);
        }

        Integer statusCode = response.getStatusCode();
        if (statusCode != 200) {
            PartnerApiException rejected = new PartnerApiException('Authorization server rejected the token request.')
                .withStatus(statusCode)
                .withCorrelationId(correlationId);
            if (statusCode == 429 || statusCode >= 500) {
                rejected.markRetryable(null);
            }
            throw rejected;
        }
        return parseGrant(response.getBody(), correlationId);
    }

    private static TokenGrant parseGrant(String body, String correlationId) {
        Map<String, Object> fields;
        try {
            fields = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (JSONException parseError) {
            throw invalidTokenResponse(correlationId, parseError);
        } catch (TypeException shapeError) {
            throw invalidTokenResponse(correlationId, shapeError);
        }
        Object accessToken = fields?.get('access_token');
        if (!(accessToken instanceof String) || String.isBlank((String) accessToken)) {
            throw invalidTokenResponse(correlationId, null);
        }
        TokenGrant grant = new TokenGrant();
        grant.accessToken = (String) accessToken;
        grant.expiresInSeconds = toPositiveInteger(fields.get('expires_in'), DEFAULT_EXPIRES_IN_SECONDS);
        return grant;
    }

    private static PartnerApiException invalidTokenResponse(String correlationId, Exception cause) {
        String message = 'Authorization server returned a response without a usable access_token.';
        PartnerApiException error = cause == null ? new PartnerApiException(message) : new PartnerApiException(message, cause);
        return error.withStatus(200).withCorrelationId(correlationId);
    }

    private static Integer toPositiveInteger(Object value, Integer fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            Integer parsed = Decimal.valueOf(String.valueOf(value)).intValue();
            return parsed > 0 ? parsed : fallback;
        } catch (TypeException notNumeric) {
            return fallback;
        }
    }

    /**
     * Serializable token entry stored in Platform Cache.
     */
    public class CachedToken {
        public String accessToken;
        public Long expiresAtMillis;

        /**
         * No-arg constructor used by JSON deserialization.
         */
        public CachedToken() {
            this(null, null);
        }

        /**
         * Creates a cache entry.
         *
         * @param accessToken Bearer token value
         * @param expiresAtMillis Absolute expiry in epoch milliseconds
         */
        public CachedToken(String accessToken, Long expiresAtMillis) {
            this.accessToken = accessToken;
            this.expiresAtMillis = expiresAtMillis;
        }

        /**
         * Checks the token against its expiry minus the safety skew.
         *
         * @param nowMillis Current epoch milliseconds
         * @return True while the token is outside the expiry safety window
         */
        public Boolean isUsableAt(Long nowMillis) {
            return String.isNotBlank(accessToken)
                && expiresAtMillis != null
                && nowMillis < expiresAtMillis - EXPIRY_SKEW_SECONDS * 1000L;
        }
    }

    private class TokenGrant {
        public String accessToken;
        public Integer expiresInSeconds;
    }
}
