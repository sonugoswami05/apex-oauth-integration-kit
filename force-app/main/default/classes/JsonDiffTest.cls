@IsTest
private class JsonDiffTest {
    private static JsonDiff.Change only(List<JsonDiff.Change> changes) {
        Assert.areEqual(1, changes.size(), 'Expected exactly one change but got ' + JSON.serialize(changes));
        return changes[0];
    }

    private static List<String> pathsOf(List<JsonDiff.Change> changes) {
        List<String> paths = new List<String>();
        for (JsonDiff.Change change : changes) {
            paths.add(change.kind.name() + ' ' + change.path);
        }
        return paths;
    }

    @IsTest
    static void shouldReturnNoChangesWhenDocumentsDifferOnlyInKeyOrderAndWhitespace() {
        String oldJson = '{"b":1,"a":{"y":[1,2],"x":"v"}}';
        String newJson = '{ "a" : { "x" : "v", "y" : [ 1, 2 ] }, "b" : 1 }';

        List<JsonDiff.Change> changes = JsonDiff.compare(oldJson, newJson);

        Assert.isTrue(changes.isEmpty(), 'Equivalent documents should produce no changes');
    }

    @IsTest
    static void shouldReportFullPathWhenNestedScalarChanges() {
        String oldJson = '{"client":{"address":{"city":"Springfield"}}}';
        String newJson = '{"client":{"address":{"city":"Shelbyville"}}}';

        JsonDiff.Change change = only(JsonDiff.compare(oldJson, newJson));

        Assert.areEqual(JsonDiff.ChangeType.CHANGED, change.kind, 'Kind');
        Assert.areEqual('$.client.address.city', change.path, 'Path');
        Assert.areEqual('Springfield', change.oldValue, 'Old value');
        Assert.areEqual('Shelbyville', change.newValue, 'New value');
        Assert.isFalse(change.isTypeChange(), 'Same JSON type');
    }

    @IsTest
    static void shouldReportSubtreeOnceWhenObjectIsAddedOrRemoved() {
        String oldJson = '{"keep":1,"legacy":{"a":1,"b":{"c":2}}}';
        String newJson = '{"keep":1,"billing":{"terms":"net30","contact":{"email":"ap@example.com"}}}';

        List<JsonDiff.Change> changes = JsonDiff.compare(oldJson, newJson);

        Assert.areEqual(new List<String>{ 'ADDED $.billing', 'REMOVED $.legacy' }, pathsOf(changes), 'One change per subtree, sorted by key');
        Assert.isNull(changes[0].oldType, 'Added values have no old type');
        Assert.areEqual(JsonDiff.TYPE_OBJECT, changes[0].newType, 'Added subtree type');
        Assert.areEqual(JsonDiff.TYPE_OBJECT, changes[1].oldType, 'Removed subtree type');
        Assert.isNull(changes[1].newType, 'Removed values have no new type');
    }

    @IsTest
    static void shouldFlagTypeChangeWhenStringBecomesNumber() {
        JsonDiff.Change change = only(JsonDiff.compare('{"amount":"100"}', '{"amount":100}'));

        Assert.areEqual('$.amount', change.path, 'Path');
        Assert.areEqual(JsonDiff.TYPE_STRING, change.oldType, 'Old type');
        Assert.areEqual(JsonDiff.TYPE_NUMBER, change.newType, 'New type');
        Assert.isTrue(change.isTypeChange(), 'Type change flag');
    }

    @IsTest
    static void shouldReportContainerOnceWhenObjectBecomesArray() {
        JsonDiff.Change change = only(JsonDiff.compare('{"tags":{"a":true}}', '{"tags":["a"]}'));

        Assert.areEqual('$.tags', change.path, 'Container replaced at its own path');
        Assert.areEqual(JsonDiff.TYPE_OBJECT, change.oldType, 'Old type');
        Assert.areEqual(JsonDiff.TYPE_ARRAY, change.newType, 'New type');
    }

    @IsTest
    static void shouldReportChangeWhenNullBecomesValue() {
        JsonDiff.Change change = only(JsonDiff.compare('{"notes":null}', '{"notes":"Rush order"}'));

        Assert.areEqual(JsonDiff.ChangeType.CHANGED, change.kind, 'Explicit null to value is a change, not an add');
        Assert.areEqual(JsonDiff.TYPE_NULL, change.oldType, 'Old type');
    }

    @IsTest
    static void shouldTreatNumbersByValueWhenScaleDiffers() {
        List<JsonDiff.Change> changes = JsonDiff.compare('{"price":450,"rate":0.5}', '{"price":450.00,"rate":0.50}');

        Assert.isTrue(changes.isEmpty(), '450 and 450.00 are the same number');
    }

