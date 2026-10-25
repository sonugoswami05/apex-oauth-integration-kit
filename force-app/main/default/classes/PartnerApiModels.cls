/**
 * Request and response DTOs for the partner document generation API.
 * Field names match the partner's JSON contract so JSON.serialize/deserialize can be used directly.
 */
public with sharing class PartnerApiModels {
    public static final String JOB_STATUS_COMPLETE = 'COMPLETE';
    public static final String JOB_STATUS_FAILED = 'FAILED';

    /**
     * Body of POST /v1/documents/generate.
     */
    public class GenerationRequest {
        public String templateKey;
        public String outputFormat;
        public String externalReference;
        public Integer schemaVersion;
        /** Merge data, usually the parsed Generation_Request__c.Request_JSON__c. */
        public Object data;
    }

    /**
     * Response of POST /v1/documents/generate.
     */
    public class SubmitResponse {
        public String jobId;
        public String status;
        /** Not part of the partner payload; filled by PartnerApiClient. */
        public String correlationId;
    }

    /**
     * Response of GET /v1/documents/jobs/{jobId}.
     */
    public class StatusResponse {
        public String jobId;
        public String status;
        public String documentUrl;
        public String errorCode;
        public String errorMessage;
        /** Not part of the partner payload; filled by PartnerApiClient. */
        public String correlationId;

        /**
         * Tells whether the job finished successfully.
         *
         * @return True when the partner finished rendering the document
         */
        public Boolean isComplete() {
            return JOB_STATUS_COMPLETE.equalsIgnoreCase(status);
        }

        /**
         * Tells whether the job failed on the partner side.
         *
         * @return True when the partner gave up on the job
         */
        public Boolean isFailed() {
            return JOB_STATUS_FAILED.equalsIgnoreCase(status);
        }
    }
}
