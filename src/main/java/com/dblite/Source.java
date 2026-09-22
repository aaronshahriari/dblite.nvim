package com.dblite;

import java.util.List;

/**
 * A backend dblite can talk to. Implementations own their wire protocol and
 * their notion of "a statement"; everything above this interface — the JSON
 * printer, the bulk file writer, script mode — is shared.
 */
public interface Source extends AutoCloseable {
    /**
     * Runs one statement. `maxRows` caps the returned rows (0 = unlimited).
     */
    Result execute(String statement, int maxRows) throws Exception;

    /** Splits a script into individually executable statements. */
    List<String> split(String script);

    /** Human-readable backend name, used in error messages. */
    String describe();

    @Override
    void close() throws Exception;

    /** Picks the implementation for a connection URL. */
    static Source open(String url, String user, String password) throws Exception {
        String lower = url.toLowerCase(java.util.Locale.ROOT);
        if (lower.startsWith("redis://") || lower.startsWith("rediss://")) {
            return new com.dblite.redis.RedisSource(url, user, password);
        }
        return new JdbcSource(url, user, password);
    }
}
