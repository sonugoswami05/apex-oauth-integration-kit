/**
 * Recursive structural diff for JSON documents.
 *
 * Returns one Change per difference with a readable path, the change kind and both values:
 *
 *   $.client.name             CHANGED  "Acme" -> "Acme Ltd"
 *   $.items[1]                ADDED    {"sku":"B2","qty":1}
 *   $.items[id=A1].qty        CHANGED  2 -> 3          (when arrays are matched by an identity key)
 *   $["display name"]         REMOVED  "Old label"
 *
 * Rules:
 * - Objects are compared key by key in sorted order, so output is deterministic.
 * - A whole subtree that appears or disappears is reported once at its root, not per leaf.
 * - A value whose JSON type changes (string to number, object to array, null to value) is CHANGED
 *   with oldType/newType filled in.
 * - Numbers compare by value (1 equals 1.0). Strings compare case-sensitively; Apex == would not.
 * - Arrays compare by index unless every element on both sides is an object with a unique scalar
 *   value for one of Options.identityKeys; then elements are matched by that key, so inserting or
 *   reordering items does not report every later element as changed.
 * - Paths listed in Options.ignoredPaths (and everything below them) are skipped.
 *
 * @example
 * List<JsonDiff.Change> changes = JsonDiff.compare(oldJson, newJson,
 *     new JsonDiff.Options().matchArraysBy('id').ignore('$.generatedAt'));
 */
