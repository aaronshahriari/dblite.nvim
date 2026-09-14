package com.dblite;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class AppSplitterTest {
    @Test
    void sqliteTransactionStatementsSplitNormally() {
        List<String> statements = App.splitStatements("""
            BEGIN TRANSACTION;
            INSERT INTO items(`semi;column`, [other;column], name) VALUES (1, 2, 'one; still one');
            COMMIT;
            """, "jdbc:sqlite:test.db");

        assertEquals(List.of(
            "BEGIN TRANSACTION",
            "INSERT INTO items(`semi;column`, [other;column], name) VALUES (1, 2, 'one; still one')",
            "COMMIT"), statements);
    }

    @Test
    void sqliteTriggerRemainsOneStatement() {
        List<String> statements = App.splitStatements("""
            CREATE TRIGGER audit_item AFTER INSERT ON items
            BEGIN
              INSERT INTO audit(message)
              VALUES (CASE WHEN NEW.name = 'x' THEN 'semi;colon' ELSE NEW.name END);
              UPDATE counters SET value = value + 1;
            END;
            INSERT INTO items(name) VALUES ('x');
            """, "jdbc:sqlite:test.db");

        assertEquals(2, statements.size());
        assertTrue(statements.get(0).startsWith("CREATE TRIGGER audit_item"));
        assertTrue(statements.get(0).endsWith("END"));
        assertEquals("INSERT INTO items(name) VALUES ('x')", statements.get(1));
    }

    @Test
    void oracleSqlPlusBlocksAndSlashTerminatorArePreserved() {
        List<String> statements = App.splitStatements("""
            BEGIN
              NULL;
            END;
            /
            SELECT 1 FROM dual;
            """, "jdbc:oracle:thin:@//localhost:1521/XEPDB1");

        assertEquals(2, statements.size());
        assertEquals("BEGIN\n  NULL;\nEND;", statements.get(0));
        assertEquals("SELECT 1 FROM dual", statements.get(1));
    }

    @Test
    void sqlServerProcedureBodyRetainsInternalSemicolons() {
        List<String> statements = App.splitStatements("""
            CREATE PROCEDURE update_items AS
            BEGIN
              UPDATE items SET active = 1;
              DELETE FROM audit WHERE expired = 1;
            END;
            """, "jdbc:sqlserver://localhost:1433;databaseName=test");

        assertEquals(1, statements.size());
        assertTrue(statements.get(0).contains("UPDATE items SET active = 1;"));
        assertTrue(statements.get(0).endsWith("END;"));
    }
}
