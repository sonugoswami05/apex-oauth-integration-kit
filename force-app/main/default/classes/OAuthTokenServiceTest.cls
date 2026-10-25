@IsTest
private class OAuthTokenServiceTest {
    private static String cachedEntry(String token, Long expiresAtMillis) {
        return JSON.serialize(new OAuthTokenService.CachedToken(token, expiresAtMillis));
    }

    @IsTest
    static void shouldRequestAndCacheTokenWhenCacheIsEmpty() {
        PartnerApiMock mock = new PartnerApiMock().token('fresh-token', 3600);
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();

        Test.startTest();
        String token = new OAuthTokenService(cache).getAccessToken();
        Test.stopTest();

        Assert.areEqual('fresh-token', token, 'Token from the authorization server');
        Assert.areEqual(1, mock.tokenRequests.size(), 'One token request');
        Assert.areEqual(3600 - OAuthTokenService.EXPIRY_SKEW_SECONDS, cache.ttls.get(OAuthTokenService.CACHE_KEY), 'Cache TTL is expiry minus skew');
        HttpRequest sent = mock.tokenRequests[0];
        Assert.areEqual('POST', sent.getMethod(), 'Method');
        Assert.isTrue(sent.getBody().contains('grant_type=client_credentials'), 'Client credentials grant');
        Assert.isTrue(sent.getBody().contains('{!$Credential.PartnerAuth.ClientSecret}'), 'Secret is a merge field, never a literal');
    }

    @IsTest
    static void shouldSkipCalloutWhenCachedTokenIsValid() {
        PartnerApiMock mock = new PartnerApiMock().token('unused', 3600);
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();
        cache.values.put(OAuthTokenService.CACHE_KEY, cachedEntry('cached-token', System.currentTimeMillis() + 600000));

        Test.startTest();
        String token = new OAuthTokenService(cache).getAccessToken();
        Test.stopTest();

        Assert.areEqual('cached-token', token, 'Cached token returned');
        Assert.areEqual(0, mock.tokenRequests.size(), 'Cache hit makes no callout');
    }

    @IsTest
    static void shouldRefreshWhenCachedTokenIsInsideSkewWindow() {
        PartnerApiMock mock = new PartnerApiMock().token('fresh-token', 3600);
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();
        Long almostExpired = System.currentTimeMillis() + (OAuthTokenService.EXPIRY_SKEW_SECONDS - 10) * 1000L;
        cache.values.put(OAuthTokenService.CACHE_KEY, cachedEntry('stale-token', almostExpired));

        Test.startTest();
        String token = new OAuthTokenService(cache).getAccessToken();
        Test.stopTest();

        Assert.areEqual('fresh-token', token, 'Tokens about to expire are replaced');
        Assert.areEqual(1, mock.tokenRequests.size(), 'One token request');
    }

    @IsTest
    static void shouldReuseTransactionTokenWhenCalledTwice() {
        PartnerApiMock mock = new PartnerApiMock().token('fresh-token', 3600);
        Test.setMock(HttpCalloutMock.class, mock);
        OAuthTokenService service = new OAuthTokenService(new TestDoubles.InMemoryTokenCache());

        Test.startTest();
        service.getAccessToken();
        String second = service.getAccessToken();
        Test.stopTest();

        Assert.areEqual('fresh-token', second, 'Same token');
        Assert.areEqual(1, mock.tokenRequests.size(), 'Second call served from the transaction cache');
    }

    @IsTest
    static void shouldFallBackWhenPlatformCacheIsUnavailable() {
        PartnerApiMock mock = new PartnerApiMock().token('fresh-token', 3600);
        Test.setMock(HttpCalloutMock.class, mock);
        OAuthTokenService service = new OAuthTokenService(new PlatformCacheTokenCache('local.NoSuchPartition'));

        Test.startTest();
        String first = service.getAccessToken();
        String second = service.getAccessToken();
        Test.stopTest();

        Assert.areEqual('fresh-token', first, 'Token still issued without a cache');
        Assert.areEqual(first, second, 'Transaction copy reused');
        Assert.areEqual(1, mock.tokenRequests.size(), 'Only one token request despite the cache outage');
    }

    @IsTest
    static void shouldTreatCorruptEntryAsMissWhenCacheHoldsBadJson() {
        PartnerApiMock mock = new PartnerApiMock().token('fresh-token', 3600);
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();
        cache.values.put(OAuthTokenService.CACHE_KEY, '{not json');

        Test.startTest();
        String token = new OAuthTokenService(cache).getAccessToken();
        Test.stopTest();

        Assert.areEqual('fresh-token', token, 'Corrupt entry replaced');
        Assert.isTrue(cache.removals >= 1, 'Corrupt entry evicted');
    }

