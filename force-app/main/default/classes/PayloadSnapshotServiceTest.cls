@IsTest
private class PayloadSnapshotServiceTest {
    private static final String CHANGED_PAYLOAD = TestDataFactory.SAMPLE_PAYLOAD.replace('"qty":2', '"qty":3');

    @TestSetup
    static void setup() {
        User tester = TestDataFactory.createIntegrationUser();
        System.runAs(tester) {
            TestDataFactory.createRequests(1);
        }
    }

    private static Generation_Request__c theRequest() {
        return [SELECT Id, Request_JSON__c, Schema_Version__c, Payload_Hash__c FROM Generation_Request__c LIMIT 1];
    }

    @IsTest
    static void shouldSortKeysAtEveryLevelWhenCanonicalizing() {
        String canonical = PayloadSnapshotService.canonicalize('{ "b": [ {"z":1,"y":2} ], "a": null }');

        Assert.areEqual('{"a":null,"b":[{"y":2,"z":1}]}', canonical, 'Sorted, compact, array order kept');
    }

    @IsTest
    static void shouldProduceSameHashWhenOnlyKeyOrderDiffers() {
        String first = PayloadSnapshotService.hash('{"a":1,"b":{"c":true,"d":"x"}}');
        String second = PayloadSnapshotService.hash('{"b":{"d":"x","c":true},"a":1}');

        Assert.areEqual(first, second, 'Hash is independent of key order');
        Assert.areEqual(64, first.length(), 'SHA-256 hex');
    }

    @IsTest
    static void shouldThrowWhenPayloadIsBlank() {
        try {
            PayloadSnapshotService.canonicalize('  ');
            Assert.fail('Expected SnapshotException');
        } catch (PayloadSnapshotService.SnapshotException expected) {
            Assert.isTrue(expected.getMessage().contains('empty'), 'Message');
        }
    }

    @IsTest
    static void shouldThrowWhenPayloadIsNotJson() {
        try {
            PayloadSnapshotService.canonicalize('{broken');
            Assert.fail('Expected SnapshotException');
        } catch (PayloadSnapshotService.SnapshotException expected) {
            Assert.isTrue(expected.getMessage().contains('not valid JSON'), 'Message');
        }
    }

    @IsTest
    static void shouldNumberSnapshotsAndStampHashWhenCapturing() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();

            Test.startTest();
            Payload_Snapshot__c first = PayloadSnapshotService.capture(request);
            request.Request_JSON__c = CHANGED_PAYLOAD;
            Payload_Snapshot__c second = PayloadSnapshotService.capture(request);
            Test.stopTest();

