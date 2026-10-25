/**
 * TokenCache backed by the Org Platform Cache partition local.IntegrationCache.
 *
 * Any cache failure (missing partition, zero capacity, eviction, size limits) is treated as a miss.
 * The token service then falls back to its transaction-scoped copy or requests a new token.
 */
public with sharing class PlatformCacheTokenCache implements TokenCache {
    public static final String DEFAULT_PARTITION = 'local.IntegrationCache';
    @TestVisible
    private static final Integer MIN_TTL_SECONDS = 300;
    @TestVisible
    private static final Integer MAX_TTL_SECONDS = 172800;

    private final String partitionName;
    private Cache.OrgPartition partition;
    private Boolean unavailable = false;

    /**
     * Uses the partition shipped with this project.
     */
    public PlatformCacheTokenCache() {
        this(DEFAULT_PARTITION);
    }

    /**
     * Uses a specific Org cache partition.
     *
     * @param partitionName Fully qualified partition name, for example local.IntegrationCache
     */
    public PlatformCacheTokenCache(String partitionName) {
        this.partitionName = partitionName;
    }

    /**
     * Reads a value from the partition.
     *
     * @param key Cache key
     * @return Cached string, or null on a miss or outage
     */
    public String get(String key) {
        Cache.OrgPartition orgPartition = resolvePartition();
        if (orgPartition == null) {
            return null;
        }
        try {
            Object value = orgPartition.get(key);
            return value instanceof String ? (String) value : null;
        } catch (Exception cacheError) {
            markUnavailable('get', cacheError);
            return null;
        }
    }

    /**
     * Stores the value unless the TTL is below the Platform Cache minimum of 5 minutes. Short-lived
     * tokens are then only kept for the current transaction.
     *
     * @param key Cache key
     * @param value Serialized token
     * @param ttlSeconds Seconds to keep the value, capped at 48 hours
     */
    public void put(String key, String value, Integer ttlSeconds) {
        if (ttlSeconds == null || ttlSeconds < MIN_TTL_SECONDS) {
            return;
        }
        Cache.OrgPartition orgPartition = resolvePartition();
        if (orgPartition == null) {
            return;
        }
        try {
            orgPartition.put(key, value, Math.min(ttlSeconds, MAX_TTL_SECONDS), Cache.Visibility.NAMESPACE, false);
        } catch (Exception cacheError) {
            markUnavailable('put', cacheError);
        }
    }

    /**
     * Evicts a value from the partition.
     *
     * @param key Cache key to evict
     */
    public void remove(String key) {
        Cache.OrgPartition orgPartition = resolvePartition();
        if (orgPartition == null) {
            return;
        }
        try {
            orgPartition.remove(key);
        } catch (Exception cacheError) {
            markUnavailable('remove', cacheError);
        }
    }

    private Cache.OrgPartition resolvePartition() {
        if (unavailable) {
            return null;
        }
        if (partition == null) {
            try {
                partition = Cache.Org.getPartition(partitionName);
            } catch (Exception cacheError) {
                markUnavailable('getPartition', cacheError);
            }
        }
        return partition;
    }

    private void markUnavailable(String operation, Exception cacheError) {
        unavailable = true;
        IntegrationLog.warn(
            'Platform Cache ' + operation + ' failed on ' + partitionName + ', continuing without cache: '
            + cacheError.getTypeName()
        );
    }
}
