@IsTest
private class RetryPolicyTest {
    @IsTest
    static void shouldDoubleBackoffUntilCapWhenJitterDisabled() {
        RetryPolicy policy = new RetryPolicy(6, 100, 1000, 2000);

        Assert.areEqual(100, policy.backoffMs(1), 'First retry uses the base delay');
        Assert.areEqual(200, policy.backoffMs(2), 'Second retry doubles');
        Assert.areEqual(400, policy.backoffMs(3), 'Third retry doubles again');
        Assert.areEqual(1000, policy.backoffMs(5), 'Capped at maxDelayMs');
        Assert.areEqual(100, policy.backoffMs(null), 'Null attempt treated as first');
    }

    @IsTest
    static void shouldStayWithinCapWhenJitterEnabled() {
        RetryPolicy policy = new RetryPolicy(3, 1000, 1500, 2000).withJitter(0.5);

        for (Integer sample = 0; sample < 20; sample++) {
            Integer delay = policy.backoffMs(1);
            Assert.isTrue(delay >= 1000 && delay <= 1500, 'Jittered delay out of bounds: ' + delay);
        }
    }

    @IsTest
    static void shouldClampJitterRatioWhenOutOfRange() {
        Assert.isTrue(new RetryPolicy(1, 0, 0, 0).withJitter(5).jitterRatio == 1, 'Clamped to 1');
        Assert.isTrue(new RetryPolicy(1, 0, 0, 0).withJitter(-1).jitterRatio == 0, 'Clamped to 0');
        Assert.isTrue(new RetryPolicy(1, 0, 0, 0).withJitter(null).jitterRatio == 0, 'Null disables jitter');
    }

    @IsTest
    static void shouldParseDeltaSecondsWhenRetryAfterIsNumeric() {
        RetryPolicy policy = new RetryPolicy(3, 100, 1000, 2000);

        Assert.areEqual(30000, policy.retryAfterMs('30', Datetime.now()), 'Seconds to milliseconds');
        Assert.areEqual(0, policy.retryAfterMs(' 0 ', Datetime.now()), 'Zero means retry now');
    }

    @IsTest
    static void shouldCapRetryAfterWhenPartnerAsksForTooLong() {
        RetryPolicy policy = new RetryPolicy(3, 100, 1000, 2000).withMaxRetryAfterSeconds(120);

        Assert.areEqual(120000, policy.retryAfterMs('86400', Datetime.now()), 'Capped at maxRetryAfterSeconds');
        Assert.areEqual(120000, policy.retryAfterMs('99999999999', Datetime.now()), 'Huge values do not overflow');
    }

    @IsTest
    static void shouldParseHttpDateWhenRetryAfterIsADate() {
        RetryPolicy policy = new RetryPolicy(3, 100, 1000, 2000);
        Datetime now = Datetime.newInstanceGmt(2026, 10, 21, 7, 28, 0);

        Assert.areEqual(30000, policy.retryAfterMs('Wed, 21 Oct 2026 07:28:30 GMT', now), 'Future date');
        Assert.areEqual(0, policy.retryAfterMs('Wed, 21 Oct 2026 07:27:00 GMT', now), 'Past date means retry now');
        Assert.areEqual(600000, policy.retryAfterMs('Thu, 22 Oct 2026 07:28:00 GMT', now), 'Capped at the default 10 minutes');
    }

    @IsTest
    static void shouldReturnNullWhenRetryAfterIsMissingOrGarbage() {
        RetryPolicy policy = new RetryPolicy(3, 100, 1000, 2000);

        Assert.isNull(policy.retryAfterMs(null, Datetime.now()), 'Missing header');
        Assert.isNull(policy.retryAfterMs('soon', Datetime.now()), 'Unparseable header');
        Assert.isNull(policy.retryAfterMs('Wed, 21 Foo 2026 07:28:30 GMT', Datetime.now()), 'Unknown month');
        Assert.isNull(policy.retryAfterMs('Wed, xx Oct 2026 07:28:30 GMT', Datetime.now()), 'Bad day');
    }

    @IsTest
    static void shouldPreferRetryAfterWhenComputingDelay() {
        RetryPolicy policy = new RetryPolicy(3, 100, 1000, 2000);

        Assert.areEqual(5000, policy.delayMs(1, '5'), 'Header wins over backoff');
        Assert.areEqual(200, policy.delayMs(2, null), 'Backoff without header');
    }

    @IsTest
    static void shouldRetryOnlyTransientStatuses() {
        RetryPolicy policy = RetryPolicy.defaults();

        Assert.isTrue(policy.isRetryableStatus(429), '429');
        Assert.isTrue(policy.isRetryableStatus(500), '500');
        Assert.isTrue(policy.isRetryableStatus(503), '503');
        Assert.isFalse(policy.isRetryableStatus(501), '501 will not get better');
        Assert.isFalse(policy.isRetryableStatus(400), '400');
        Assert.isFalse(policy.isRetryableStatus(404), '404');
        Assert.isFalse(policy.isRetryableStatus(null), 'null');
    }

    @IsTest
    static void shouldRejectWhenMaxAttemptsIsBelowOne() {
        try {
            new RetryPolicy(0, 100, 1000, 2000);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException expected) {
            Assert.isTrue(expected.getMessage().contains('maxAttempts'), 'Message names the parameter');
        }
    }

    @IsTest
    static void shouldNormalizeNullDelaysWhenConstructed() {
        RetryPolicy policy = new RetryPolicy(2, null, null, null);

        Assert.areEqual(0, policy.baseDelayMs, 'Base delay');
        Assert.areEqual(0, policy.maxDelayMs, 'Max delay');
        Assert.areEqual(0, policy.maxInlineWaitMs, 'Inline budget');
        Assert.areEqual(0, policy.backoffMs(3), 'Zero backoff');
    }
}
