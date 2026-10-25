@IsTest
private class PayloadDiffControllerTest {
    private static final String NEVER_SENT = 'never-sent';
    private static final String CHANGED = 'changed';
    private static final String IDENTICAL = 'identical';
    private static final String SCHEMA_V2 = 'schema-v2';
    private static final String MANY_CHANGES = 'many-changes';
    private static final String RUNNING = 'running';

    private static final String CHANGED_PAYLOAD = '{"client":{"name":"Harbor Lane Studio","tier":2,'
        + '"address":{"city":"Springfield","postalCode":"01101"}},'
        + '"items":[{"id":"A1","description":"Discovery workshop","qty":3,"price":450.00},'
        + '{"id":"B2","description":"Implementation","qty":1,"price":3200},'
        + '{"id":"C3","description":"Training","qty":1,"price":800}]}';

    @TestSetup
    static void setup() {
        User tester = TestDataFactory.createIntegrationUser();
        System.runAs(tester) {
            Map<String, Generation_Request__c> requestsByKey = new Map<String, Generation_Request__c>{
                NEVER_SENT => request(NEVER_SENT, TestDataFactory.SAMPLE_PAYLOAD, 1, DocumentGenerationJob.STATUS_DRAFT),
                CHANGED => request(CHANGED, CHANGED_PAYLOAD, 1, DocumentGenerationJob.STATUS_COMPLETE),
                IDENTICAL => request(IDENTICAL, TestDataFactory.SAMPLE_PAYLOAD, 1, DocumentGenerationJob.STATUS_COMPLETE),
                SCHEMA_V2 => request(SCHEMA_V2, '{"customer":{"displayName":"Harbor Lane Studio"}}', 2, DocumentGenerationJob.STATUS_FAILED),
                MANY_CHANGES => request(MANY_CHANGES, flatPayload(PayloadDiffController.MAX_ROWS + 1, 1), 1, DocumentGenerationJob.STATUS_COMPLETE),
                RUNNING => request(RUNNING, TestDataFactory.SAMPLE_PAYLOAD, 1, DocumentGenerationJob.STATUS_POLLING)
            };
            insert requestsByKey.values();

            List<Payload_Snapshot__c> snapshots = new List<Payload_Snapshot__c>{
                snapshot(requestsByKey.get(CHANGED).Id, TestDataFactory.SAMPLE_PAYLOAD),
                snapshot(requestsByKey.get(IDENTICAL).Id, TestDataFactory.SAMPLE_PAYLOAD),
                snapshot(requestsByKey.get(SCHEMA_V2).Id, TestDataFactory.SAMPLE_PAYLOAD),
                snapshot(requestsByKey.get(MANY_CHANGES).Id, flatPayload(PayloadDiffController.MAX_ROWS + 1, 0))
            };
            insert snapshots;
        }
    }

    private static Generation_Request__c request(String templateKey, String payload, Integer schemaVersion, String status) {
        Generation_Request__c record = TestDataFactory.newRequest(payload, schemaVersion);
        record.Template_Key__c = templateKey;
        record.Status__c = status;
        return record;
    }

    private static Payload_Snapshot__c snapshot(Id requestId, String payload) {
        String canonical = PayloadSnapshotService.canonicalize(payload);
        return new Payload_Snapshot__c(
            Generation_Request__c = requestId,
            Payload_JSON__c = canonical,
            Payload_Hash__c = PayloadSnapshotService.hash(canonical),
            Schema_Version__c = 1,
            Sequence__c = 1
        );
    }

    private static String flatPayload(Integer keyCount, Integer value) {
        Map<String, Object> payload = new Map<String, Object>();
        for (Integer index = 0; index < keyCount; index++) {
            payload.put('field' + String.valueOf(index).leftPad(4, '0'), value);
        }
        return JSON.serialize(payload);
    }

    private static Id idFor(String templateKey) {
        return [SELECT Id FROM Generation_Request__c WHERE Template_Key__c = :templateKey LIMIT 1].Id;
    }

    @IsTest
    static void shouldReportNoBaselineWhenRequestWasNeverSubmitted() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            PayloadDiffController.DiffView view = PayloadDiffController.getPayloadDiff(idFor(NEVER_SENT));

