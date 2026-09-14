package com.dblite;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.sql.Types;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class SQLiteIntegrationTest {
    @TempDir
    Path tempDir;

    @Test
    void credentialFreeTemporaryFileCrudAndTypes() throws Exception {
        String url = "jdbc:sqlite:" + tempDir.resolve("crud.db");
        try (Connection connection = App.openConnection(url, null, null);
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                CREATE TABLE items (
                  id INTEGER PRIMARY KEY,
                  amount REAL,
                  name TEXT,
                  payload BLOB,
                  optional TEXT
                )
                """);

            try (PreparedStatement insert = connection.prepareStatement(
                    "INSERT INTO items(id, amount, name, payload, optional) VALUES (?, ?, ?, ?, ?)")) {
                insert.setLong(1, 7L);
                insert.setDouble(2, 12.5);
                insert.setString(3, "alpha");
                insert.setBytes(4, new byte[]{1, 2, 3});
                insert.setNull(5, Types.VARCHAR);
                assertEquals(1, insert.executeUpdate());
            }

            assertEquals(1, statement.executeUpdate("UPDATE items SET name = 'beta' WHERE id = 7"));
            try (ResultSet result = statement.executeQuery(
                    "SELECT id, amount, name, payload, optional FROM items")) {
                assertEquals(Types.INTEGER, result.getMetaData().getColumnType(1));
                assertEquals(Types.REAL, result.getMetaData().getColumnType(2));
                assertEquals(Types.VARCHAR, result.getMetaData().getColumnType(3));
                assertEquals(Types.BLOB, result.getMetaData().getColumnType(4));
                assertEquals(Types.VARCHAR, result.getMetaData().getColumnType(5));
                result.next();
                assertEquals(7L, result.getLong(1));
                assertEquals(12.5, result.getDouble(2));
                assertEquals("beta", result.getString(3));
                assertArrayEquals(new byte[]{1, 2, 3}, result.getBytes(4));
                assertNull(result.getString(5));
                assertEquals("\"<BLOB 3 bytes>\"", App.formatValue(result, 4, Types.BLOB));
                assertEquals("null", App.formatValue(result, 5, Types.VARCHAR));
            }

            try (ResultSet result = statement.executeQuery("SELECT 1e999 AS overflow")) {
                result.next();
                assertEquals("\"Inf\"", App.formatValue(result, 1, Types.FLOAT));
            }

            assertEquals(1, statement.executeUpdate("DELETE FROM items WHERE id = 7"));
            try (ResultSet result = statement.executeQuery("SELECT 1 FROM items")) {
                assertFalse(result.next());
            }
        }
    }

    @Test
    void transactionsAndTriggersWorkFromSplitScript() throws Exception {
        String url = "jdbc:sqlite:" + tempDir.resolve("script.db");
        String script = """
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE audit (item_id INTEGER, name TEXT);
            CREATE TRIGGER audit_item AFTER INSERT ON items
            BEGIN
              INSERT INTO audit(item_id, name) VALUES (NEW.id, NEW.name);
            END;
            BEGIN TRANSACTION;
            INSERT INTO items(name) VALUES ('rolled back');
            ROLLBACK;
            BEGIN TRANSACTION;
            INSERT INTO items(name) VALUES ('kept');
            COMMIT;
            """;

        try (Connection connection = App.openConnection(url, null, null)) {
            for (String sql : App.splitStatements(script, url)) {
                try (Statement statement = connection.createStatement()) {
                    statement.execute(sql);
                }
            }
            try (Statement statement = connection.createStatement();
                 ResultSet result = statement.executeQuery(
                     "SELECT items.name, audit.name FROM items JOIN audit ON audit.item_id = items.id")) {
                result.next();
                assertEquals("kept", result.getString(1));
                assertEquals("kept", result.getString(2));
                assertFalse(result.next());
            }
        }
    }
}
