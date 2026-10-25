@IsTest
private class PartnerApiClientTest {
    private static PartnerApiModels.GenerationRequest sampleRequest() {
        PartnerApiModels.GenerationRequest request = new PartnerApiModels.GenerationRequest();
        request.templateKey = TestDataFactory.TEMPLATE_KEY;
        request.outputFormat = 'PDF';
        request.schemaVersion = 1;
        request.data = JSON.deserializeUntyped(TestDataFactory.SAMPLE_PAYLOAD);
        return request;
    }

    @IsTest
    static void shouldSendAuthAndCorrelationHeadersWhenSubmitting() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(202, TestDataFactory.submitBody('job-1'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        PartnerApiModels.SubmitResponse response = TestDoubles.client().submitGeneration(sampleRequest(), 'req-1');
        Test.stopTest();

        Assert.areEqual('job-1', response.jobId, 'Job id parsed');
        HttpRequest sent = mock.apiRequests[0];
        Assert.areEqual(PartnerApiClient.BASE_ENDPOINT + PartnerApiClient.SUBMIT_PATH, sent.getEndpoint(), 'Endpoint uses the Named Credential');
        Assert.areEqual('Bearer tok-1', sent.getHeader('Authorization'), 'Bearer token');
        Assert.areEqual('req-1', sent.getHeader('Idempotency-Key'), 'Idempotency key');
        Assert.areEqual(response.correlationId, sent.getHeader('X-Correlation-Id'), 'Correlation id echoed to caller');
        Assert.isTrue(sent.getBody().contains('"templateKey":"engagement-letter"'), 'Typed DTO serialized');
        Assert.isFalse(sent.getBody().contains('"externalReference"'), 'Null fields suppressed');
    }

    @IsTest
    static void shouldRefreshTokenOnceWhenPartnerReturns401() {
        PartnerApiMock mock = new PartnerApiMock()
            .token('expired-token', 3600)
            .token('fresh-token', 3600)
            .api(401, '{"error":"invalid_token"}')
            .api(202, TestDataFactory.submitBody('job-2'));
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.RecordingSleeper sleeper = new TestDoubles.RecordingSleeper();

        Test.startTest();
        PartnerApiModels.SubmitResponse response = TestDoubles.client(new TestDoubles.InMemoryTokenCache(), sleeper).submitGeneration(sampleRequest(), null);
        Test.stopTest();

        Assert.areEqual('job-2', response.jobId, 'Replayed request succeeded');
        Assert.areEqual(2, mock.tokenRequests.size(), 'Token refreshed exactly once');
        Assert.areEqual('Bearer fresh-token', mock.apiRequests[1].getHeader('Authorization'), 'Replay uses the new token');
        Assert.isTrue(sleeper.delays.isEmpty(), 'A token refresh does not wait');
        Assert.isNull(mock.apiRequests[0].getHeader('Idempotency-Key'), 'Blank idempotency key is not sent');
    }

    @IsTest
    static void shouldThrow401WhenRefreshedTokenIsAlsoRejected() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).token('tok-2', 3600).api(401, '{"error":"invalid_token"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            TestDoubles.client().getGenerationStatus('job-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(401, expected.getStatusCode(), 'Status code');
            Assert.isFalse(expected.isRetryable(), 'Second 401 is final');
        }
        Test.stopTest();

