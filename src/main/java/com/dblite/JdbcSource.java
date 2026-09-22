package com.dblite;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.List;

/** Every SQL backend dblite supports, behind the shared Source interface. */
final class JdbcSource implements Source {
    private final String url;
    private final Connection conn;

    JdbcSource(String url, String user, String password) throws java.sql.SQLException {
        this.url  = url;
        this.conn = connect(url, user, password);
    }

    static Connection connect(String url, String user, String password)
            throws java.sql.SQLException {
        return credentialFree(url)
            ? DriverManager.getConnection(url)
            : DriverManager.getConnection(url, user, password);
    }

    private static boolean credentialFree(String url) {
        String lower = url.toLowerCase(java.util.Locale.ROOT);
        return lower.startsWith("jdbc:sqlite:") || lower.contains("integratedsecurity=true");
    }

    @Override
    public Result execute(String statement, int maxRows) throws Exception {
        Statement stmt = conn.createStatement();
        try {
            if (maxRows > 0) {
                stmt.setMaxRows(maxRows);
            } else {
                // An uncapped result is either a bulk dump or an explicitly
                // unlimited run; either way a larger fetch size drastically cuts
                // round-trips (Oracle defaults to 10 rows/fetch).
                stmt.setFetchSize(1000);
            }
            boolean hasResultSet = stmt.execute(statement);
            if (!hasResultSet) {
                int uc = stmt.getUpdateCount();
                stmt.close();
                return Result.updated(uc);
            }
            ResultSet rs = stmt.getResultSet();
            return Result.of(new JdbcRows(url, stmt, rs));
        } catch (Exception e) {
            try { stmt.close(); } catch (Exception ignored) { /* original error wins */ }
            throw e;
        }
    }

    @Override
    public List<String> split(String script) {
        return SqlSplitter.split(script, url);
    }

    @Override
    public String describe() {
        return url;
    }

    @Override
    public void close() throws Exception {
        conn.close();
    }
}
