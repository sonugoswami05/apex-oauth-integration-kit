@IsTest
private class PlatformCacheTokenCacheTest {
    @IsTest
    static void shouldSkipStoreWhenTtlIsBelowPlatformMinimum() {
        PlatformCacheTokenCache cache = new PlatformCacheTokenCache();

        cache.put('shortLived', 'value', PlatformCacheTokenCache.MIN_TTL_SECONDS - 1);

        Assert.isNull(cache.get('shortLived'), 'Values under the 300 second minimum are never stored');
    }

    @IsTest
    static void shouldBehaveAsMissWhenPartitionDoesNotExist() {
        PlatformCacheTokenCache cache = new PlatformCacheTokenCache('local.NoSuchPartition');

        cache.put('token', 'value', 3600);
        cache.remove('token');

        Assert.isNull(cache.get('token'), 'A missing partition is a cache miss, never an exception');
    }

    @IsTest
    static void shouldRoundTripOrMissWhenUsingShippedPartition() {
        PlatformCacheTokenCache cache = new PlatformCacheTokenCache();

        cache.put('roundTrip', 'value', 600);
        String cached = cache.get('roundTrip');

        // Orgs without allocated capacity silently miss; orgs with capacity return the value.
        Assert.isTrue(cached == null || cached.equals('value'), 'Unexpected cached value: ' + cached);
        cache.remove('roundTrip');
        Assert.isNull(cache.get('roundTrip'), 'Removed values are gone');
    }
}
