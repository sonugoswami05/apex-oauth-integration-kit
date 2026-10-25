/**
 * Typed failure raised by the partner API client and the token service.
 *
 * Carries the HTTP status code (0 when no response was received), the correlation id that was sent
 * with the request, and whether the caller may safely try again later. Messages never include
 * access tokens, client secrets or request bodies.
 *
 * @example
 * throw new PartnerApiException('Partner API returned HTTP 503.')
 *     .withStatus(503)
 *     .withCorrelationId(correlationId)
 *     .markRetryable(30);
 */
public class PartnerApiException extends Exception {
    private Integer statusCode = 0;
    private String correlationId;
    private Boolean retryable = false;
    private Integer retryAfterSeconds;

    /**
     * Sets the HTTP status code.
     *
     * @param statusCode HTTP status code returned by the partner, or 0 for transport failures
     * @return this exception, for chaining
     */
    public PartnerApiException withStatus(Integer statusCode) {
        this.statusCode = statusCode == null ? 0 : statusCode;
        return this;
    }

    /**
     * Sets the correlation id of the failed call.
     *
     * @param correlationId Correlation id sent in the X-Correlation-Id header
     * @return this exception, for chaining
     */
    public PartnerApiException withCorrelationId(String correlationId) {
        this.correlationId = correlationId;
        return this;
    }

    /**
     * Flags the failure as transient so an async caller can schedule another attempt.
     *
     * @param retryAfterSeconds Suggested wait before the next attempt, or null when unknown
     * @return this exception, for chaining
     */
    public PartnerApiException markRetryable(Integer retryAfterSeconds) {
        this.retryable = true;
        this.retryAfterSeconds = retryAfterSeconds;
        return this;
    }

    /**
     * Returns the HTTP status code.
     *
     * @return HTTP status code, or 0 when the request never received a response
     */
    public Integer getStatusCode() {
        return statusCode;
    }

    /**
     * Returns the correlation id.
     *
     * @return Correlation id of the failed call, or null
     */
    public String getCorrelationId() {
        return correlationId;
    }

    /**
     * Tells whether a later attempt may succeed.
     *
     * @return True when a later attempt may succeed (429, most 5xx, timeouts)
     */
    public Boolean isRetryable() {
        return retryable;
    }

    /**
     * Returns the suggested wait before the next attempt.
     *
     * @return Seconds the partner asked us to wait, or the backoff the client would have used; may be null
     */
    public Integer getRetryAfterSeconds() {
        return retryAfterSeconds;
    }

    /**
     * Builds a one-line description that is safe to store on a record or show to an admin.
     *
     * @return Message with status code and correlation id appended
     */
    public String toSafeMessage() {
        String detail = getMessage();
        if (statusCode != null && statusCode > 0) {
            detail += ' [HTTP ' + statusCode + ']';
        }
        if (String.isNotBlank(correlationId)) {
            detail += ' [correlation id ' + correlationId + ']';
        }
        return detail;
    }
}