public with sharing class JsonDiff {
    public static final String ROOT = '$';
    public static final String TYPE_NULL = 'null';
    public static final String TYPE_OBJECT = 'object';
    public static final String TYPE_ARRAY = 'array';
    public static final String TYPE_STRING = 'string';
    public static final String TYPE_NUMBER = 'number';
    public static final String TYPE_BOOLEAN = 'boolean';

    private static final Pattern SIMPLE_KEY = Pattern.compile('^[A-Za-z_][A-Za-z0-9_]*$');

    /** Kind of difference found at a path. */
    public enum ChangeType {
        ADDED,
        REMOVED,
        CHANGED
    }

    /**
     * Compares two JSON strings with default options. Blank input is treated as JSON null.
     *
     * @param oldJson Previous document
     * @param newJson Current document
     * @return Changes in deterministic order; empty when the documents are equivalent
     * @throws JsonDiffException When either input is not valid JSON
     */
    public static List<Change> compare(String oldJson, String newJson) {
        return compare(oldJson, newJson, new Options());
    }

    /**
     * Compares two JSON strings using the given options. Blank input is treated as JSON null.
     *
     * @param oldJson Previous document
     * @param newJson Current document
     * @param options Array identity keys and ignored paths
     * @return Changes in deterministic order; empty when the documents are equivalent
     * @throws JsonDiffException When either input is not valid JSON
     */
    public static List<Change> compare(String oldJson, String newJson, Options options) {
        return compareNodes(parse(oldJson, 'old'), parse(newJson, 'new'), options);
    }

    /**
     * Compares two already parsed nodes (output of JSON.deserializeUntyped).
     *
     * @param oldNode Previous value
     * @param newNode Current value
     * @param options Array identity keys and ignored paths, may be null
     * @return Changes in deterministic order
     */
    public static List<Change> compareNodes(Object oldNode, Object newNode, Options options) {
        Walker walker = new Walker(options == null ? new Options() : options);
        walker.diffNode(ROOT, oldNode, newNode);
        return walker.changes;
    }

    /**
     * Classifies a parsed JSON value.
     *
     * @param value Parsed JSON value
     * @return One of the TYPE_* constants
     */
    public static String typeOf(Object value) {
        if (value == null) {
            return TYPE_NULL;
        }
        if (value instanceof Map<String, Object>) {
            return TYPE_OBJECT;
        }
        if (value instanceof List<Object>) {
            return TYPE_ARRAY;
        }
        if (value instanceof Boolean) {
            return TYPE_BOOLEAN;
        }
        if (value instanceof Integer || value instanceof Long || value instanceof Decimal || value instanceof Double) {
            return TYPE_NUMBER;
        }
        return TYPE_STRING;
    }

    /**
     * Renders a value for display: strings as-is, containers as compact JSON.
     *
     * @param value Parsed JSON value
     * @param maxLength Maximum length; longer output is abbreviated with "..."
     * @return Display text, "null" for JSON null
     */
    public static String formatValue(Object value, Integer maxLength) {
        String text;
        String valueType = typeOf(value);
        if (valueType == TYPE_NULL) {
            text = 'null';
        } else if (valueType == TYPE_OBJECT || valueType == TYPE_ARRAY) {
            text = JSON.serialize(value);
        } else {
            text = String.valueOf(value);
        }
        return (maxLength != null && maxLength > 3) ? text.abbreviate(maxLength) : text;
    }

    private static Object parse(String json, String label) {
        if (String.isBlank(json)) {
            return null;
        }
        try {
            return JSON.deserializeUntyped(json);
        } catch (JSONException parseError) {
            throw new JsonDiffException('The ' + label + ' document is not valid JSON: ' + parseError.getMessage(), parseError);
        }
    }

    private static Boolean isKeyedBy(List<Object> elements, String identityKey) {
        Set<String> seen = new Set<String>();
        for (Object element : elements) {
            if (!(element instanceof Map<String, Object>)) {
                return false;
            }
            Object keyValue = ((Map<String, Object>) element).get(identityKey);
            String keyType = typeOf(keyValue);
            if (keyType != TYPE_STRING && keyType != TYPE_NUMBER && keyType != TYPE_BOOLEAN) {
                return false;
            }
            if (!seen.add(String.valueOf(keyValue))) {
                return false;
            }
        }
        return true;
    }

    private static Map<String, Object> indexByIdentity(List<Object> elements, String identityKey) {
        Map<String, Object> elementsById = new Map<String, Object>();
        for (Object element : elements) {
            elementsById.put(identityOf(element, identityKey), element);
        }
        return elementsById;
    }

    private static String identityOf(Object element, String identityKey) {
        return String.valueOf(((Map<String, Object>) element).get(identityKey));
    }

    private static Boolean scalarsEqual(String valueType, Object oldValue, Object newValue) {
        if (valueType == TYPE_NULL) {
            return true;
        }
        if (valueType == TYPE_NUMBER) {
            Decimal difference = toDecimal(oldValue) - toDecimal(newValue);
            return difference == 0;
        }
        if (valueType == TYPE_BOOLEAN) {
            return (Boolean) oldValue == (Boolean) newValue;
        }
        // String.equals is case-sensitive; the == operator on strings is not.
        return String.valueOf(oldValue).equals(String.valueOf(newValue));
    }

    private static Decimal toDecimal(Object value) {
        return Decimal.valueOf(String.valueOf(value));
    }

    private static String childPath(String parentPath, String key) {
        if (SIMPLE_KEY.matcher(key).matches()) {
            return parentPath + '.' + key;
        }
        return parentPath + '["' + key.replace('\\', '\\\\').replace('"', '\\"') + '"]';
    }

    /**
     * One difference between the two documents.
     */
    public class Change {
        public ChangeType kind;
        public String path;
        public Object oldValue;
        public Object newValue;
        /** JSON type of oldValue, or null when the path was ADDED. */
        public String oldType;
        /** JSON type of newValue, or null when the path was REMOVED. */
        public String newType;

        /**
         * Creates a change and records the JSON type of each side.
         *
         * @param kind ADDED, REMOVED or CHANGED
         * @param path Path of the difference, rooted at $
         * @param oldValue Previous value (null for ADDED)
         * @param newValue Current value (null for REMOVED)
         */
        public Change(ChangeType kind, String path, Object oldValue, Object newValue) {
            this.kind = kind;
            this.path = path;
            this.oldValue = oldValue;
            this.newValue = newValue;
            this.oldType = kind == ChangeType.ADDED ? null : typeOf(oldValue);
            this.newType = kind == ChangeType.REMOVED ? null : typeOf(newValue);
        }

        /**
         * Tells whether the value switched JSON type, for example string to number.
         *
         * @return True when a CHANGED value also switched JSON type
         */
        public Boolean isTypeChange() {
            return kind == ChangeType.CHANGED && oldType != null && !oldType.equals(newType);
        }
    }

    /**
     * Comparison settings.
     */
    public class Options {
        /** Field names that identify array elements, for example id or sku. */
        public Set<String> identityKeys = new Set<String>();
        /** Paths skipped together with everything below them, for example $.generatedAt. */
        public Set<String> ignoredPaths = new Set<String>();

        /**
         * Adds a field used to match array elements by identity instead of position.
         *
         * @param identityKey Field that uniquely identifies elements of object arrays
         * @return this options instance, for chaining
         */
        public Options matchArraysBy(String identityKey) {
            if (String.isNotBlank(identityKey)) {
                identityKeys.add(identityKey);
            }
            return this;
        }

        /**
         * Skips a path and everything below it.
         *
         * @param path Path to skip, rooted at $
         * @return this options instance, for chaining
         */
        public Options ignore(String path) {
            if (String.isNotBlank(path)) {
                ignoredPaths.add(path);
            }
            return this;
        }

        /**
         * Checks a path against the ignored paths.
         *
         * @param path Path being compared
         * @return True when the path or one of its ancestors is ignored
         */
        public Boolean isIgnored(String path) {
            if (ignoredPaths.isEmpty()) {
                return false;
            }
            for (String ignoredPath : ignoredPaths) {
                if (path.equals(ignoredPath) || path.startsWith(ignoredPath + '.') || path.startsWith(ignoredPath + '[')) {
                    return true;
                }
            }
            return false;
        }
    }

    /**
     * Holds the options and the result list for one comparison so the recursive helpers stay small.
     */
    private class Walker {
        private final Options options;
        public final List<Change> changes = new List<Change>();

        /**
         * Starts a comparison.
         *
         * @param options Comparison settings
         */
        public Walker(Options options) {
            this.options = options;
        }

        /**
         * Compares two values at a path and records any differences.
         *
         * @param path Path of the values, rooted at $
         * @param oldNode Previous value
         * @param newNode Current value
         */
        public void diffNode(String path, Object oldNode, Object newNode) {
            if (options.isIgnored(path)) {
                return;
            }
            String oldType = typeOf(oldNode);
            String newType = typeOf(newNode);
            if (!oldType.equals(newType)) {
                changes.add(new Change(ChangeType.CHANGED, path, oldNode, newNode));
            } else if (oldType == TYPE_OBJECT) {
                diffObjects(path, (Map<String, Object>) oldNode, (Map<String, Object>) newNode);
            } else if (oldType == TYPE_ARRAY) {
                diffArrays(path, (List<Object>) oldNode, (List<Object>) newNode);
            } else if (!scalarsEqual(oldType, oldNode, newNode)) {
                changes.add(new Change(ChangeType.CHANGED, path, oldNode, newNode));
            }
        }

        private void diffObjects(String path, Map<String, Object> oldMap, Map<String, Object> newMap) {
            Set<String> allKeys = new Set<String>(oldMap.keySet());
            allKeys.addAll(newMap.keySet());
            List<String> sortedKeys = new List<String>(allKeys);
            sortedKeys.sort();
            for (String key : sortedKeys) {
                String keyPath = childPath(path, key);
                Boolean inOld = oldMap.containsKey(key);
                Boolean inNew = newMap.containsKey(key);
                if (inOld && inNew) {
                    diffNode(keyPath, oldMap.get(key), newMap.get(key));
                } else if (inNew) {
                    addIfTracked(new Change(ChangeType.ADDED, keyPath, null, newMap.get(key)));
                } else {
                    addIfTracked(new Change(ChangeType.REMOVED, keyPath, oldMap.get(key), null));
                }
            }
        }

        private void diffArrays(String path, List<Object> oldList, List<Object> newList) {
            String identityKey = findIdentityKey(oldList, newList);
            if (identityKey == null) {
                diffArraysByIndex(path, oldList, newList);
            } else {
                diffArraysByKey(path, identityKey, oldList, newList);
            }
        }

        private void diffArraysByIndex(String path, List<Object> oldList, List<Object> newList) {
            Integer longest = Math.max(oldList.size(), newList.size());
            for (Integer index = 0; index < longest; index++) {
                String elementPath = path + '[' + index + ']';
                if (index < oldList.size() && index < newList.size()) {
                    diffNode(elementPath, oldList[index], newList[index]);
                } else if (index < newList.size()) {
                    addIfTracked(new Change(ChangeType.ADDED, elementPath, null, newList[index]));
                } else {
                    addIfTracked(new Change(ChangeType.REMOVED, elementPath, oldList[index], null));
                }
            }
        }

        private void diffArraysByKey(String path, String identityKey, List<Object> oldList, List<Object> newList) {
            Map<String, Object> newById = indexByIdentity(newList, identityKey);
            Set<String> oldIds = new Set<String>();
            for (Object element : oldList) {
                String identity = identityOf(element, identityKey);
                oldIds.add(identity);
                String elementPath = path + '[' + identityKey + '=' + identity + ']';
                if (newById.containsKey(identity)) {
                    diffNode(elementPath, element, newById.get(identity));
                } else {
                    addIfTracked(new Change(ChangeType.REMOVED, elementPath, element, null));
                }
            }
            for (Object element : newList) {
                String identity = identityOf(element, identityKey);
                if (!oldIds.contains(identity)) {
                    String elementPath = path + '[' + identityKey + '=' + identity + ']';
                    addIfTracked(new Change(ChangeType.ADDED, elementPath, null, element));
                }
            }
        }

        private String findIdentityKey(List<Object> oldList, List<Object> newList) {
            if (options.identityKeys.isEmpty() || (oldList.isEmpty() && newList.isEmpty())) {
                return null;
            }
            List<String> candidates = new List<String>(options.identityKeys);
            candidates.sort();
            for (String candidate : candidates) {
                if (isKeyedBy(oldList, candidate) && isKeyedBy(newList, candidate)) {
                    return candidate;
                }
            }
            return null;
        }

        private void addIfTracked(Change change) {
            if (!options.isIgnored(change.path)) {
                changes.add(change);
            }
        }
    }

    /**
     * Raised when an input is not valid JSON.
     */
    public class JsonDiffException extends Exception {
    }
}
