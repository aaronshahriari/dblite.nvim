package com.dblite;

import java.sql.Connection;
import java.sql.ResultSet;

public class App {
    public static void main(String[] args) {
        String url = System.getenv("DB_URL");
        String user = System.getenv("DB_USER");
        String password = System.getenv("DB_PASSWORD");

        if (url == null) {
            System.err.println("Missing required env var: DB_URL");
            System.err.println("Example DB_URL: jdbc:oracle:thin:@//localhost:1521/XEPDB1  or  jdbc:sqlserver://localhost:1433;databaseName=MyDB  or  redis://localhost:6379/0");
            System.exit(1);
        }
        boolean credentialFree = usesCredentialFreeConnection(url);
        if (!credentialFree && (user == null || password == null)) {
            System.err.println("Missing required env vars: DB_USER, DB_PASSWORD (not required for SQLite, Redis, or integratedSecurity=true)");
            System.exit(1);
        }

        int maxRows = 0;
        boolean scriptMode = false;
        String toFile = null;
        String format = "csv";
        for (int i = 0; i < args.length; i++) {
            if ("--max-rows".equals(args[i]) && i + 1 < args.length) {
                try {
                    maxRows = Integer.parseInt(args[++i]);
                } catch (NumberFormatException e) {
                    System.err.println("Invalid --max-rows value: " + args[i]);
                    System.exit(1);
                }
            } else if ("--script".equals(args[i])) {
                scriptMode = true;
            } else if ("--to-file".equals(args[i]) && i + 1 < args.length) {
                toFile = args[++i];
            } else if ("--format".equals(args[i]) && i + 1 < args.length) {
                format = args[++i];
            }
        }

        String query;
        try {
            query = new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
            // In script mode the splitter handles terminators per-statement; only
            // the single-statement path strips a lone trailing ;/ for convenience.
            if (!scriptMode && !isRedis(url)) query = query.replaceAll("[;/]\\s*$", "").trim();
        } catch (java.io.IOException e) {
            System.err.println("Failed to read query from stdin: " + e.getMessage());
            System.exit(1);
            return;
        }
        if (query.isEmpty()) {
            System.err.println("No query provided on stdin");
            System.exit(1);
        }

        if (scriptMode) {
            runScript(query, url, user, password);
            return;
        }

        Source source;
        try {
            source = Source.open(url, user, password);
        } catch (Exception e) {
            System.err.println("Connection failed: " + describe(e));
            System.exit(2);
            return;
        }

        // Once the connection is up, a failure is the statement's fault, not the
        // connection's — saying so saves a round of misdirected debugging.
        try (Source s = source) {
            Result result = s.execute(query, toFile != null ? 0 : maxRows);

            if (result.hasRows() && toFile != null) {
                try (Rows rows = result.rows) {
                    writeToFile(rows, toFile, format);
                }
            } else if (result.hasRows()) {
                try (Rows rows = result.rows) {
                    printRows(rows);
                }
            } else {
                System.out.println("{\"update_count\": " + result.updateCount + "}");
            }
        } catch (Exception e) {
            System.err.println("Query failed: " + describe(e));
            System.exit(2);
        }
    }

    private static boolean isRedis(String url) {
        String lower = url.toLowerCase(java.util.Locale.ROOT);
        return lower.startsWith("redis://") || lower.startsWith("rediss://");
    }

    private static String describe(Exception e) {
        String msg = e.getMessage();
        return (msg == null || msg.isEmpty()) ? e.toString() : msg;
    }

    // --- Output ------------------------------------------------------------

    private static void printRows(Rows rows) throws Exception {
        String[] columns = rows.columns();
        String[] types   = rows.columnTypes();

        StringBuilder head = new StringBuilder();
        head.append("{\"columns\": [");
        for (int i = 0; i < columns.length; i++) {
            if (i > 0) head.append(", ");
            head.append(Json.quote(columns[i]));
        }
        head.append("],\n\"column_types\": [");
        for (int i = 0; i < types.length; i++) {
            if (i > 0) head.append(", ");
            head.append(Json.quote(types[i]));
        }
        head.append("],\n\"rows\": [");
        System.out.println(head);

        int rowCount = 0;
        while (rows.next()) {
            if (rowCount > 0) System.out.println(",");
            StringBuilder line = new StringBuilder("  {");
            for (int i = 1; i <= columns.length; i++) {
                if (i > 1) line.append(", ");
                line.append(Json.quote(columns[i - 1])).append(": ");
                line.append(rows.jsonValue(i));
            }
            line.append("}");
            System.out.print(line);
            rowCount++;
        }
        System.out.println();
        System.out.println("]}");
    }

