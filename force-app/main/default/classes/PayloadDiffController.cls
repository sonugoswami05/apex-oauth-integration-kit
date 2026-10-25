/**
 * Backs the payloadDiffViewer LWC: shows what changed in a Generation_Request__c payload since the
 * last generation, and starts a regeneration once the user confirms.
 */
public with sharing class PayloadDiffController {
    @TestVisible
    private static final Integer MAX_ROWS = 500;
    private static final Integer MAX_VALUE_LENGTH = 500;
    private static final Set<String> REGENERABLE_STATUSES = new Set<String>{
        DocumentGenerationJob.STATUS_DRAFT,
        DocumentGenerationJob.STATUS_COMPLETE,
        DocumentGenerationJob.STATUS_FAILED
    };

    /**
     * Compares the request's current payload with the latest submitted snapshot.
     *
     * @param requestId Generation_Request__c id
     * @return View model for the diff viewer
     * @throws AuraHandledException When the record is missing, inaccessible or cannot be compared
     */
    @AuraEnabled(cacheable=true)
    public static DiffView getPayloadDiff(Id requestId) {
        Generation_Request__c request = loadRequest(requestId);
        if (request == null) {
            throw auraError('Generation request not found or you do not have access to it.');
        }
        try {
            PayloadSnapshotService.Comparison comparison = PayloadSnapshotService.compareToLatest(request, diffOptions());
            return toView(request, comparison);
        } catch (JsonDiff.JsonDiffException diffError) {
            throw auraError('The last submitted payload could not be read: ' + diffError.getMessage());
        } catch (QueryException queryError) {
            throw auraError('You do not have access to the payload history of this request.');
        }
    }

    /**
     * Starts a new generation run for the request.
     *
     * @param requestId Generation_Request__c id
     * @return Id of the enqueued job
     * @throws AuraHandledException When a run is already active or the payload is invalid
     */
    @AuraEnabled
    public static Id requestRegeneration(Id requestId) {
        try {
            return DocumentGenerationJob.start(requestId);
        } catch (DocumentGenerationJob.GenerationException startError) {
            throw auraError(startError.getMessage());
        } catch (DmlException saveError) {
            throw auraError('The request could not be updated: ' + saveError.getDmlMessage(0));
        } catch (AsyncException queueError) {
            throw auraError('The generation job could not be queued. Please try again in a few minutes.');
        }
    }

    /**
     * Identity keys used to match array elements in this kit's payloads. Adjust to your payload.
     *
     * @return Diff options for the viewer
     */
    private static JsonDiff.Options diffOptions() {
        return new JsonDiff.Options().matchArraysBy('id').matchArraysBy('key').matchArraysBy('sku');
    }

    private static Generation_Request__c loadRequest(Id requestId) {
        if (requestId == null) {
            return null;
        }
        List<Generation_Request__c> requests = [
            SELECT Id, Name, Status__c, Request_JSON__c, Schema_Version__c, Payload_Hash__c
            FROM Generation_Request__c
            WHERE Id = :requestId
            WITH USER_MODE
            LIMIT 1
        ];
        return requests.isEmpty() ? null : requests[0];
    }

    private static DiffView toView(Generation_Request__c request, PayloadSnapshotService.Comparison comparison) {
        DiffView view = new DiffView();
        view.status = comparison.status.name();
        view.message = comparison.message;
        view.requestStatus = request.Status__c;
        view.canRegenerate = String.isBlank(request.Status__c) || REGENERABLE_STATUSES.contains(request.Status__c);
        view.currentSchemaVersion = comparison.currentSchemaVersion;
        view.baselineSchemaVersion = comparison.baselineSchemaVersion;
        if (comparison.baseline != null) {
            view.baselineName = comparison.baseline.Name;
            view.baselineSequence = comparison.baseline.Sequence__c?.intValue();
            view.baselineCapturedOn = comparison.baseline.CreatedDate;
        }
        for (JsonDiff.Change change : comparison.changes) {
            countChange(view, change.kind);
            if (view.rows.size() < MAX_ROWS) {
                view.rows.add(toRow(change, view.rows.size()));
            }
        }
        view.truncated = comparison.changes.size() > MAX_ROWS;
        return view;
    }

    private static void countChange(DiffView view, JsonDiff.ChangeType kind) {
        if (kind == JsonDiff.ChangeType.ADDED) {
            view.addedCount++;
        } else if (kind == JsonDiff.ChangeType.REMOVED) {
            view.removedCount++;
        } else {
            view.changedCount++;
        }
    }

    private static DiffRow toRow(JsonDiff.Change change, Integer index) {
        DiffRow row = new DiffRow();
        row.key = String.valueOf(index);
        row.path = change.path;
        row.kind = change.kind.name().toLowerCase();
        row.oldValue = change.kind == JsonDiff.ChangeType.ADDED ? null : JsonDiff.formatValue(change.oldValue, MAX_VALUE_LENGTH);
        row.newValue = change.kind == JsonDiff.ChangeType.REMOVED ? null : JsonDiff.formatValue(change.newValue, MAX_VALUE_LENGTH);
        row.oldType = change.oldType;
        row.newType = change.newType;
        row.typeChanged = change.isTypeChange();
        return row;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    /**
     * Diff summary returned to the LWC.
     */
    public class DiffView {
        /** NO_BASELINE, IDENTICAL, CHANGED, SCHEMA_MISMATCH or INVALID_PAYLOAD. */
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public String requestStatus;
        @AuraEnabled public Boolean canRegenerate = false;
        @AuraEnabled public String baselineName;
        @AuraEnabled public Integer baselineSequence;
        @AuraEnabled public Datetime baselineCapturedOn;
        @AuraEnabled public Integer baselineSchemaVersion;
        @AuraEnabled public Integer currentSchemaVersion;
        @AuraEnabled public Integer addedCount = 0;
        @AuraEnabled public Integer removedCount = 0;
        @AuraEnabled public Integer changedCount = 0;
        @AuraEnabled public Boolean truncated = false;
        @AuraEnabled public List<DiffRow> rows = new List<DiffRow>();
    }

    /**
     * One changed path.
     */
    public class DiffRow {
        @AuraEnabled public String key;
        @AuraEnabled public String path;
        /** added, removed or changed. */
        @AuraEnabled public String kind;
        @AuraEnabled public String oldValue;
        @AuraEnabled public String newValue;
        @AuraEnabled public String oldType;
        @AuraEnabled public String newType;
        @AuraEnabled public Boolean typeChanged = false;
    }
}
