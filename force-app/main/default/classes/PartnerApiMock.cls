/**
 * Multi-response HttpCalloutMock that routes token calls and API calls to separate queues.
 *
 * Responses are consumed in order; the last response of each queue repeats, which keeps "always
 * fails" scenarios short to write. Every request is recorded for header and body assertions.
 *
 * @example
 * PartnerApiMock mock = new PartnerApiMock()
 *     .token('tok-1', 3600)
 *     .api(401, '{"error":"invalid_token"}')
 *     .api(202, TestDataFactory.submitBody('job-1'));
 * Test.setMock(HttpCalloutMock.class, mock);
 */
@IsTest
public class PartnerApiMock implements HttpCalloutMock {
    private final List<Stub> tokenStubs = new List<Stub>();
    private final List<Stub> apiStubs = new List<Stub>();
    public final List<HttpRequest> tokenRequests = new List<HttpRequest>();
    public final List<HttpRequest> apiRequests = new List<HttpRequest>();

    /**
     * @param accessToken Token to return
     * @param expiresIn Lifetime in seconds
     * @return this mock
     */
    public PartnerApiMock token(String accessToken, Integer expiresIn) {
        tokenStubs.add(new Stub(200, TestDataFactory.tokenBody(accessToken, expiresIn), null, false));
        return this;
    }

    /**
     * @param statusCode Status returned by the token endpoint
     * @param body Body returned by the token endpoint
     * @return this mock
     */
    public PartnerApiMock tokenResponse(Integer statusCode, String body) {
        tokenStubs.add(new Stub(statusCode, body, null, false));
        return this;
    }

    /**
     * @return this mock; the next token call throws CalloutException
     */
    public PartnerApiMock tokenTimeout() {
        tokenStubs.add(new Stub(null, null, null, true));
        return this;
    }

    /**
     * @param statusCode API status code
     * @param body API body
     * @return this mock
     */
    public PartnerApiMock api(Integer statusCode, String body) {
        return api(statusCode, body, null);
    }

    /**
     * @param statusCode API status code
     * @param body API body
     * @param headers Response headers, for example Retry-After
     * @return this mock
     */
    public PartnerApiMock api(Integer statusCode, String body, Map<String, String> headers) {
        apiStubs.add(new Stub(statusCode, body, headers, false));
        return this;
    }

    /**
     * @return this mock; the next API call throws CalloutException
     */
    public PartnerApiMock apiTimeout() {
        apiStubs.add(new Stub(null, null, null, true));
        return this;
    }

    /**
     * @param request Outgoing request
     * @return Next stubbed response for the request's route
     */
    public HttpResponse respond(HttpRequest request) {
        Boolean isTokenCall = request.getEndpoint().startsWith(OAuthTokenService.TOKEN_ENDPOINT);
        List<Stub> stubs;
        if (isTokenCall) {
            tokenRequests.add(request);
            stubs = tokenStubs;
        } else {
            apiRequests.add(request);
            stubs = apiStubs;
        }
        if (stubs.isEmpty()) {
            throw new CalloutException('PartnerApiMock has no response for ' + request.getEndpoint());
        }
        Stub next = stubs.size() > 1 ? stubs.remove(0) : stubs[0];
        if (next.simulateTimeout) {
            throw new CalloutException('Read timed out');
        }
        HttpResponse response = new HttpResponse();
        response.setStatusCode(next.statusCode);
        if (next.body != null) {
            response.setBody(next.body);
        }
        if (next.headers != null) {
            for (String name : next.headers.keySet()) {
                response.setHeader(name, next.headers.get(name));
            }
        }
        return response;
    }

    private class Stub {
        public Integer statusCode;
        public String body;
        public Map<String, String> headers;
        public Boolean simulateTimeout;

        public Stub(Integer statusCode, String body, Map<String, String> headers, Boolean simulateTimeout) {
            this.statusCode = statusCode;
            this.body = body;
            this.headers = headers;
            this.simulateTimeout = simulateTimeout;
        }
    }
}
