package com.dblite;

import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.Statement;
import java.sql.Types;

/** Streams a JDBC cursor through the shared Rows interface. */
final class JdbcRows implements Rows {
    private final String    url;
    private final Statement stmt;
    private final ResultSet rs;
    private final String[]  columns;
    private final String[]  typeNames;
    private final int[]     sqlTypes;

    JdbcRows(String url, Statement stmt, ResultSet rs) throws java.sql.SQLException {
        this.url  = url;
        this.stmt = stmt;
        this.rs   = rs;

        ResultSetMetaData meta = rs.getMetaData();
        int n = meta.getColumnCount();
        this.columns   = new String[n];
        this.typeNames = new String[n];
        this.sqlTypes  = new int[n];
        for (int i = 1; i <= n; i++) {
            columns[i - 1]   = meta.getColumnLabel(i);
            typeNames[i - 1] = meta.getColumnTypeName(i);
            sqlTypes[i - 1]  = meta.getColumnType(i);
        }
    }

    @Override public String[] columns()     { return columns; }
    @Override public String[] columnTypes() { return typeNames; }
    @Override public boolean  next() throws java.sql.SQLException { return rs.next(); }

    @Override
    public String jsonValue(int col) throws java.sql.SQLException {
        return formatValue(rs, col, sqlTypes[col - 1]);
    }

    @Override
    public String csvValue(int col) throws java.sql.SQLException {
        int sqlType = sqlTypes[col - 1];
        if (sqlType == Types.BLOB) {
            Long length = blobLength(url, rs, col);
            return length == null ? "" : "<BLOB " + length + " bytes>";
        }
        if (sqlType == Types.CLOB || sqlType == Types.NCLOB) {
            java.sql.Clob clob = rs.getClob(col);
            if (clob == null || rs.wasNull()) return "";
            return clob.getSubString(1, (int) Math.min(clob.length(), 1_000_000));
        }
        String raw = rs.getString(col);
        if (raw == null || rs.wasNull()) return "";
        return raw;
    }

    @Override
    public void close() throws Exception {
        try { rs.close(); } finally { stmt.close(); }
    }

    static String formatValue(ResultSet rs, int col, int sqlType) throws java.sql.SQLException {
        if (sqlType == Types.BLOB) {
            Long length = blobLength(connectionUrl(rs), rs, col);
            return length == null ? "null" : "\"<BLOB " + length + " bytes>\"";
        }
        if (sqlType == Types.CLOB || sqlType == Types.NCLOB) {
            java.sql.Clob clob = rs.getClob(col);
            if (clob == null || rs.wasNull()) return "null";
            String val = clob.getSubString(1, (int) Math.min(clob.length(), 1_000_000));
            return Json.quote(val);
        }
        String raw = rs.getString(col);
        if (raw == null || rs.wasNull()) return "null";

        switch (sqlType) {
            case Types.BIT:
            case Types.BOOLEAN:
                return rs.getBoolean(col) ? "true" : "false";
            case Types.TINYINT:
            case Types.SMALLINT:
            case Types.INTEGER:
            case Types.BIGINT:
            case Types.FLOAT:
            case Types.REAL:
            case Types.DOUBLE:
            case Types.NUMERIC:
            case Types.DECIMAL:
                return Json.isJsonNumber(raw) ? raw : Json.quote(raw);
            default:
                return Json.quote(raw);
        }
    }

    private static String connectionUrl(ResultSet rs) throws java.sql.SQLException {
        return rs.getStatement().getConnection().getMetaData().getURL();
    }

    // SQLite's JDBC driver does not implement getBlob(), so its BLOB length is
    // measured by draining the binary stream instead.
    private static Long blobLength(String url, ResultSet rs, int col) throws java.sql.SQLException {
        if (!url.toLowerCase(java.util.Locale.ROOT).startsWith("jdbc:sqlite:")) {
            java.sql.Blob blob = rs.getBlob(col);
            return blob == null || rs.wasNull() ? null : blob.length();
        }
        try (java.io.InputStream input = rs.getBinaryStream(col)) {
            if (input == null || rs.wasNull()) return null;
            long length = 0;
            byte[] buffer = new byte[8192];
            for (int read; (read = input.read(buffer)) >= 0;) length += read;
            return length;
        } catch (java.io.IOException e) {
            throw new java.sql.SQLException("Failed to read BLOB", e);
        }
    }
}
