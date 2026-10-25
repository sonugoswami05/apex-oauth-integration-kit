/**
 * Small helpers shared by the integration classes: correlation ids, secret masking and a single
 * place for warning output. Nothing here ever receives a full token or secret in clear text.
 */
public with sharing class IntegrationLog {
    private static final String PREFIX = '[partner-api] ';
    private static final Integer VISIBLE_SUFFIX_LENGTH = 4;
    private static final Integer MIN_MASKABLE_LENGTH = 12;

    /**
     * Generates a random RFC 4122 style identifier for the X-Correlation-Id header.
     *
     * @return 36 character lowercase hex id, for example 9f1c2d3e-...
     */
    public static String newCorrelationId() {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16) + '-'
            + hex.substring(16, 20) + '-' + hex.substring(20, 32);
    }

    /**
     * Masks a secret so it can appear in diagnostics. Short values are fully hidden.
     *
     * @param secret Token or other sensitive value
     * @return For example "****9f2a (40 chars)", or "****" for short values
     */
    public static String mask(String secret) {
        if (String.isBlank(secret)) {
            return '(empty)';
        }
        if (secret.length() < MIN_MASKABLE_LENGTH) {
            return '****';
        }
        return '****' + secret.right(VISIBLE_SUFFIX_LENGTH) + ' (' + secret.length() + ' chars)';
    }

    /**
     * Writes a warning for failure paths only (cache outages, token refreshes). Callers must pass
     * already-masked values.
     *
     * @param message Text to log
     */
    public static void warn(String message) {
        System.debug(LoggingLevel.WARN, PREFIX + message);
    }
}
