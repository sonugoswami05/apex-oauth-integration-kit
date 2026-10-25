@IsTest
private class DocumentGenerationJobTest {
    private static final String JOB_ID = 'job-42';

    @TestSetup
    static void setup() {
        User tester = TestDataFactory.createIntegrationUser();
        System.runAs(tester) {
            Generation_Request__c draft = TestDataFactory.newRequest(TestDataFactory.SAMPLE_PAYLOAD, 1);
            Generation_Request__c queued = TestDataFactory.newRequest(TestDataFactory.SAMPLE_PAYLOAD, 1);
            queued.Status__c = DocumentGenerationJob.STATUS_QUEUED;
            insert new List<Generation_Request__c>{ draft, queued };
        }
    }

    /** The Draft request created in setup. */
    private static Generation_Request__c theRequest() {
        return requestWithStatus(DocumentGenerationJob.STATUS_DRAFT);
    }

    /** Queued requests are pre-built in setup so no DML has to happen before a callout. */
    private static Generation_Request__c requestWithStatus(String status) {
        return TestDataFactory.reload([SELECT Id FROM Generation_Request__c WHERE Status__c = :status LIMIT 1].Id);
    }

    private static DocumentGenerationJob.StepResult runUntilDone(Generation_Request__c request, PartnerApiClient client) {
        DocumentGenerationJob.StepResult result;
        Integer guard = 0;
        do {
            result = DocumentGenerationJob.runStep(request, client);
            guard++;
        } while (result.nextDelayMinutes != null && guard < 50);
        return result;
    }

    @IsTest
    static void shouldSubmitAndSnapshotWhenStartedAndQueueableRuns() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(202, TestDataFactory.submitBody(JOB_ID));
        Test.setMock(HttpCalloutMock.class, mock);

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();

            Test.startTest();
            Id asyncJobId = DocumentGenerationJob.start(request.Id);
            Test.stopTest();