    @IsTest
    static void shouldDetectChangeWhenOnlyLetterCaseDiffers() {
        JsonDiff.Change change = only(JsonDiff.compare('{"name":"acme"}', '{"name":"ACME"}'));

        Assert.areEqual('$.name', change.path, 'Apex == ignores case, the diff must not');
    }

    @IsTest
    static void shouldDetectChangeWhenBooleanFlips() {
        JsonDiff.Change change = only(JsonDiff.compare('{"active":true}', '{"active":false}'));

        Assert.areEqual(true, change.oldValue, 'Old value');
        Assert.areEqual(false, change.newValue, 'New value');
    }

    @IsTest
    static void shouldReportAddedElementWhenArrayGrows() {
        JsonDiff.Change change = only(JsonDiff.compare('{"items":[1,2]}', '{"items":[1,2,3]}'));

        Assert.areEqual(JsonDiff.ChangeType.ADDED, change.kind, 'Kind');
        Assert.areEqual('$.items[2]', change.path, 'Index path');
        Assert.areEqual(3, change.newValue, 'Added value');
    }

    @IsTest
    static void shouldReportRemovedElementWhenArrayShrinks() {
        JsonDiff.Change change = only(JsonDiff.compare('{"items":["a","b"]}', '{"items":["a"]}'));

        Assert.areEqual(JsonDiff.ChangeType.REMOVED, change.kind, 'Kind');
        Assert.areEqual('$.items[1]', change.path, 'Index path');
    }

    @IsTest
    static void shouldDescendIntoArrayElementsWhenMatchingByIndex() {
        String oldJson = '{"items":[{"sku":"A","qty":1},{"sku":"B","qty":1}]}';
        String newJson = '{"items":[{"sku":"A","qty":1},{"sku":"B","qty":4}]}';

        JsonDiff.Change change = only(JsonDiff.compare(oldJson, newJson));

        Assert.areEqual('$.items[1].qty', change.path, 'Nested path inside array element');
    }

    @IsTest
    static void shouldIgnoreReorderingWhenArrayMatchedByIdentityKey() {
        String oldJson = '{"items":[{"id":"A1","qty":2},{"id":"B2","qty":1}]}';
        String newJson = '{"items":[{"id":"B2","qty":1},{"id":"A1","qty":2}]}';

        List<JsonDiff.Change> changes = JsonDiff.compare(oldJson, newJson, new JsonDiff.Options().matchArraysBy('id'));

        Assert.isTrue(changes.isEmpty(), 'Same elements in a different order are not changes');
    }

    @IsTest
    static void shouldUseIdentityPathsWhenKeyedArrayChanges() {
        String oldJson = '{"items":[{"id":"A1","qty":2},{"id":"B2","qty":1},{"id":"C3","qty":5}]}';
        String newJson = '{"items":[{"id":"N9","qty":1},{"id":"A1","qty":3},{"id":"C3","qty":5}]}';

        List<JsonDiff.Change> changes = JsonDiff.compare(oldJson, newJson, new JsonDiff.Options().matchArraysBy('id'));

        Assert.areEqual(
            new List<String>{ 'CHANGED $.items[id=A1].qty', 'REMOVED $.items[id=B2]', 'ADDED $.items[id=N9]' },
            pathsOf(changes),
            'Insert at the front must not cascade into every later element'
        );
    }

    @IsTest
    static void shouldFallBackToIndexWhenIdentityKeyIsNotUnique() {
        String oldJson = '{"items":[{"id":"A","qty":1},{"id":"A","qty":2}]}';
        String newJson = '{"items":[{"id":"A","qty":1},{"id":"A","qty":3}]}';

        JsonDiff.Change change = only(JsonDiff.compare(oldJson, newJson, new JsonDiff.Options().matchArraysBy('id')));

        Assert.areEqual('$.items[1].qty', change.path, 'Duplicate identities fall back to index matching');
    }

    @IsTest
    static void shouldFallBackToIndexWhenElementsAreNotObjects() {
        JsonDiff.Change change = only(JsonDiff.compare('[1,2]', '[1,5]', new JsonDiff.Options().matchArraysBy('id')));

        Assert.areEqual('$[1]', change.path, 'Scalar arrays are compared by index');
    }

    @IsTest
    static void shouldSkipSubtreeWhenPathIsIgnored() {
        String oldJson = '{"generatedAt":"2026-01-01T00:00:00Z","meta":{"trace":"a","source":"crm"},"total":10}';
        String newJson = '{"generatedAt":"2026-02-01T00:00:00Z","meta":{"trace":"b","source":"crm"},"total":12}';
        JsonDiff.Options options = new JsonDiff.Options().ignore('$.generatedAt').ignore('$.meta');

        JsonDiff.Change change = only(JsonDiff.compare(oldJson, newJson, options));

        Assert.areEqual('$.total', change.path, 'Only the tracked path is reported');
    }

