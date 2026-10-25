/**
 * Hand-written test doubles for the kit's seams: token cache, sleeper and job scheduler.
 */
@IsTest
public class TestDoubles {
    /**
     * Fast, jitter-free policy: 3 attempts, 100 ms base, 1 s cap, 2 s inline budget.
     *
     * @return Deterministic retry policy
     */
    public static RetryPolicy fastPolicy() {
        return new RetryPolicy(3, 100, 1000, 2000);
    }

    /**
     * @param cache Token cache to use
     * @param sleeper Sleeper to use
     * @return Client wired with test doubles and the fast policy
     */
    public static PartnerApiClient client(TokenCache cache, PartnerApiClient.Sleeper sleeper) {
        return new PartnerApiClient(new OAuthTokenService(cache), fastPolicy(), sleeper);
    }

    /**
     * @return Client with an empty in-memory cache and a recording sleeper
     */
    public static PartnerApiClient client() {
        return client(new InMemoryTokenCache(), new RecordingSleeper());
    }

    /**
     * Map-backed TokenCache that records TTLs and removals.
     */
    public class InMemoryTokenCache implements TokenCache {
        public Map<String, String> values = new Map<String, String>();
        public Map<String, Integer> ttls = new Map<String, Integer>();
        public Integer removals = 0;

        public String get(String key) {
            return values.get(key);
        }

        public void put(String key, String value, Integer ttlSeconds) {
            values.put(key, value);
            ttls.put(key, ttlSeconds);
        }

        public void remove(String key) {
            values.remove(key);
            removals++;
        }
    }

    /**
     * Sleeper that records requested delays instead of waiting.
     */
    public class RecordingSleeper implements PartnerApiClient.Sleeper {
        public List<Integer> delays = new List<Integer>();

        public void sleep(Integer milliseconds) {
            delays.add(milliseconds);
        }
    }

    /**
     * Scheduler that records chained jobs instead of enqueuing them.
     */
    public class RecordingScheduler implements DocumentGenerationJob.JobScheduler {
        public List<Queueable> jobs = new List<Queueable>();
        public List<Integer> delays = new List<Integer>();

        public Id schedule(Queueable job, Integer delayMinutes) {
            jobs.add(job);
            delays.add(delayMinutes);
            return null;
        }
    }
}