            Generation_Request__c saved = TestDataFactory.reload(request.Id);
            Assert.isNotNull(asyncJobId, 'Job enqueued');
            Assert.areEqual(DocumentGenerationJob.STATUS_SUBMITTED, saved.Status__c, 'Submitted by the Queueable');
            Assert.areEqual(JOB_ID, saved.Response_Id__c, 'Partner job id stored');
            Assert.areEqual(1, saved.Attempts__c.intValue(), 'One attempt');
            Assert.isNotNull(saved.Correlation_Id__c, 'Correlation id stored');
            Assert.areEqual(PayloadSnapshotService.hash(TestDataFactory.SAMPLE_PAYLOAD), saved.Payload_Hash__c, 'Hash of the submitted payload');
            Assert.areEqual(1, [SELECT COUNT() FROM Payload_Snapshot__c WHERE Generation_Request__c = :request.Id], 'Snapshot captured');
            Assert.areEqual(String.valueOf(request.Id) + '-1', mock.apiRequests[0].getHeader('Idempotency-Key'), 'Idempotency key per run');
        }
    }

    @IsTest
    static void shouldChainNextPollWhenExecutedDirectly() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('tok-1', 3600).api(202, TestDataFactory.submitBody(JOB_ID)));
        TestDoubles.RecordingScheduler scheduler = new TestDoubles.RecordingScheduler();
        DocumentGenerationJob.scheduler = scheduler;

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = requestWithStatus(DocumentGenerationJob.STATUS_QUEUED);

            Test.startTest();
            new DocumentGenerationJob(request.Id).execute(null);
            Test.stopTest();

            Assert.areEqual(1, scheduler.jobs.size(), 'Next step chained');
            Assert.areEqual(DocumentGenerationJob.pollDelayMinutes, scheduler.delays[0], 'Poll delay applied');
            Assert.areEqual(DocumentGenerationJob.STATUS_SUBMITTED, TestDataFactory.reload(request.Id).Status__c, 'Status saved');
        }
    }

    @IsTest
    static void shouldDoNothingWhenRequestIsNotActive() {
        PartnerApiMock mock = new PartnerApiMock().token('tok-1', 3600).api(202, TestDataFactory.submitBody(JOB_ID));
        Test.setMock(HttpCalloutMock.class, mock);
        TestDoubles.RecordingScheduler scheduler = new TestDoubles.RecordingScheduler();
        DocumentGenerationJob.scheduler = scheduler;

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();

            Test.startTest();
            new DocumentGenerationJob(request.Id).execute(null);
            Test.stopTest();

            Assert.areEqual(0, mock.apiRequests.size(), 'Draft requests are not processed');
            Assert.isTrue(scheduler.jobs.isEmpty(), 'Nothing chained');
        }
    }

    @IsTest
    static void shouldPollUntilCompleteWhenPartnerFinishes() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock()
            .token('tok-1', 3600)
            .api(202, TestDataFactory.submitBody(JOB_ID))
            .api(200, TestDataFactory.statusBody(JOB_ID, 'PROCESSING'))
            .api(200, TestDataFactory.statusBody(JOB_ID, 'PROCESSING'))
            .api(200, TestDataFactory.statusBody(JOB_ID, PartnerApiModels.JOB_STATUS_COMPLETE)));

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();

            Test.startTest();
            DocumentGenerationJob.StepResult last = runUntilDone(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(DocumentGenerationJob.STATUS_COMPLETE, request.Status__c, 'Complete');
            Assert.areEqual(4, request.Attempts__c.intValue(), 'Submit plus three polls');
            Assert.areEqual('https://files.partner.example.com/' + JOB_ID + '.pdf', request.Document_Url__c, 'Document URL stored');
            Assert.isNull(last.nextDelayMinutes, 'Chain ends');
            Assert.isNull(request.Error__c, 'No error');
        }
    }

    @IsTest
    static void shouldStopAtMaxAttemptsWhenPartnerNeverFinishes() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock()
            .token('tok-1', 3600)
            .api(202, TestDataFactory.submitBody(JOB_ID))
            .api(200, TestDataFactory.statusBody(JOB_ID, 'PROCESSING')));
        DocumentGenerationJob.maxAttempts = 4;

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();

            Test.startTest();
            runUntilDone(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(DocumentGenerationJob.STATUS_FAILED, request.Status__c, 'Gave up');
            Assert.areEqual(4, request.Attempts__c.intValue(), 'Stopped exactly at the cap');
            Assert.isTrue(request.Error__c.contains('Stopped after 4 attempts'), 'Reason recorded: ' + request.Error__c);
        }
    }

    @IsTest
    static void shouldFailWhenPartnerReportsFailure() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock()
            .token('tok-1', 3600)
            .api(200, TestDataFactory.statusBody(JOB_ID, PartnerApiModels.JOB_STATUS_FAILED)));

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            request.Response_Id__c = JOB_ID;

            Test.startTest();
            DocumentGenerationJob.StepResult result = DocumentGenerationJob.runStep(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(DocumentGenerationJob.STATUS_FAILED, request.Status__c, 'Failed');
            Assert.isTrue(request.Error__c.contains('TEMPLATE_MISSING'), 'Partner error code kept');
            Assert.isNull(result.nextDelayMinutes, 'No further polling');
        }
    }

    @IsTest
    static void shouldDeferWithRetryAfterWhenSubmitIsThrottled() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock()
            .token('tok-1', 3600)
            .api(429, '{"message":"quota exceeded"}', new Map<String, String>{ 'Retry-After' => '120' }));

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            request.Status__c = DocumentGenerationJob.STATUS_QUEUED;

            Test.startTest();
            DocumentGenerationJob.StepResult result = DocumentGenerationJob.runStep(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(2, result.nextDelayMinutes, '120 seconds rounds to a 2 minute delay');
            Assert.areEqual(DocumentGenerationJob.STATUS_QUEUED, request.Status__c, 'Still waiting to submit');
            Assert.isTrue(request.Error__c.startsWith('Will retry'), 'Transient error recorded');
            Assert.isFalse(result.submitted, 'Nothing submitted yet');
        }
    }

    @IsTest
    static void shouldKeepPollingWhenStatusCallIsThrottled() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock()
            .token('tok-1', 3600)
            .api(503, '', new Map<String, String>{ 'Retry-After' => '30' }));

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            request.Response_Id__c = JOB_ID;

            Test.startTest();
            DocumentGenerationJob.StepResult result = DocumentGenerationJob.runStep(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(DocumentGenerationJob.STATUS_POLLING, request.Status__c, 'Back to polling');
            Assert.areEqual(DocumentGenerationJob.pollDelayMinutes, result.nextDelayMinutes, 'Short Retry-After uses the normal poll delay');
        }
    }

    @IsTest
    static void shouldFailWhenPartnerRejectsRequest() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock()
            .token('tok-1', 3600)
            .api(400, '{"message":"templateKey is required"}'));

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();

            Test.startTest();
            DocumentGenerationJob.StepResult result = DocumentGenerationJob.runStep(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(DocumentGenerationJob.STATUS_FAILED, request.Status__c, 'Failed');
            Assert.isTrue(request.Error__c.contains('[HTTP 400]'), 'Status in error: ' + request.Error__c);
            Assert.isNull(result.nextDelayMinutes, 'No retry for 4xx');
        }
    }

    @IsTest
    static void shouldFailWhenPayloadIsInvalidAtSubmitTime() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            request.Request_JSON__c = '{broken';

            Test.startTest();
            DocumentGenerationJob.StepResult result = DocumentGenerationJob.runStep(request, TestDoubles.client());
            Test.stopTest();

            Assert.areEqual(DocumentGenerationJob.STATUS_FAILED, request.Status__c, 'Failed without a callout');
            Assert.isNull(result.nextDelayMinutes, 'Nothing to retry');
        }
    }

    @IsTest
    static void shouldRejectWhenRunIsAlreadyActive() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = requestWithStatus(DocumentGenerationJob.STATUS_QUEUED);

            try {
                DocumentGenerationJob.start(request.Id);
                Assert.fail('Expected GenerationException');
            } catch (DocumentGenerationJob.GenerationException expected) {
                Assert.isTrue(expected.getMessage().contains('already in progress'), 'Message');
            }
        }
    }

    @IsTest
    static void shouldRejectWhenPayloadIsInvalidAtStart() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            request.Request_JSON__c = 'not json';
            update request;

            try {
                DocumentGenerationJob.start(request.Id);
                Assert.fail('Expected GenerationException');
            } catch (DocumentGenerationJob.GenerationException expected) {
                Assert.isTrue(expected.getMessage().contains('not valid JSON'), 'Message');
            }
        }
    }

    @IsTest
    static void shouldRejectWhenRequestDoesNotExist() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            delete request;

            try {
                DocumentGenerationJob.start(request.Id);
                Assert.fail('Expected GenerationException');
            } catch (DocumentGenerationJob.GenerationException expected) {
                Assert.isTrue(expected.getMessage().contains('not found'), 'Message');
            }
        }
    }

    @IsTest
    static void shouldMarkFailedWhenStepCrashed() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Id queuedId = requestWithStatus(DocumentGenerationJob.STATUS_QUEUED).Id;
            Id draftId = theRequest().Id;

            Test.startTest();
            Boolean ignoredOnSuccess = DocumentGenerationJob.recordCrash(queuedId, ParentJobResult.SUCCESS, null);
            Boolean ignoredWhenInactive = DocumentGenerationJob.recordCrash(draftId, ParentJobResult.UNHANDLED_EXCEPTION, null);
            Boolean recorded = DocumentGenerationJob.recordCrash(queuedId, ParentJobResult.UNHANDLED_EXCEPTION, new DmlException('row lock'));
            Test.stopTest();

            Generation_Request__c saved = TestDataFactory.reload(queuedId);
            Assert.isFalse(ignoredOnSuccess, 'Successful jobs are left alone');
            Assert.isFalse(ignoredWhenInactive, 'Finished or draft requests are left alone');
            Assert.isTrue(recorded, 'Crash recorded');
            Assert.areEqual(DocumentGenerationJob.STATUS_FAILED, saved.Status__c, 'Status');
            Assert.isTrue(saved.Error__c.contains('System.DmlException: row lock'), 'Reason: ' + saved.Error__c);
        }
    }

    @IsTest
    static void shouldConvertRetryAfterToMinutes() {
        Integer poll = DocumentGenerationJob.pollDelayMinutes;

        Assert.areEqual(poll, DocumentGenerationJob.retryDelayMinutes(null), 'Unknown wait uses the poll delay');
        Assert.areEqual(poll, DocumentGenerationJob.retryDelayMinutes(30), 'Never shorter than the poll delay');
        Assert.areEqual(2, DocumentGenerationJob.retryDelayMinutes(61), 'Rounded up');
        Assert.areEqual(10, DocumentGenerationJob.retryDelayMinutes(3600), 'Capped at the 10 minute Queueable maximum');
    }

    @IsTest
    static void shouldClampDelayWhenSchedulingWithDefaultScheduler() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Test.startTest();
            Id jobId = new DocumentGenerationJob.AsyncJobScheduler().schedule(new DocumentGenerationJob(null), 99);
            Test.stopTest();

            Assert.isNotNull(jobId, 'Enqueued from a non-async test context');
        }
    }
}
