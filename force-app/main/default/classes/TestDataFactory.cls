/**
 * Test data for the integration kit: a least-privilege user with the Integration_Kit_User
 * permission set, Generation_Request__c / Payload_Snapshot__c records and partner response bodies.
 */
@IsTest
public class TestDataFactory {
    public static final String PERMISSION_SET_NAME = 'Integration_Kit_User';
    public static final String TEST_USER_EMAIL = 'integration.kit.tester@example.com';
    public static final String TEMPLATE_KEY = 'engagement-letter';
    public static final String SAMPLE_PAYLOAD = '{"client":{"name":"Harbor Lane Studio","tier":"standard",'
        + '"address":{"city":"Springfield","postalCode":"01101"}},'
        + '"items":[{"id":"A1","description":"Discovery workshop","qty":2,"price":450.00},'
        + '{"id":"B2","description":"Implementation","qty":1,"price":3200}],'
        + '"notes":null}';

    /**
     * Inserts a Standard User with the kit permission set. Runs the setup DML in its own runAs
     * block so callers can insert non-setup records afterwards without MIXED_DML_OPERATION.
     *
     * @return Inserted user
     */
    public static User createIntegrationUser() {
        User tester;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            String uniqueSuffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(12);
            tester = new User(
                FirstName = 'Integration',
                LastName = 'Kit Tester',
                Email = TEST_USER_EMAIL,
                Username = 'integration.kit.' + uniqueSuffix + '@example.com.test',
                Alias = 'kittest',
                TimeZoneSidKey = 'America/New_York',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                ProfileId = standardProfile.Id
            );
            insert tester;
            PermissionSet kitPermissions = [SELECT Id FROM PermissionSet WHERE Name = :PERMISSION_SET_NAME LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = tester.Id, PermissionSetId = kitPermissions.Id);
        }
        return tester;
    }

    /**
     * @return The user created by createIntegrationUser in @TestSetup
     */
    public static User getIntegrationUser() {
        return [SELECT Id FROM User WHERE Email = :TEST_USER_EMAIL AND IsActive = TRUE LIMIT 1];
    }

    /**
     * @param payload Request JSON
     * @param schemaVersion Payload schema version
     * @return Unsaved Draft request
     */
    public static Generation_Request__c newRequest(String payload, Integer schemaVersion) {
        return new Generation_Request__c(
            Status__c = DocumentGenerationJob.STATUS_DRAFT,
            Template_Key__c = TEMPLATE_KEY,
            Request_JSON__c = payload,
            Schema_Version__c = schemaVersion
        );
    }

    /**
     * @param payload Request JSON
     * @param schemaVersion Payload schema version
     * @return Inserted Draft request
     */
    public static Generation_Request__c createRequest(String payload, Integer schemaVersion) {
        Generation_Request__c request = newRequest(payload, schemaVersion);
        insert request;
        return request;
    }

    /**
     * @param count Number of requests
     * @return Inserted Draft requests with the sample payload
     */
    public static List<Generation_Request__c> createRequests(Integer count) {
        List<Generation_Request__c> requests = new List<Generation_Request__c>();
        for (Integer index = 0; index < count; index++) {
            requests.add(newRequest(SAMPLE_PAYLOAD, 1));
        }
        insert requests;
        return requests;
    }

    /**
     * @param requestId Parent request
     * @param payload Payload JSON to store (canonicalized here)
     * @param schemaVersion Schema version of the payload
     * @param sequence Snapshot number
     * @return Inserted snapshot
     */
    public static Payload_Snapshot__c createSnapshot(Id requestId, String payload, Integer schemaVersion, Integer sequence) {
        String canonical = PayloadSnapshotService.canonicalize(payload);
        Payload_Snapshot__c snapshot = new Payload_Snapshot__c(
            Generation_Request__c = requestId,
            Payload_JSON__c = canonical,
            Payload_Hash__c = PayloadSnapshotService.hash(canonical),
            Schema_Version__c = schemaVersion,
            Sequence__c = sequence
        );
        insert snapshot;
        return snapshot;
    }

    /**
     * @param requestId Request to reload
     * @return Request with every field the job and controller use
     */
    public static Generation_Request__c reload(Id requestId) {
        return [
            SELECT Id, Name, Status__c, Template_Key__c, Request_JSON__c, Schema_Version__c, Payload_Hash__c,
                Response_Id__c, Attempts__c, Error__c, Correlation_Id__c, Document_Url__c
            FROM Generation_Request__c
            WHERE Id = :requestId
        ];
    }

    /**
     * @param accessToken Token value
     * @param expiresIn Lifetime in seconds, or null to omit expires_in
     * @return OAuth token endpoint response body
     */
    public static String tokenBody(String accessToken, Integer expiresIn) {
        Map<String, Object> body = new Map<String, Object>{ 'access_token' => accessToken, 'token_type' => 'Bearer' };
        if (expiresIn != null) {
            body.put('expires_in', expiresIn);
        }
        return JSON.serialize(body);
    }

    /**
     * @param jobId Partner job id
     * @return Submit response body
     */
    public static String submitBody(String jobId) {
        return JSON.serialize(new Map<String, Object>{ 'jobId' => jobId, 'status' => 'QUEUED' });
    }

    /**
     * @param jobId Partner job id
     * @param status QUEUED, PROCESSING, COMPLETE or FAILED
     * @return Status response body
     */
    public static String statusBody(String jobId, String status) {
        Map<String, Object> body = new Map<String, Object>{ 'jobId' => jobId, 'status' => status };
        if (status == PartnerApiModels.JOB_STATUS_COMPLETE) {
            body.put('documentUrl', 'https://files.partner.example.com/' + jobId + '.pdf');
        }
        if (status == PartnerApiModels.JOB_STATUS_FAILED) {
            body.put('errorCode', 'TEMPLATE_MISSING');
            body.put('errorMessage', 'Template engagement-letter was not found');
        }
        return JSON.serialize(body);
    }
}