            Assert.areEqual(1, first.Sequence__c.intValue(), 'First snapshot');
            Assert.areEqual(2, second.Sequence__c.intValue(), 'Second snapshot');
            Assert.areEqual(second.Payload_Hash__c, request.Payload_Hash__c, 'Request carries the latest hash');
            Assert.areEqual(PayloadSnapshotService.canonicalize(CHANGED_PAYLOAD), second.Payload_JSON__c, 'Canonical JSON stored');
            Assert.areEqual(second.Id, PayloadSnapshotService.latest(request.Id).Id, 'Latest returns the newest');
            Assert.areEqual(3, PayloadSnapshotService.nextSequence(request.Id), 'Next sequence');
        }
    }

    @IsTest
    static void shouldThrowWhenCapturingUnsavedRequest() {
        try {
            PayloadSnapshotService.capture(TestDataFactory.newRequest(TestDataFactory.SAMPLE_PAYLOAD, 1));
            Assert.fail('Expected SnapshotException');
        } catch (PayloadSnapshotService.SnapshotException expected) {
            Assert.isTrue(expected.getMessage().contains('saved'), 'Message');
        }
    }

    @IsTest
    static void shouldReportNoBaselineWhenNeverSubmitted() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            PayloadSnapshotService.Comparison result = PayloadSnapshotService.compareToLatest(theRequest(), null);

            Assert.areEqual(PayloadSnapshotService.ComparisonStatus.NO_BASELINE, result.status, 'Status');
            Assert.isNull(PayloadSnapshotService.latest(null), 'Null id has no snapshot');
        }
    }

    @IsTest
    static void shouldReportIdenticalWhenHashesMatch() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            TestDataFactory.createSnapshot(request.Id, TestDataFactory.SAMPLE_PAYLOAD, 1, 1);

            PayloadSnapshotService.Comparison result = PayloadSnapshotService.compareToLatest(request, null);

            Assert.areEqual(PayloadSnapshotService.ComparisonStatus.IDENTICAL, result.status, 'Status');
            Assert.isTrue(result.changes.isEmpty(), 'No changes');
        }
    }

    @IsTest
    static void shouldReportIdenticalWhenOnlyIgnoredPathsDiffer() {
        Payload_Snapshot__c baseline = new Payload_Snapshot__c(
            Payload_JSON__c = '{"at":"2026-01-01","total":1}',
            Payload_Hash__c = PayloadSnapshotService.hash('{"at":"2026-01-01","total":1}'),
            Schema_Version__c = 1
        );

        PayloadSnapshotService.Comparison result = PayloadSnapshotService.compare(baseline, '{"at":"2026-02-01","total":1}', 1, new JsonDiff.Options().ignore('$.at'));

        Assert.areEqual(PayloadSnapshotService.ComparisonStatus.IDENTICAL, result.status, 'Hash differs but no tracked change');
    }

    @IsTest
    static void shouldListChangesWhenPayloadChanged() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            TestDataFactory.createSnapshot(request.Id, TestDataFactory.SAMPLE_PAYLOAD, 1, 1);
            request.Request_JSON__c = CHANGED_PAYLOAD;

            PayloadSnapshotService.Comparison result = PayloadSnapshotService.compareToLatest(request, new JsonDiff.Options().matchArraysBy('id'));

            Assert.areEqual(PayloadSnapshotService.ComparisonStatus.CHANGED, result.status, 'Status');
            Assert.areEqual(1, result.changes.size(), 'One change');
            Assert.areEqual('$.items[id=A1].qty', result.changes[0].path, 'Path');
            Assert.areEqual(1, result.baselineSchemaVersion, 'Baseline version');
        }
    }

    @IsTest
    static void shouldSkipFieldDiffWhenSchemaVersionsDiffer() {
        System.runAs(TestDataFactory.getIntegrationUser()) {
            Generation_Request__c request = theRequest();
            TestDataFactory.createSnapshot(request.Id, TestDataFactory.SAMPLE_PAYLOAD, 1, 1);
            request.Request_JSON__c = '{"customer":{"displayName":"Harbor Lane Studio"},"lines":[]}';
            request.Schema_Version__c = 2;

            PayloadSnapshotService.Comparison result = PayloadSnapshotService.compareToLatest(request, null);

            Assert.areEqual(PayloadSnapshotService.ComparisonStatus.SCHEMA_MISMATCH, result.status, 'Status');
            Assert.isTrue(result.changes.isEmpty(), 'No field-level changes across schema versions');
            Assert.isTrue(result.message.contains('v1') && result.message.contains('v2'), 'Message names both versions');
        }
    }

    @IsTest
    static void shouldReportInvalidPayloadWhenCurrentJsonIsBroken() {
        Payload_Snapshot__c baseline = new Payload_Snapshot__c(Payload_JSON__c = '{}', Payload_Hash__c = PayloadSnapshotService.hash('{}'));

        PayloadSnapshotService.Comparison result = PayloadSnapshotService.compare(baseline, '{oops', null, null);

        Assert.areEqual(PayloadSnapshotService.ComparisonStatus.INVALID_PAYLOAD, result.status, 'Status');
        Assert.areEqual(PayloadSnapshotService.DEFAULT_SCHEMA_VERSION, result.currentSchemaVersion, 'Null version defaults to 1');
    }
}