    // --- Script mode -------------------------------------------------------
    // Runs a script: many statements sharing one connection. Statements execute
    // in order, stopping at the first failure, and a per-statement log is
    // emitted as JSON. Connection-level failures exit(2) (like the
    // single-statement path); per-statement errors are reported in the JSON
    // with exit(0) so the log still renders.
    private static void runScript(String script, String url, String user, String password) {
        StringBuilder out = new StringBuilder();
        out.append("{\"script\": true, \"results\": [");
        int executed = 0, failed = 0, total = 0;

        try (Source source = Source.open(url, user, password)) {
            java.util.List<String> stmts = source.split(script);
            if (stmts.isEmpty()) {
                System.err.println("No statements found in script");
                System.exit(1);
            }
            total = stmts.size();

            for (int idx = 0; idx < stmts.size(); idx++) {
                String s = stmts.get(idx);
                if (idx > 0) out.append(", ");
                out.append("{\"index\": ").append(idx + 1);
                out.append(", \"preview\": ").append(Json.quote(preview(s)));
                try {
                    Result r = source.execute(s, 0);
                    int uc = r.updateCount;
                    if (r.hasRows()) {
                        uc = -1;
                        r.rows.close();
                    }
                    out.append(", \"ok\": true, \"update_count\": ").append(uc).append("}");
                    executed++;
                } catch (Exception e) {
                    out.append(", \"ok\": false, \"error\": ")
                       .append(Json.quote(describe(e))).append("}");
                    failed++;
                    break; // stop at first error
                }
            }
        } catch (Exception e) {
            System.err.println("Connection failed: " + describe(e));
            System.exit(2);
            return;
        }

        out.append("], \"executed\": ").append(executed);
        out.append(", \"failed\": ").append(failed);
        out.append(", \"total\": ").append(total).append("}");
        System.out.println(out);
    }

    static Connection openConnection(String url, String user, String password)
            throws java.sql.SQLException {
        return JdbcSource.connect(url, user, password);
    }

    private static boolean usesCredentialFreeConnection(String url) {
        String lower = url.toLowerCase(java.util.Locale.ROOT);
        return lower.startsWith("jdbc:sqlite:")
            || lower.startsWith("redis://")
            || lower.startsWith("rediss://")
            || lower.contains("integratedsecurity=true");
    }

    // First ~80 chars of a statement, collapsed to a single line, for the log.
    private static String preview(String s) {
        String one = s.replaceAll("\\s+", " ").trim();
        return one.length() > 80 ? one.substring(0, 80) + "…" : one;
    }

    static java.util.List<String> splitStatements(String sql, String url) {
        return SqlSplitter.split(sql, url);
    }

    // --- Bulk file dump ----------------------------------------------------
    // Streams the full result set straight to `path` (CSV or JSON) row by row,
    // so arbitrarily large exports never buffer in memory. Emits a small JSON
    // summary to stdout on completion so the caller can report the row count.
    private static void writeToFile(Rows rows, String path, String format) throws Exception {
        boolean json = "json".equalsIgnoreCase(format);
        String[] columns = rows.columns();
        String[] types   = rows.columnTypes();
        int columnCount  = columns.length;
        long rowCount = 0;

        try (java.io.BufferedWriter w = java.nio.file.Files.newBufferedWriter(
                java.nio.file.Paths.get(path), java.nio.charset.StandardCharsets.UTF_8)) {
            if (json) {
                w.write("{\"columns\": [");
                for (int i = 0; i < columnCount; i++) {
                    if (i > 0) w.write(", ");
                    w.write(Json.quote(columns[i]));
                }
                w.write("],\n\"column_types\": [");
                for (int i = 0; i < types.length; i++) {
                    if (i > 0) w.write(", ");
                    w.write(Json.quote(types[i]));
                }
                w.write("],\n\"rows\": [\n");
                while (rows.next()) {
                    if (rowCount > 0) w.write(",\n");
                    w.write("  {");
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) w.write(", ");
                        w.write(Json.quote(columns[i - 1]));
                        w.write(": ");
                        w.write(rows.jsonValue(i));
                    }
                    w.write("}");
                    rowCount++;
                }
                w.write("\n]}\n");
            } else {
                for (int i = 0; i < columnCount; i++) {
                    if (i > 0) w.write(",");
                    w.write(Json.csvEscape(columns[i]));
                }
                w.write("\n");
                while (rows.next()) {
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) w.write(",");
                        w.write(Json.csvEscape(rows.csvValue(i)));
                    }
                    w.write("\n");
                    rowCount++;
                }
            }
        }
        System.out.println("{\"to_file\": true, \"format\": " + Json.quote(format)
            + ", \"path\": " + Json.quote(path) + ", \"rows\": " + rowCount + "}");
    }

    static String formatValue(ResultSet rs, int col, int sqlType) throws java.sql.SQLException {
        return JdbcRows.formatValue(rs, col, sqlType);
    }
}