            Assert.areEqual('NO_BASELINE', view.status, 'Status');
            Assert.isTrue(view.canRegenerate, 'Draft requests can be generated');
            Assert.isTrue(view.rows.isEmpty(), 'No rows');
        }
    }

    @IsTest
    static void shouldReturnRowsAndCountsWhenPayloadChanged() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            PayloadDiffController.DiffView view = PayloadDiffController.getPayloadDiff(idFor(CHANGED));

            Assert.areEqual('CHANGED', view.status, 'Status');
            Assert.areEqual(2, view.changedCount, 'Changed');
            Assert.areEqual(1, view.addedCount, 'Added');
            Assert.areEqual(1, view.removedCount, 'Removed');
            Assert.areEqual(4, view.rows.size(), 'One row per change');
            Assert.areEqual(1, view.baselineSequence, 'Compared with snapshot 1');
            Assert.isNotNull(view.baselineCapturedOn, 'Snapshot date');
            Assert.isFalse(view.truncated, 'Not truncated');

            PayloadDiffController.DiffRow tierRow = view.rows[0];
            Assert.areEqual('$.client.tier', tierRow.path, 'Sorted first');
            Assert.areEqual('changed', tierRow.kind, 'Kind');
            Assert.isTrue(tierRow.typeChanged, 'string -> number');
            Assert.areEqual('standard', tierRow.oldValue, 'Old value');
            Assert.areEqual('2', tierRow.newValue, 'New value');

            Assert.areEqual('$.items[id=A1].qty', view.rows[1].path, 'Keyed array path');
            Assert.areEqual('added', view.rows[2].kind, 'New line item');
            Assert.isNull(view.rows[2].oldValue, 'Added rows have no old value');
            Assert.areEqual('removed', view.rows[3].kind, 'Removed notes');
            Assert.areEqual('$.notes', view.rows[3].path, 'Removed path');
            Assert.isNull(view.rows[3].newValue, 'Removed rows have no new value');
        }
    }

    @IsTest
    static void shouldReportIdenticalWhenPayloadUnchanged() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            PayloadDiffController.DiffView view = PayloadDiffController.getPayloadDiff(idFor(IDENTICAL));

            Assert.areEqual('IDENTICAL', view.status, 'Status');
            Assert.areEqual(0, view.changedCount + view.addedCount + view.removedCount, 'No changes counted');
        }
    }

    @IsTest
    static void shouldNotDiffFieldsWhenSchemaVersionChanged() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            PayloadDiffController.DiffView view = PayloadDiffController.getPayloadDiff(idFor(SCHEMA_V2));

            Assert.areEqual('SCHEMA_MISMATCH', view.status, 'Status');
            Assert.areEqual(1, view.baselineSchemaVersion, 'Baseline version');
            Assert.areEqual(2, view.currentSchemaVersion, 'Current version');
            Assert.isTrue(view.rows.isEmpty(), 'No field rows across versions');
        }
    }

    @IsTest
    static void shouldCapRowsWhenThereAreTooManyChanges() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            PayloadDiffController.DiffView view = PayloadDiffController.getPayloadDiff(idFor(MANY_CHANGES));

            Assert.areEqual(PayloadDiffController.MAX_ROWS + 1, view.changedCount, 'Every change counted');
            Assert.areEqual(PayloadDiffController.MAX_ROWS, view.rows.size(), 'Rows capped');
            Assert.isTrue(view.truncated, 'Truncation flagged');
        }
    }

    @IsTest
    static void shouldBlockRegenerationWhenRunIsActive() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Id runningId = idFor(RUNNING);
            PayloadDiffController.DiffView view = PayloadDiffController.getPayloadDiff(runningId);
            Assert.isFalse(view.canRegenerate, 'Polling requests cannot be regenerated');

            try {
                PayloadDiffController.requestRegeneration(runningId);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException expected) {
                Assert.isTrue(expected.getMessage().contains('already in progress'), 'Message: ' + expected.getMessage());
            }
        }
    }

    @IsTest
    static void shouldThrowWhenRecordIsMissing() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            try {
                PayloadDiffController.getPayloadDiff(null);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException expected) {
                Assert.isTrue(expected.getMessage().contains('not found'), 'Message: ' + expected.getMessage());
            }
        }
    }

    @IsTest
    static void shouldStartRunWhenUserConfirmsRegeneration() {
        Test.setMock(HttpCalloutMock.class, new PartnerApiMock().token('tok-1', 3600).api(202, TestDataFactory.submitBody('job-7')));

        System.runAs(TestDataFactory.getIntegrationUser()) {
            Id requestId = idFor(CHANGED);

            Test.startTest();
            Id jobId = PayloadDiffController.requestRegeneration(requestId);
            Test.stopTest();

            Generation_Request__c saved = TestDataFactory.reload(requestId);
            Assert.isNotNull(jobId, 'Queueable enqueued');
            Assert.areEqual(DocumentGenerationJob.STATUS_SUBMITTED, saved.Status__c, 'Run started and submitted');
            Assert.areEqual(PayloadSnapshotService.hash(CHANGED_PAYLOAD), saved.Payload_Hash__c, 'New baseline is the regenerated payload');
            Assert.areEqual(2, [SELECT COUNT() FROM Payload_Snapshot__c WHERE Generation_Request__c = :requestId], 'Second snapshot captured');
        }
    }
}
