/**
 * Minimal key/value contract used by OAuthTokenService to store serialized tokens.
 * Implementations must never throw: a cache outage should only cost an extra token request.
 */
public interface TokenCache {
    /**
     * Reads a value.
     *
     * @param key Alphanumeric cache key
     * @return Stored value, or null on a miss or when the cache is unavailable
     */
    String get(String key);

    /**
     * Stores a value.
     *
     * @param key Alphanumeric cache key
     * @param value Value to store
     * @param ttlSeconds Time to live in seconds; implementations may skip values they cannot hold
     */
    void put(String key, String value, Integer ttlSeconds);

    /**
     * Evicts a value.
     *
     * @param key Alphanumeric cache key to evict
     */
    void remove(String key);
}
