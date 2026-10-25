/**
 * Asynchronous document generation for one Generation_Request__c.
 *
 * Each execution performs exactly one step and then re-enqueues itself with a delay:
 *
 *   Queued --submit--> Submitted --poll--> Polling --poll--> ... --> Complete | Failed
 *
 * Why a chained Queueable: Apex cannot sleep, a single transaction caps total callout time, and a
 * render can take minutes. Re-enqueuing with AsyncOptions.MinimumQueueableDelayInMinutes spaces the
 * polls out without holding a transaction open. Attempts__c caps the chain, so a partner that never
 * finishes cannot create an endless loop.
 *
 * Within a step all callouts happen before any DML (snapshot insert, request update), which keeps
 * the job clear of "uncommitted work pending" errors.
 *
 * @example
 * Id jobId = DocumentGenerationJob.start(generationRequestId);
 */
public with sharing class DocumentGenerationJob implements Queueable, Database.AllowsCallouts {
    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_SUBMITTED = 'Submitted';
    public static final String STATUS_POLLING = 'Polling';
    public static final String STATUS_COMPLETE = 'Complete';
    public static final String STATUS_FAILED = 'Failed';

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{ STATUS_QUEUED, STATUS_SUBMITTED, STATUS_POLLING };
    private static final String OUTPUT_FORMAT = 'PDF';
    private static final Integer MAX_ASYNC_DELAY_MINUTES = 10;
    private static final Integer MAX_ERROR_LENGTH = 32000;

    @TestVisible
    private static Integer maxAttempts = 30;
    @TestVisible
    private static Integer pollDelayMinutes = 1;
    @TestVisible
    private static JobScheduler scheduler = new AsyncJobScheduler();

    private final Id requestId;

    /**
     * Creates the job for one request.
     *
     * @param requestId Generation_Request__c to process
     */
    public DocumentGenerationJob(Id requestId) {
        this.requestId = requestId;
    }

    /**
     * Resets a request for a new run and enqueues the first step.
     *
     * @param requestId Generation_Request__c id
     * @return Id of the enqueued job (null inside an Apex test that is already running async code)
     * @throws GenerationException When the request is missing, already running, or has an invalid payload
     */
    public static Id start(Id requestId) {
        Generation_Request__c request = load(requestId);
        if (request == null) {
            throw new GenerationException('Generation request not found or you do not have access to it.');
        }
        if (ACTIVE_STATUSES.contains(request.Status__c)) {
            throw new GenerationException('A generation run is already in progress for ' + request.Name + '.');
        }
        try {
            PayloadSnapshotService.canonicalize(request.Request_JSON__c);
        } catch (PayloadSnapshotService.SnapshotException invalidPayload) {
            throw new GenerationException(invalidPayload.getMessage(), invalidPayload);
        }
        request.Status__c = STATUS_QUEUED;
        request.Attempts__c = 0;
        request.Error__c = null;
        request.Response_Id__c = null;
        request.Document_Url__c = null;
        request.Correlation_Id__c = null;
        update as user request;
        return scheduler.schedule(new DocumentGenerationJob(requestId), 0);
    }

    /**
     * Runs one submit or poll step, saves the outcome and schedules the next step if needed.
     *
     * @param context Queueable context (unused)
     */
    public void execute(QueueableContext context) {
        if (System.isQueueable()) {
            // Records a Failed status if this step dies with an uncatchable error (limits, DML).
            System.attachFinalizer(new FailureFinalizer(requestId));
        }
        Generation_Request__c request = load(requestId);
        if (request == null || !ACTIVE_STATUSES.contains(request.Status__c)) {
            // Deleted, cancelled or already finished by another run.
            return;
        }
        StepResult result = runStep(request, new PartnerApiClient());
        if (result.submitted) {
            PayloadSnapshotService.capture(request);
        }
        update as user request;
        if (result.nextDelayMinutes != null) {
            scheduler.schedule(new DocumentGenerationJob(requestId), result.nextDelayMinutes);
        }
    }

    /**
     * Performs one step against the partner API and updates the request in memory only.
     * Kept separate from execute() so tests can drive a whole polling loop in one transaction.
     *
     * @param request Request loaded with all job fields
     * @param client Partner API client
     * @return What happened and whether another step is needed
     */
    @TestVisible
    private static StepResult runStep(Generation_Request__c request, PartnerApiClient client) {
        StepResult result = new StepResult();
        Integer attempt = request.Attempts__c == null ? 1 : request.Attempts__c.intValue() + 1;
        request.Attempts__c = attempt;
        try {
            if (String.isBlank(request.Response_Id__c)) {
                submit(request, client, result);
            } else {
                poll(request, client, result);
            }
        } catch (PartnerApiException apiError) {
            handleApiFailure(request, apiError, result);
        } catch (PayloadSnapshotService.SnapshotException invalidPayload) {
            fail(request, invalidPayload.getMessage());
        }
        if (result.nextDelayMinutes != null && attempt >= maxAttempts) {
            result.nextDelayMinutes = null;
            fail(request, 'Stopped after ' + attempt + ' attempts without a final status from the partner.');
        }
        return result;
    }

    private static void submit(Generation_Request__c request, PartnerApiClient client, StepResult result) {
        String canonical = PayloadSnapshotService.canonicalize(request.Request_JSON__c);
        PartnerApiModels.GenerationRequest body = new PartnerApiModels.GenerationRequest();
        body.templateKey = request.Template_Key__c;
        body.outputFormat = OUTPUT_FORMAT;
        body.externalReference = request.Id;
        body.schemaVersion = request.Schema_Version__c == null
            ? PayloadSnapshotService.DEFAULT_SCHEMA_VERSION
            : request.Schema_Version__c.intValue();
        body.data = JSON.deserializeUntyped(canonical);

        // Same key for every retry of this submit, new key for each regeneration.
        String idempotencyKey = String.valueOf(request.Id) + '-' + PayloadSnapshotService.nextSequence(request.Id);
        PartnerApiModels.SubmitResponse response = client.submitGeneration(body, idempotencyKey);

        request.Response_Id__c = response.jobId;
        request.Correlation_Id__c = response.correlationId;
        request.Status__c = STATUS_SUBMITTED;
        request.Error__c = null;
        result.submitted = true;
        result.nextDelayMinutes = pollDelayMinutes;
    }

    private static void poll(Generation_Request__c request, PartnerApiClient client, StepResult result) {
        PartnerApiModels.StatusResponse status = client.getGenerationStatus(request.Response_Id__c);
        request.Correlation_Id__c = status.correlationId;
        if (status.isComplete()) {
            request.Status__c = STATUS_COMPLETE;
            request.Document_Url__c = status.documentUrl;
            request.Error__c = null;
        } else if (status.isFailed()) {
            String reason = String.isBlank(status.errorMessage) ? 'no reason given' : status.errorMessage;
            String code = String.isBlank(status.errorCode) ? '' : ' (' + status.errorCode + ')';
            fail(request, 'Partner reported the job as failed' + code + ': ' + reason);
        } else {
            request.Status__c = STATUS_POLLING;
            request.Error__c = null;
            result.nextDelayMinutes = pollDelayMinutes;
        }
    }

    private static void handleApiFailure(Generation_Request__c request, PartnerApiException apiError, StepResult result) {
        request.Correlation_Id__c = apiError.getCorrelationId();
        if (!apiError.isRetryable()) {
            fail(request, apiError.toSafeMessage());
            return;
        }
        request.Status__c = String.isBlank(request.Response_Id__c) ? STATUS_QUEUED : STATUS_POLLING;
        request.Error__c = ('Will retry: ' + apiError.toSafeMessage()).left(MAX_ERROR_LENGTH);
        result.nextDelayMinutes = retryDelayMinutes(apiError.getRetryAfterSeconds());
    }

    @TestVisible
    private static Integer retryDelayMinutes(Integer retryAfterSeconds) {
        if (retryAfterSeconds == null || retryAfterSeconds <= 0) {
            return pollDelayMinutes;
        }
        Integer minutes = (retryAfterSeconds + 59) / 60;
        return Math.min(Math.max(minutes, pollDelayMinutes), MAX_ASYNC_DELAY_MINUTES);
    }

    /**
     * Marks a still-active request as Failed after its Queueable ended with an unhandled exception.
     *
     * @param requestId Generation_Request__c id
     * @param result Outcome of the parent Queueable
     * @param error Exception that ended the parent Queueable, may be null
     * @return True when the request was updated
     */
    @TestVisible
    private static Boolean recordCrash(Id requestId, ParentJobResult result, Exception error) {
        if (result != ParentJobResult.UNHANDLED_EXCEPTION) {
            return false;
        }
        Generation_Request__c request = load(requestId);
        if (request == null || !ACTIVE_STATUSES.contains(request.Status__c)) {
            return false;
        }
        String reason = error == null ? 'unknown error' : error.getTypeName() + ': ' + error.getMessage();
        fail(request, 'The generation job stopped unexpectedly (' + reason + ').');
        update as user request;
        return true;
    }

    private static void fail(Generation_Request__c request, String message) {
        request.Status__c = STATUS_FAILED;
        request.Error__c = message == null ? null : message.left(MAX_ERROR_LENGTH);
    }

    private static Generation_Request__c load(Id requestId) {
        if (requestId == null) {
            return null;
        }
        List<Generation_Request__c> requests = [
            SELECT Id, Name, Status__c, Template_Key__c, Request_JSON__c, Schema_Version__c, Payload_Hash__c,
                Response_Id__c, Attempts__c, Error__c, Correlation_Id__c, Document_Url__c
            FROM Generation_Request__c
            WHERE Id = :requestId
            WITH USER_MODE
            LIMIT 1
        ];
        return requests.isEmpty() ? null : requests[0];
    }

    /**
     * Outcome of one step.
     */
    public class StepResult {
        /** True when this step submitted the payload, so a snapshot must be captured. */
        public Boolean submitted = false;
        /** Minutes until the next step, or null when the run is finished. */
        public Integer nextDelayMinutes;
    }

    /**
     * Enqueues the next step. Swappable so tests can observe chaining.
     */
    public interface JobScheduler {
        /**
         * Enqueues the job, optionally after a delay.
         *
         * @param job Job to enqueue
         * @param delayMinutes Minimum delay before it runs (0 to 10)
         * @return Async job id, or null when nothing was enqueued
         */
        Id schedule(Queueable job, Integer delayMinutes);
    }

    /**
     * Default scheduler backed by System.enqueueJob with AsyncOptions.
     */
    public class AsyncJobScheduler implements JobScheduler {
        /**
         * Enqueues the job with AsyncOptions.MinimumQueueableDelayInMinutes.
         *
         * @param job Job to enqueue
         * @param delayMinutes Minimum delay before it runs (clamped to 0..10)
         * @return Async job id, or null inside a test that is already running a Queueable
         */
        public Id schedule(Queueable job, Integer delayMinutes) {
            // Apex tests cannot chain Queueables; tests drive later steps directly instead.
            if (Test.isRunningTest() && System.isQueueable()) {
                return null;
            }
            AsyncOptions options = new AsyncOptions();
            Integer requested = delayMinutes == null ? 0 : delayMinutes;
            options.MinimumQueueableDelayInMinutes = Math.min(Math.max(requested, 0), MAX_ASYNC_DELAY_MINUTES);
            return System.enqueueJob(job, options);
        }
    }

    /**
     * Finalizer attached to every step so a crash never leaves a request stuck in Polling.
     */
    public class FailureFinalizer implements Finalizer {
        private final Id requestId;

        /**
         * Creates a finalizer for one request.
         *
         * @param requestId Generation_Request__c id
         */
        public FailureFinalizer(Id requestId) {
            this.requestId = requestId;
        }

        /**
         * Runs after the parent Queueable, whether it succeeded or not.
         *
         * @param context Finalizer context with the parent job result
         */
        public void execute(FinalizerContext context) {
            recordCrash(requestId, context.getResult(), context.getException());
        }
    }

    /**
     * Raised when a run cannot be started.
     */
    public class GenerationException extends Exception {
    }
}