    @IsTest
    static void shouldSkipAddedValueWhenPathIsIgnored() {
        List<JsonDiff.Change> changes = JsonDiff.compare('{}', '{"debug":{"x":1}}', new JsonDiff.Options().ignore('$.debug'));

        Assert.isTrue(changes.isEmpty(), 'Additions under an ignored path are skipped');
    }

    @IsTest
    static void shouldUseBracketNotationWhenKeyIsNotAnIdentifier() {
        JsonDiff.Change change = only(JsonDiff.compare('{"display name":"a"}', '{"display name":"b"}'));

        Assert.areEqual('$["display name"]', change.path, 'Keys with spaces use bracket notation');
    }

    @IsTest
    static void shouldEscapeQuotesWhenKeyContainsQuote() {
        JsonDiff.Change change = only(JsonDiff.compare('{"say \\"hi\\"":1}', '{"say \\"hi\\"":2}'));

        Assert.areEqual('$["say \\"hi\\""]', change.path, 'Quotes inside keys are escaped');
    }

    @IsTest
    static void shouldReportRootChangeWhenDocumentTypeDiffers() {
        JsonDiff.Change change = only(JsonDiff.compare('[1]', '{"a":1}'));

        Assert.areEqual(JsonDiff.ROOT, change.path, 'Root path');
        Assert.isTrue(change.isTypeChange(), 'Array replaced by object');
    }

    @IsTest
    static void shouldTreatBlankAsNullWhenOldDocumentIsMissing() {
        JsonDiff.Change change = only(JsonDiff.compare('', '{"a":1}'));

        Assert.areEqual(JsonDiff.ChangeType.CHANGED, change.kind, 'Kind');
        Assert.areEqual(JsonDiff.TYPE_NULL, change.oldType, 'Blank input is JSON null');
    }

    @IsTest
    static void shouldThrowWhenInputIsNotJson() {
        try {
            JsonDiff.compare('{"a":1}', '{not json');
            Assert.fail('Expected JsonDiffException');
        } catch (JsonDiff.JsonDiffException expected) {
            Assert.isTrue(expected.getMessage().contains('new document'), 'Message names the bad side: ' + expected.getMessage());
        }
    }

    @IsTest
    static void shouldUseDefaultOptionsWhenOptionsAreNull() {
        List<JsonDiff.Change> changes = JsonDiff.compareNodes(new Map<String, Object>{ 'a' => 1 }, new Map<String, Object>{ 'a' => 2 }, null);

        Assert.areEqual(1, changes.size(), 'Null options behave like defaults');
    }

    @IsTest
    static void shouldReturnSortedDeterministicOrderWhenManyKeysChange() {
        List<JsonDiff.Change> changes = JsonDiff.compare('{"c":1,"a":1,"b":1}', '{"b":2,"c":2,"a":2}');

        Assert.areEqual(new List<String>{ 'CHANGED $.a', 'CHANGED $.b', 'CHANGED $.c' }, pathsOf(changes), 'Sorted by key');
    }

    @IsTest
    static void shouldFormatValuesForDisplay() {
        Assert.areEqual('null', JsonDiff.formatValue(null, 50), 'Null');
        Assert.areEqual('{"a":1}', JsonDiff.formatValue(new Map<String, Object>{ 'a' => 1 }, 50), 'Object as JSON');
        Assert.areEqual('[1,2]', JsonDiff.formatValue(new List<Object>{ 1, 2 }, 50), 'Array as JSON');
        Assert.areEqual('abcdefg...', JsonDiff.formatValue('abcdefghijklmnop', 10), 'Abbreviated');
        Assert.areEqual('42', JsonDiff.formatValue(42, null), 'Number without limit');
    }

    @IsTest
    static void shouldClassifyTypesForEveryJsonKind() {
        Assert.areEqual(JsonDiff.TYPE_NULL, JsonDiff.typeOf(null), 'null');
        Assert.areEqual(JsonDiff.TYPE_OBJECT, JsonDiff.typeOf(new Map<String, Object>()), 'object');
        Assert.areEqual(JsonDiff.TYPE_ARRAY, JsonDiff.typeOf(new List<Object>()), 'array');
        Assert.areEqual(JsonDiff.TYPE_STRING, JsonDiff.typeOf('x'), 'string');
        Assert.areEqual(JsonDiff.TYPE_NUMBER, JsonDiff.typeOf(1.5), 'number');
        Assert.areEqual(JsonDiff.TYPE_BOOLEAN, JsonDiff.typeOf(true), 'boolean');
    }
}
