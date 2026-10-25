/**
 * Bounded retry rules for partner API calls.
 *
 * - Only 429 and transient 5xx responses (plus transport failures) are retried. 501 is not.
 * - Delay before attempt n+1 is baseDelayMs * 2^(n-1), capped at maxDelayMs, with optional jitter.
 * - A Retry-After header (delta seconds or HTTP date) always wins over the computed backoff,
 *   capped at maxRetryAfterSeconds.
 * - Apex cannot sleep, so a delay is only waited out inline when it fits maxInlineWaitMs. Longer
 *   waits are handed back to the caller (see PartnerApiException.getRetryAfterSeconds) so an async
 *   job can reschedule itself instead of burning CPU time.
 *
 * @example
 * RetryPolicy policy = new RetryPolicy(4, 250, 4000, 1500).withJitter(0.2);
 */
public with sharing class RetryPolicy {
    private static final Integer MILLIS_PER_SECOND = 1000;
    private static final Integer DEFAULT_MAX_RETRY_AFTER_SECONDS = 600;
    private static final Map<String, Integer> MONTHS_BY_ABBREVIATION = new Map<String, Integer>{
        'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
        'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
    };

    /** Total attempts including the first one. */
    public Integer maxAttempts { get; private set; }
    /** Delay after the first failed attempt. */
    public Integer baseDelayMs { get; private set; }
    /** Upper bound for the exponential backoff. */
    public Integer maxDelayMs { get; private set; }
    /** Longest delay the client may wait out inside the current transaction. */
    public Integer maxInlineWaitMs { get; private set; }
    /** Upper bound applied to Retry-After values. */
    public Integer maxRetryAfterSeconds { get; private set; }
    /** Random extra delay as a fraction of the backoff (0 disables jitter). */
    public Decimal jitterRatio { get; private set; }

    /**
     * Defaults suited to interactive and Queueable callers: 3 attempts, 500 ms base, 4 s cap,
     * up to 2 s waited inline, 20% jitter.
     *
     * @return Default policy
     */
    public static RetryPolicy defaults() {
        return new RetryPolicy(3, 500, 4000, 2000).withJitter(0.2);
    }

    /**
     * Creates a policy without jitter and with a 10 minute Retry-After ceiling.
     *
     * @param maxAttempts Total attempts including the first (minimum 1)
     * @param baseDelayMs Backoff after the first failure in milliseconds
     * @param maxDelayMs Backoff ceiling in milliseconds
     * @param maxInlineWaitMs Longest delay that may be waited out in-transaction
     */
    public RetryPolicy(Integer maxAttempts, Integer baseDelayMs, Integer maxDelayMs, Integer maxInlineWaitMs) {
        if (maxAttempts == null || maxAttempts < 1) {
            throw new IllegalArgumentException('maxAttempts must be at least 1.');
        }
        this.maxAttempts = maxAttempts;
        this.baseDelayMs = Math.max(0, baseDelayMs == null ? 0 : baseDelayMs);
        this.maxDelayMs = Math.max(this.baseDelayMs, maxDelayMs == null ? 0 : maxDelayMs);
        this.maxInlineWaitMs = Math.max(0, maxInlineWaitMs == null ? 0 : maxInlineWaitMs);
        this.maxRetryAfterSeconds = DEFAULT_MAX_RETRY_AFTER_SECONDS;
        this.jitterRatio = 0;
    }

    /**
     * Adds random jitter so many clients do not retry in lockstep.
     *
     * @param ratio Fraction of the backoff added as random jitter, between 0 and 1
     * @return this policy, for chaining
     */
    public RetryPolicy withJitter(Decimal ratio) {
        Decimal clamped = ratio;
        if (clamped == null || clamped < 0) {
            clamped = 0;
        } else if (clamped > 1) {
            clamped = 1;
        }
        this.jitterRatio = clamped;
        return this;
    }

    /**
     * Caps how long a Retry-After header may ask us to wait.
     *
     * @param seconds Ceiling for Retry-After values
     * @return this policy, for chaining
     */
    public RetryPolicy withMaxRetryAfterSeconds(Integer seconds) {
        this.maxRetryAfterSeconds = Math.max(0, seconds == null ? 0 : seconds);
        return this;
    }

    /**
     * Tells whether a status code is worth retrying.
     *
     * @param statusCode HTTP status code
     * @return True for 429 and 5xx other than 501 Not Implemented
     */
    public Boolean isRetryableStatus(Integer statusCode) {
        if (statusCode == null) {
            return false;
        }
        return statusCode == 429 || (statusCode >= 500 && statusCode <= 599 && statusCode != 501);
    }

    /**
     * Delay to apply after a failed attempt, preferring the partner's Retry-After header.
     *
     * @param failedAttempt 1-based number of the attempt that just failed
     * @param retryAfterHeader Raw Retry-After header value, may be null
     * @return Delay in milliseconds
     */
    public Integer delayMs(Integer failedAttempt, String retryAfterHeader) {
        Integer fromHeader = retryAfterMs(retryAfterHeader, Datetime.now());
        return fromHeader != null ? fromHeader : backoffMs(failedAttempt);
    }

    /**
     * Exponential backoff with optional jitter.
     *
     * @param failedAttempt 1-based number of the attempt that just failed
     * @return Delay in milliseconds, never above maxDelayMs
     */
    public Integer backoffMs(Integer failedAttempt) {
        Integer delay = baseDelayMs;
        Integer attempt = failedAttempt == null ? 1 : failedAttempt;
        for (Integer step = 1; step < attempt && delay < maxDelayMs; step++) {
            delay = delay * 2;
        }
        delay = Math.min(delay, maxDelayMs);
        if (jitterRatio > 0 && delay > 0) {
            Decimal jitter = Decimal.valueOf(Math.random()) * delay * jitterRatio;
            delay = Math.min(delay + jitter.intValue(), maxDelayMs);
        }
        return delay;
    }

    /**
     * Parses a Retry-After header in either delta-seconds ("120") or IMF-fixdate
     * ("Wed, 21 Oct 2026 07:28:00 GMT") form.
     *
     * @param headerValue Raw header value
     * @param now Reference time for HTTP-date values
     * @return Delay in milliseconds capped at maxRetryAfterSeconds, or null when absent or unparseable
     */
    public Integer retryAfterMs(String headerValue, Datetime now) {
        if (String.isBlank(headerValue)) {
            return null;
        }
        String trimmed = headerValue.trim();
        Integer seconds;
        if (trimmed.isNumeric()) {
            seconds = trimmed.length() > 6 ? maxRetryAfterSeconds : Integer.valueOf(trimmed);
        } else {
            Datetime retryAt = parseHttpDate(trimmed);
            if (retryAt == null) {
                return null;
            }
            Long deltaSeconds = (retryAt.getTime() - now.getTime()) / MILLIS_PER_SECOND;
            if (deltaSeconds <= 0) {
                seconds = 0;
            } else {
                seconds = deltaSeconds > maxRetryAfterSeconds ? maxRetryAfterSeconds : deltaSeconds.intValue();
            }
        }
        return Math.min(seconds, maxRetryAfterSeconds) * MILLIS_PER_SECOND;
    }

    @TestVisible
    private static Datetime parseHttpDate(String value) {
        List<String> parts = value.split('\\s+');
        if (parts.size() != 6) {
            return null;
        }
        Integer month = MONTHS_BY_ABBREVIATION.get(parts[2].toLowerCase());
        List<String> clock = parts[4].split(':');
        if (month == null || clock.size() != 3) {
            return null;
        }
        try {
            return Datetime.newInstanceGmt(
                Integer.valueOf(parts[3]),
                month,
                Integer.valueOf(parts[1]),
                Integer.valueOf(clock[0]),
                Integer.valueOf(clock[1]),
                Integer.valueOf(clock[2])
            );
        } catch (TypeException badNumber) {
            return null;
        }
    }
}