        Assert.areEqual(2, mock.apiRequests.size(), 'Original call plus one replay');
        Assert.areEqual(2, mock.tokenRequests.size(), 'Only one refresh');
    }

    @IsTest
    static void shouldWaitAndRetryWhenRetryAfterFitsInlineBudget() {
        PartnerApiMock mock = new PartnerApiMock()
            .token('tok-1', 3600)
            .api(429, '{"message":"slow down"}', new Map<String, String>{ 'Retry-After' => '1' })
            .api(200, TestDataFactory.statusBody('job-1', 'PROCESSING'));
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.RecordingSleeper sleeper = new TestDoubles.RecordingSleeper();

        Test.startTest();
        PartnerApiModels.StatusResponse status = TestDoubles.client(new TestDoubles.InMemoryTokenCache(), sleeper).getGenerationStatus('job-1');
        Test.stopTest();

        Assert.areEqual('PROCESSING', status.status, 'Second attempt succeeded');
        Assert.areEqual(new List<Integer>{ 1000 }, sleeper.delays, 'Waited exactly what Retry-After asked for');
    }

    @IsTest
    static void shouldDeferToCallerWhenRetryAfterExceedsInlineBudget() {
        PartnerApiMock mock = new PartnerApiMock()
            .token('tok-1', 3600)
            .api(429, '{"message":"quota exceeded"}', new Map<String, String>{ 'Retry-After' => '120' });
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.RecordingSleeper sleeper = new TestDoubles.RecordingSleeper();

        Test.startTest();
        try {
            TestDoubles.client(new TestDoubles.InMemoryTokenCache(), sleeper).getGenerationStatus('job-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(429, expected.getStatusCode(), 'Status code');
            Assert.isTrue(expected.isRetryable(), 'Caller may retry later');
            Assert.areEqual(120, expected.getRetryAfterSeconds(), 'Retry-After passed through');
            Assert.isTrue(expected.getMessage().contains('quota exceeded'), 'Partner message included');
        }
        Test.stopTest();

        Assert.areEqual(1, mock.apiRequests.size(), 'No inline retry for long waits');
        Assert.isTrue(sleeper.delays.isEmpty(), 'Did not burn CPU waiting');
    }

    @IsTest
    static void shouldBackOffThenGiveUpWhenServerErrorPersists() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(500, '{"error":"internal"}');
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.RecordingSleeper sleeper = new TestDoubles.RecordingSleeper();
        RetryPolicy policy = TestDoubles.fastPolicy();

        Test.startTest();
        try {
            TestDoubles.client(new TestDoubles.InMemoryTokenCache(), sleeper).getGenerationStatus('job-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(500, expected.getStatusCode(), 'Status code');
            Assert.isTrue(expected.isRetryable(), 'Still transient, an async caller may try again');
            Assert.isTrue(expected.toSafeMessage().contains('[HTTP 500]'), 'Safe message has the status');
        }
        Test.stopTest();

        Assert.areEqual(policy.maxAttempts, mock.apiRequests.size(), 'Bounded by maxAttempts');
        Assert.areEqual(new List<Integer>{ 100, 200 }, sleeper.delays, 'Exponential backoff between attempts');
    }

    @IsTest
    static void shouldRecoverWhenServiceUnavailableIsTransient() {
        PartnerApiMock mock = new PartnerApiMock()
            .token('tok-1', 3600)
            .api(503, '')
            .api(200, TestDataFactory.statusBody('job-1', 'COMPLETE'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        PartnerApiModels.StatusResponse status = TestDoubles.client().getGenerationStatus('job-1');
        Test.stopTest();

        Assert.isTrue(status.isComplete(), 'Completed after one retry');
        Assert.areEqual(2, mock.apiRequests.size(), 'Two attempts');
    }

    @IsTest
    static void shouldRetryWhenCalloutTimesOut() {
        PartnerApiMock mock = new PartnerApiMock()
            .token('tok-1', 3600)
            .apiTimeout()
            .api(200, TestDataFactory.statusBody('job-1', 'PROCESSING'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        PartnerApiModels.StatusResponse status = TestDoubles.client().getGenerationStatus('job-1');
        Test.stopTest();

        Assert.areEqual('PROCESSING', status.status, 'Recovered after a timeout');
    }

    @IsTest
    static void shouldThrowRetryableWhenEveryAttemptTimesOut() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('tok-1', 3600).apiTimeout());

        Test.startTest();
        try {
            TestDoubles.client().getGenerationStatus('job-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(0, expected.getStatusCode(), 'No response');
            Assert.isTrue(expected.isRetryable(), 'Transport failures are transient');
            Assert.isInstanceOfType(expected.getCause(), CalloutException.class, 'Original cause kept');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldFailFastWhenClientErrorIsReturned() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(404, '{"message":"job not found"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            TestDoubles.client().getGenerationStatus('missing-job');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(404, expected.getStatusCode(), 'Status code');
            Assert.isFalse(expected.isRetryable(), '404 is final');
            Assert.isTrue(expected.getMessage().contains('job not found'), 'Partner message included');
        }
        Test.stopTest();

        Assert.areEqual(1, mock.apiRequests.size(), 'No retries for 4xx');
    }

    @IsTest
    static void shouldNotRetryWhenNotImplemented() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(501, 'Not Implemented');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            TestDoubles.client().send('PATCH', '/v1/documents/jobs/job-1', '{}', null);
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(501, expected.getStatusCode(), 'Status code');
            Assert.isTrue(expected.getMessage().contains('Not Implemented'), 'Plain-text body included');
        }
        Test.stopTest();

        Assert.areEqual(1, mock.apiRequests.size(), 'Single attempt');
    }

    @IsTest
    static void shouldThrowWhenSuccessBodyIsEmpty() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('tok-1', 3600).api(200, ''));

        Test.startTest();
        try {
            TestDoubles.client().getGenerationStatus('job-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.isTrue(expected.getMessage().contains('empty body'), 'Message');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowWhenSuccessBodyIsNotJson() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('tok-1', 3600).api(200, '<ok/>'));

        Test.startTest();
        try {
            TestDoubles.client().getGenerationStatus('job-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.isTrue(expected.getMessage().contains('could not be parsed'), 'Message');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrowWhenSubmitResponseHasNoJobId() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('tok-1', 3600).api(202, '{"status":"QUEUED"}'));

        Test.startTest();
        try {
            TestDoubles.client().submitGeneration(sampleRequest(), 'req-1');
            Assert.fail('Expected PartnerApiException');
        } catch (PartnerApiException expected) {
            Assert.areEqual(202, expected.getStatusCode(), 'Status code');
            Assert.isTrue(expected.getMessage().contains('jobId'), 'Message');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldUrlEncodeJobIdWhenPolling() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(200, TestDataFactory.statusBody('a b/c', 'PROCESSING'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TestDoubles.client().getGenerationStatus('a b/c');
        Test.stopTest();

        Assert.areEqual(PartnerApiClient.BASE_ENDPOINT + PartnerApiClient.STATUS_PATH + 'a+b%2Fc', mock.apiRequests[0].getEndpoint(), 'Encoded path segment');
        Assert.areEqual('GET', mock.apiRequests[0].getMethod(), 'Method');
    }

    @IsTest
    static void shouldRejectInvalidArguments() {
        PartnerApiClient client = new PartnerApiClient();
        Integer rejected = 0;
        try {
            client.getGenerationStatus(' ');
        } catch (IllegalArgumentException expected) {
            rejected++;
        }
        try {
            client.submitGeneration(null, 'key');
        } catch (IllegalArgumentException expected) {
            rejected++;
        }
        try {
            client.withTimeout(0);
        } catch (IllegalArgumentException expected) {
            rejected++;
        }
        Assert.areEqual(3, rejected, 'Each invalid argument is rejected before any callout');
    }

    @IsTest
    static void shouldApplyCustomTimeoutWhenConfigured() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(200, '{"ok":true}');
        Test.setMock(HttpCalloutMock.class, mock);
        PartnerApiClient client = new PartnerApiClient(null, null, null).withTimeout(5000);

        Test.startTest();
        PartnerApiClient.ApiResponse response = client.send('GET', '/v1/health', null, new Map<String, String>{ 'X-Tenant' => 'demo' });
        Test.stopTest();

        Assert.areEqual(200, response.statusCode, 'Status');
        Assert.areEqual(1, response.attempts, 'First attempt succeeded');
        Assert.areEqual('demo', mock.apiRequests[0].getHeader('X-Tenant'), 'Extra header sent');
    }

    @IsTest
    static void shouldSpinForRequestedTimeWhenUsingCpuBoundedSleeper() {
        PartnerApiClient.CpuBoundedSleeper sleeper = new PartnerApiClient.CpuBoundedSleeper();
        Long started = System.currentTimeMillis();

        sleeper.sleep(5);
        sleeper.sleep(0);

        Assert.isTrue(System.currentTimeMillis() - started >= 5, 'Waited at least the requested time');
    }
}
