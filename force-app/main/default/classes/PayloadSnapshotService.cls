/**
 * Stores versioned snapshots of submitted payloads and compares the current payload with the last
 * one that was actually sent.
 *
 * Payloads are canonicalized (object keys sorted, compact output) before hashing, so key order or
 * whitespace never shows up as a change. Every snapshot records the payload schema version; when the
 * versions differ the comparison stops at SCHEMA_MISMATCH instead of producing a misleading
 * field-by-field diff between two different shapes.
 */
public with sharing class PayloadSnapshotService {
    /** Versions below 1 or missing are treated as version 1. */
    public static final Integer DEFAULT_SCHEMA_VERSION = 1;

    /** Outcome of comparing the current payload with the latest snapshot. */
    public enum ComparisonStatus {
        NO_BASELINE,
        IDENTICAL,
        CHANGED,
        SCHEMA_MISMATCH,
        INVALID_PAYLOAD
    }

    /**
     * Re-serializes JSON with object keys sorted at every level and no extra whitespace.
     *
     * @param json Any JSON document
     * @return Canonical JSON string
     * @throws SnapshotException When the input is blank or not valid JSON
     */
    public static String canonicalize(String json) {
        if (String.isBlank(json)) {
            throw new SnapshotException('Payload JSON is empty.');
        }
        Object root;
        try {
            root = JSON.deserializeUntyped(json);
        } catch (JSONException parseError) {
            throw new SnapshotException('Payload is not valid JSON: ' + parseError.getMessage(), parseError);
        }
        JSONGenerator generator = JSON.createGenerator(false);
        writeCanonical(generator, root);
        return generator.getAsString();
    }

    /**
     * Hashes the canonical form of a payload.
     *
     * @param json Any JSON document
     * @return Lowercase hex SHA-256 of the canonical form
     * @throws SnapshotException When the input is blank or not valid JSON
     */
    public static String hash(String json) {
        return digest(canonicalize(json));
    }

    /**
     * Number the next snapshot of this request will get. Also used to build a stable idempotency key
     * for the submit that will create it.
     *
     * @param requestId Generation_Request__c id
     * @return 1 for a request that was never submitted
     */
    public static Integer nextSequence(Id requestId) {
        Payload_Snapshot__c previous = latest(requestId);
        return previous == null || previous.Sequence__c == null ? 1 : previous.Sequence__c.intValue() + 1;
    }

    /**
     * Saves the request's current payload as the newest snapshot and stamps the payload hash on the
     * request in memory. The caller persists the request.
     *
     * @param request Saved Generation_Request__c with Request_JSON__c and Schema_Version__c
     * @return Inserted snapshot
     * @throws SnapshotException When the request is unsaved or its payload is not valid JSON
     */
    public static Payload_Snapshot__c capture(Generation_Request__c request) {
        if (request == null || request.Id == null) {
            throw new SnapshotException('A saved Generation Request is required to capture a snapshot.');
        }
        String canonical = canonicalize(request.Request_JSON__c);
        Payload_Snapshot__c snapshot = new Payload_Snapshot__c(
            Generation_Request__c = request.Id,
            Sequence__c = nextSequence(request.Id),
            Schema_Version__c = schemaVersionOf(request.Schema_Version__c),
            Payload_JSON__c = canonical,
            Payload_Hash__c = digest(canonical)
        );
        insert as user snapshot;
        request.Payload_Hash__c = snapshot.Payload_Hash__c;
        return snapshot;
    }

    /**
     * Returns the newest snapshot of a request.
     *
     * @param requestId Generation_Request__c id
     * @return Most recent snapshot, or null when the request was never submitted
     */
    public static Payload_Snapshot__c latest(Id requestId) {
        if (requestId == null) {
            return null;
        }
        List<Payload_Snapshot__c> snapshots = [
            SELECT Id, Name, Sequence__c, Schema_Version__c, Payload_JSON__c, Payload_Hash__c, CreatedDate
            FROM Payload_Snapshot__c
            WHERE Generation_Request__c = :requestId
            WITH USER_MODE
            ORDER BY Sequence__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 1
        ];
        return snapshots.isEmpty() ? null : snapshots[0];
    }

    /**
     * Compares the request's current payload with its latest snapshot.
     *
     * @param request Generation_Request__c with Id, Request_JSON__c and Schema_Version__c
     * @param options Diff options (array identity keys, ignored paths), may be null
     * @return Comparison result
     */
    public static Comparison compareToLatest(Generation_Request__c request, JsonDiff.Options options) {
        return compare(latest(request?.Id), request?.Request_JSON__c, schemaVersionOf(request?.Schema_Version__c), options);
    }

    /**
     * Compares a payload with a baseline snapshot.
     *
     * @param baseline Snapshot to compare against, or null
     * @param currentJson Current payload JSON
     * @param currentSchemaVersion Schema version of the current payload
     * @param options Diff options, may be null
     * @return Comparison result; changes are only populated when status is CHANGED
     */
    public static Comparison compare(Payload_Snapshot__c baseline, String currentJson, Integer currentSchemaVersion, JsonDiff.Options options) {
        Comparison result = new Comparison();
        result.baseline = baseline;
        result.currentSchemaVersion = currentSchemaVersion == null ? DEFAULT_SCHEMA_VERSION : currentSchemaVersion;

        if (baseline == null) {
            result.status = ComparisonStatus.NO_BASELINE;
            result.message = 'This request has not been submitted yet, so there is nothing to compare.';
            return result;
        }
        result.baselineSchemaVersion = schemaVersionOf(baseline.Schema_Version__c);
        if (result.baselineSchemaVersion != result.currentSchemaVersion) {
            result.status = ComparisonStatus.SCHEMA_MISMATCH;
            result.message = 'The payload format changed from schema v' + result.baselineSchemaVersion
                + ' to v' + result.currentSchemaVersion
                + '. Field-level changes are not shown because paths are not comparable across versions.';
            return result;
        }

        String canonical;
        try {
            canonical = canonicalize(currentJson);
        } catch (SnapshotException invalidPayload) {
            result.status = ComparisonStatus.INVALID_PAYLOAD;
            result.message = invalidPayload.getMessage();
            return result;
        }
        if (digest(canonical).equals(baseline.Payload_Hash__c)) {
            result.status = ComparisonStatus.IDENTICAL;
            result.message = 'No changes since the last generation.';
            return result;
        }
        result.changes = JsonDiff.compare(baseline.Payload_JSON__c, canonical, options);
        result.status = result.changes.isEmpty() ? ComparisonStatus.IDENTICAL : ComparisonStatus.CHANGED;
        result.message = result.changes.isEmpty()
            ? 'No changes since the last generation.'
            : String.valueOf(result.changes.size()) + ' change(s) since the last generation.';
        return result;
    }

    private static Integer schemaVersionOf(Decimal storedVersion) {
        if (storedVersion == null || storedVersion < 1) {
            return DEFAULT_SCHEMA_VERSION;
        }
        return storedVersion.intValue();
    }

    private static String digest(String canonical) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(canonical)));
    }

    private static void writeCanonical(JSONGenerator generator, Object node) {
        if (node instanceof Map<String, Object>) {
            writeSortedObject(generator, (Map<String, Object>) node);
        } else if (node instanceof List<Object>) {
            generator.writeStartArray();
            for (Object element : (List<Object>) node) {
                writeCanonical(generator, element);
            }
            generator.writeEndArray();
        } else if (node == null) {
            generator.writeNull();
        } else {
            generator.writeObject(node);
        }
    }

    private static void writeSortedObject(JSONGenerator generator, Map<String, Object> objectNode) {
        List<String> keys = new List<String>(objectNode.keySet());
        keys.sort();
        generator.writeStartObject();
        for (String key : keys) {
            generator.writeFieldName(key);
            writeCanonical(generator, objectNode.get(key));
        }
        generator.writeEndObject();
    }

    /**
     * Result of a payload comparison.
     */
    public class Comparison {
        public ComparisonStatus status;
        public String message;
        public Payload_Snapshot__c baseline;
        public Integer baselineSchemaVersion;
        public Integer currentSchemaVersion;
        public List<JsonDiff.Change> changes = new List<JsonDiff.Change>();
    }

    /**
     * Raised for missing or malformed payloads.
     */
    public class SnapshotException extends Exception {
    }
}