    @IsTest
    static void shouldDefaultLifetimeWhenExpiresInIsMissing() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('fresh-token', null));
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();

        Test.startTest();
        new OAuthTokenService(cache).getAccessToken();
        Test.stopTest();

        Integer expectedTtl = OAuthTokenService.DEFAULT_EXPIRES_IN_SECONDS - OAuthTokenService.EXPIRY_SKEW_SECONDS;
        Assert.areEqual(expectedTtl, cache.ttls.get(OAuthTokenService.CACHE_KEY), 'Default lifetime applied');
    }

    @IsTest
    static void shouldNotCacheWhenTokenLifetimeIsShorterThanSkew() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('short-token', 30));
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();

        Test.startTest();
        String token = new OAuthTokenService(cache).getAccessToken();
        Test.stopTest();

        Assert.areEqual('short-token', token, 'Token still returned for this call');
        Assert.isFalse(cache.values.containsKey(OAuthTokenService.CACHE_KEY), 'Nothing cached when TTL would be negative');
    }

    @IsTest
    static void shouldEvictEverywhereWhenInvalidated() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('first-token', 3600).token('second-token', 3600));
        TestDoubles.InMemoryTokenCache cache = new TestDoubles.InMemoryTokenCache();
        OAuthTokenService service = new OAuthTokenService(cache);

        Test.startTest();
        service.getAccessToken();
        service.invalidate();
        String afterInvalidate = service.getAccessToken();
        Test.stopTest();

        Assert.areEqual('second-token', afterInvalidate, 'A new token is requested after invalidation');
        Assert.areEqual(1, cache.removals, 'Cache entry removed');
    }

    @IsTest
    static void shouldThrowNonRetryableWhenClientIsRejected() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().tokenResponse(401, '{"error":"invalid_client"}'));

        Test.startTest();
        try {
            new OAuthTokenService(new TestDoubles.InMemoryTokenCache()).getAccessToken();
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(401, expected.getStatusCode(), 'Status code');
            Assert.isFalse(expected.isRetryable(), 'Bad credentials do not fix themselves');
            Assert.isNotNull(expected.getCorrelationId(), 'Correlation id attached');
            Assert.isFalse(expected.toSafeMessage().contains('invalid_client'), 'Response body is not echoed');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowRetryableWhenAuthServerIsDown() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().tokenResponse(503, ''));

        Test.startTest();
        try {
            new OAuthTokenService(new TestDoubles.InMemoryTokenCache()).getAccessToken();
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(503, expected.getStatusCode(), 'Status code');
            Assert.isTrue(expected.isRetryable(), '503 is transient');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowRetryableWhenTokenCallTimesOut() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().tokenTimeout());

        Test.startTest();
        try {
            new OAuthTokenService(new TestDoubles.InMemoryTokenCache()).getAccessToken();
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(0, expected.getStatusCode(), 'No response received');
            Assert.isTrue(expected.isRetryable(), 'Timeouts are transient');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowWhenAccessTokenIsMissing() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().tokenResponse(200, '{"token_type":"Bearer"}'));

        Test.startTest();
        try {
            new OAuthTokenService(new TestDoubles.InMemoryTokenCache()).getAccessToken();
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.isTrue(expected.getMessage().contains('access_token'), 'Message explains the problem');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowWhenTokenResponseIsNotJson() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().tokenResponse(200, '<html>login</html>'));

        Test.startTest();
        try {
            new OAuthTokenService(new TestDoubles.InMemoryTokenCache()).getAccessToken();
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.isNotNull(expected.getCause(), 'Parse error kept as the cause');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowWhenTokenResponseIsAJsonArray() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().tokenResponse(200, '["not","an","object"]'));

        Test.startTest();
        try {
            new OAuthTokenService(new TestDoubles.InMemoryTokenCache()).getAccessToken();
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(200, expected.getStatusCode(), 'Status recorded');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldUsePlatformCacheWhenConstructedWithDefaults() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('fresh-token', 3600));

        Test.startTest();
        String token = new OAuthTokenService().getAccessToken();
        String fromNullCache = new OAuthTokenService(null).getAccessToken();
        Test.stopTest();

        Assert.areEqual('fresh-token', token, 'Default wiring works');
        Assert.areEqual(token, fromNullCache, 'Null cache falls back to the default cache');
    }

    @IsTest
    static void shouldMaskSecretsWhenFormattingForLogs() {
        Assert.areEqual('(empty)', IntegrationLog.mask(null), 'Blank');
        Assert.areEqual('****', IntegrationLog.mask('short'), 'Short values fully hidden');
        Assert.areEqual('****wxyz (26 chars)', IntegrationLog.mask('abcdefghijklmnopqrstuvwxyz'), 'Only the last four characters shown');
        Assert.areEqual(36, IntegrationLog.newCorrelationId().length(), 'UUID-shaped correlation id');
    }
}
