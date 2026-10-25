/**
 * Thin HTTP client for the partner document generation API.
 *
 * Every call:
 * - goes through the PartnerApi Named Credential (no hard-coded hosts or secrets)
 * - carries a bearer token from OAuthTokenService and an X-Correlation-Id header
 * - refreshes the token once and replays the request when the partner answers 401
 * - retries 429/5xx/transport failures under a bounded RetryPolicy that honors Retry-After
 * - fails with a typed PartnerApiException (status code, correlation id, retryable flag)
 *
 * @example
 * PartnerApiClient client = new PartnerApiClient();
 * PartnerApiModels.StatusResponse status = client.getGenerationStatus('job-123');
 */
public with sharing class PartnerApiClient {
    public static final String BASE_ENDPOINT = 'callout:PartnerApi';
    @TestVisible
    private static final String SUBMIT_PATH = '/v1/documents/generate';
    @TestVisible
    private static final String STATUS_PATH = '/v1/documents/jobs/';
    private static final String CORRELATION_HEADER = 'X-Correlation-Id';
    private static final String RETRY_AFTER_HEADER = 'Retry-After';
    private static final Integer DEFAULT_TIMEOUT_MS = 20000;
    private static final Integer MAX_TIMEOUT_MS = 120000;
    private static final Integer MAX_ERROR_DETAIL_LENGTH = 300;

    private final OAuthTokenService tokenService;
    private final RetryPolicy retryPolicy;
    private final Sleeper sleeper;
    private Integer timeoutMs = DEFAULT_TIMEOUT_MS;

    /**
     * Production wiring: Platform Cache backed tokens, default retry policy, CPU-bounded waits.
     */
    public PartnerApiClient() {
        this(new OAuthTokenService(), RetryPolicy.defaults(), new CpuBoundedSleeper());
    }

    /**
     * Creates a client with explicit collaborators. Null arguments fall back to the defaults.
     *
     * @param tokenService Source of bearer tokens
     * @param retryPolicy Retry rules
     * @param sleeper Strategy used to wait between inline retries
     */
    public PartnerApiClient(OAuthTokenService tokenService, RetryPolicy retryPolicy, Sleeper sleeper) {
        this.tokenService = tokenService == null ? new OAuthTokenService() : tokenService;
        this.retryPolicy = retryPolicy == null ? RetryPolicy.defaults() : retryPolicy;
        this.sleeper = sleeper == null ? new CpuBoundedSleeper() : sleeper;
    }

    /**
     * Overrides the per-request timeout (default 20 seconds).
     *
     * @param timeoutMs Per-request timeout in milliseconds (1 to 120000)
     * @return this client, for chaining
     */
    public PartnerApiClient withTimeout(Integer timeoutMs) {
        if (timeoutMs == null || timeoutMs < 1 || timeoutMs > MAX_TIMEOUT_MS) {
            throw new IllegalArgumentException('timeoutMs must be between 1 and ' + MAX_TIMEOUT_MS + '.');
        }
        this.timeoutMs = timeoutMs;
        return this;
    }

    /**
     * Submits a document generation job.
     *
     * @param request Template, format and merge data
     * @param idempotencyKey Stable key for this logical submit so replays never create duplicates
     * @return Partner job id and initial status
     * @throws PartnerApiException On any non-2xx outcome or an unusable response body
     */
    public PartnerApiModels.SubmitResponse submitGeneration(PartnerApiModels.GenerationRequest request, String idempotencyKey) {
        if (request == null) {
            throw new IllegalArgumentException('request is required.');
        }
        Map<String, String> headers = new Map<String, String>();
        if (String.isNotBlank(idempotencyKey)) {
            headers.put('Idempotency-Key', idempotencyKey);
        }
        ApiResponse response = send('POST', SUBMIT_PATH, JSON.serialize(request, true), headers);
        PartnerApiModels.SubmitResponse parsed = (PartnerApiModels.SubmitResponse) parseBody(response, PartnerApiModels.SubmitResponse.class);
        if (String.isBlank(parsed.jobId)) {
            throw new PartnerApiException('Partner API accepted the request but returned no jobId.')
                .withStatus(response.statusCode)
                .withCorrelationId(response.correlationId);
        }
        parsed.correlationId = response.correlationId;
        return parsed;
    }

    /**
     * Reads the status of a generation job.
     *
     * @param jobId Partner job id returned by submitGeneration
     * @return Current job status
     * @throws PartnerApiException On any non-2xx outcome or an unusable response body
     */
    public PartnerApiModels.StatusResponse getGenerationStatus(String jobId) {
        if (String.isBlank(jobId)) {
            throw new IllegalArgumentException('jobId is required.');
        }
        ApiResponse response = send('GET', STATUS_PATH + EncodingUtil.urlEncode(jobId, 'UTF-8'), null, null);
        PartnerApiModels.StatusResponse parsed = (PartnerApiModels.StatusResponse) parseBody(response, PartnerApiModels.StatusResponse.class);
        parsed.correlationId = response.correlationId;
        return parsed;
    }

    /**
     * Sends any request to the partner API with auth, retries and error mapping applied.
     * Use it for endpoints that do not have a typed method yet.
     *
     * @param method HTTP method, for example GET or POST
     * @param path Path below the Named Credential base URL, starting with /
     * @param body JSON body, or null
     * @param extraHeaders Additional headers, or null
     * @return Successful (2xx) response
     * @throws PartnerApiException When the call fails after the retry budget is spent
     */
    public ApiResponse send(String method, String path, String body, Map<String, String> extraHeaders) {
        CallState call = new CallState(method, path, body, extraHeaders);
        // Hard ceiling: every retryable attempt plus one replay after a token refresh.
        Integer maxRoundTrips = retryPolicy.maxAttempts + 1;
        for (Integer roundTrip = 0; roundTrip < maxRoundTrips; roundTrip++) {
            HttpResponse response = transmit(call);
            if (isSuccess(response)) {
                return new ApiResponse(response.getStatusCode(), response.getBody(), call.correlationId, call.attempt);
            }
            if (!refreshTokenOnce(response, call)) {
                waitBeforeRetry(response, call);
            }
        }
        throw new PartnerApiException('Partner API retry budget exhausted.').withCorrelationId(call.correlationId);
    }

    private HttpResponse transmit(CallState call) {
        call.transportError = null;
        try {
            return new Http().send(buildRequest(call));
        } catch (CalloutException calloutError) {
            call.transportError = calloutError;
            return null;
        }
    }

    private static Boolean isSuccess(HttpResponse response) {
        return response != null && response.getStatusCode() >= 200 && response.getStatusCode() < 300;
    }

    /**
     * A 401 usually means the cached token was revoked or rotated early. Drop it and replay once.
     *
     * @param response Response of the last attempt, or null after a transport failure
     * @param call State of the current call
     * @return True when the token was dropped and the request should be replayed
     */
    private Boolean refreshTokenOnce(HttpResponse response, CallState call) {
        if (response == null || response.getStatusCode() != 401 || call.tokenRefreshed) {
            return false;
        }
        call.tokenRefreshed = true;
        tokenService.invalidate();
        return true;
    }

    /**
     * Throws when the failure is final or the wait does not fit this transaction; otherwise waits
     * and advances the attempt counter.
     *
     * @param response Response of the last attempt, or null after a transport failure
     * @param call State of the current call
     */
    private void waitBeforeRetry(HttpResponse response, CallState call) {
        PartnerApiException failure;
        if (response == null) {
            failure = new PartnerApiException('Partner API call failed before a response was received.', call.transportError)
                .withCorrelationId(call.correlationId);
        } else {
            failure = toException(response, call.correlationId);
            if (!retryPolicy.isRetryableStatus(response.getStatusCode())) {
                throw failure;
            }
        }
        Integer delayMs = retryPolicy.delayMs(call.attempt, response?.getHeader(RETRY_AFTER_HEADER));
        if (call.attempt >= retryPolicy.maxAttempts || !canWaitInline(delayMs)) {
            throw failure.markRetryable(toWholeSeconds(delayMs));
        }
        sleeper.sleep(delayMs);
        call.attempt++;
    }

    /**
     * The endpoint and the client secret both come from Named/External Credentials. The bearer
     * header is set here only because the token is minted and cached by OAuthTokenService.
     *
     * @param call State of the current call
     * @return Request ready to send
     */
    @SuppressWarnings('PMD.ApexSuggestUsingNamedCred')
    private HttpRequest buildRequest(CallState call) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(BASE_ENDPOINT + call.path);
        request.setMethod(call.method);
        request.setTimeout(timeoutMs);
        request.setHeader('Authorization', 'Bearer ' + tokenService.getAccessToken());
        request.setHeader('Accept', 'application/json');
        request.setHeader(CORRELATION_HEADER, call.correlationId);
        if (call.body != null) {
            request.setHeader('Content-Type', 'application/json');
            request.setBody(call.body);
        }
        if (call.extraHeaders != null) {
            for (String name : call.extraHeaders.keySet()) {
                request.setHeader(name, call.extraHeaders.get(name));
            }
        }
        return request;
    }

    private Boolean canWaitInline(Integer delayMs) {
        Boolean withinBudget = delayMs <= retryPolicy.maxInlineWaitMs;
        Boolean cpuHeadroom = Limits.getCpuTime() + delayMs < Limits.getLimitCpuTime() / 2;
        Boolean calloutHeadroom = Limits.getCallouts() < Limits.getLimitCallouts();
        return withinBudget && cpuHeadroom && calloutHeadroom;
    }

    private static Integer toWholeSeconds(Integer delayMs) {
        return delayMs == null ? null : (delayMs + 999) / 1000;
    }

    private static PartnerApiException toException(HttpResponse response, String correlationId) {
        String detail = extractErrorDetail(response.getBody());
        String message = 'Partner API returned HTTP ' + response.getStatusCode() + (String.isBlank(detail) ? '.' : ': ' + detail);
        return new PartnerApiException(message).withStatus(response.getStatusCode()).withCorrelationId(correlationId);
    }

    private static String extractErrorDetail(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> fields = (Map<String, Object>) parsed;
                Object message = fields.containsKey('message') ? fields.get('message') : fields.get('error');
                return message == null ? null : String.valueOf(message).abbreviate(MAX_ERROR_DETAIL_LENGTH);
            }
        } catch (JSONException notJson) {
            return body.abbreviate(MAX_ERROR_DETAIL_LENGTH);
        }
        return null;
    }

    private static Object parseBody(ApiResponse response, System.Type targetType) {
        if (String.isBlank(response.body)) {
            throw new PartnerApiException('Partner API returned an empty body.')
                .withStatus(response.statusCode)
                .withCorrelationId(response.correlationId);
        }
        try {
            return JSON.deserialize(response.body, targetType);
        } catch (JSONException parseError) {
            throw new PartnerApiException('Partner API returned a body that could not be parsed.', parseError)
                .withStatus(response.statusCode)
                .withCorrelationId(response.correlationId);
        }
    }

    /**
     * Strategy for waiting between inline retries. Tests inject a recorder instead of waiting.
     */
    public interface Sleeper {
        /**
         * Blocks for roughly the given time.
         *
         * @param milliseconds Time to wait
         */
        void sleep(Integer milliseconds);
    }

    /**
     * Apex has no Thread.sleep, so this spins on the clock. RetryPolicy.maxInlineWaitMs and the CPU
     * headroom check in canWaitInline keep the cost small; longer waits are deferred to async jobs.
     */
    public class CpuBoundedSleeper implements Sleeper {
        /**
         * Spins until the deadline passes.
         *
         * @param milliseconds Time to wait
         */
        public void sleep(Integer milliseconds) {
            if (milliseconds == null || milliseconds <= 0) {
                return;
            }
            Long deadline = System.currentTimeMillis() + milliseconds;
            Integer spins = 0;
            while (System.currentTimeMillis() < deadline) {
                spins++;
            }
        }
    }

    /**
     * Mutable state of one logical call across its attempts.
     */
    private class CallState {
        public final String method;
        public final String path;
        public final String body;
        public final Map<String, String> extraHeaders;
        public final String correlationId = IntegrationLog.newCorrelationId();
        public Integer attempt = 1;
        public Boolean tokenRefreshed = false;
        public CalloutException transportError;

        /**
         * Starts a call with a fresh correlation id.
         *
         * @param method HTTP method
         * @param path Path below the Named Credential base URL
         * @param body JSON body, or null
         * @param extraHeaders Additional headers, or null
         */
        public CallState(String method, String path, String body, Map<String, String> extraHeaders) {
            this.method = method;
            this.path = path;
            this.body = body;
            this.extraHeaders = extraHeaders;
        }
    }

    /**
     * Successful partner response.
     */
    public class ApiResponse {
        public Integer statusCode;
        public String body;
        public String correlationId;
        /** Number of attempts it took, 1 when the first call succeeded. */
        public Integer attempts;

        /**
         * Creates a response holder.
         *
         * @param statusCode HTTP status code
         * @param body Raw response body
         * @param correlationId Correlation id sent with the request
         * @param attempts Attempts used
         */
        public ApiResponse(Integer statusCode, String body, String correlationId, Integer attempts) {
            this.statusCode = statusCode;
            this.body = body;
            this.correlationId = correlationId;
            this.attempts = attempts;
        }
    }
}
