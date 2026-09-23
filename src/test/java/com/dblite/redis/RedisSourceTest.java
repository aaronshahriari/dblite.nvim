package com.dblite.redis;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dblite.Result;
import com.dblite.Rows;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

class RedisSourceTest {

    /** Materialises a Rows into plain maps so assertions read clearly. */
    private static List<Map<String, String>> drain(Rows rows) throws Exception {
        List<Map<String, String>> out = new ArrayList<>();
        String[] cols = rows.columns();
        while (rows.next()) {
            Map<String, String> row = new LinkedHashMap<>();
            for (int i = 1; i <= cols.length; i++) row.put(cols[i - 1], rows.csvValue(i));
            out.add(row);
        }
        return out;
    }

    private static List<String> jsonCells(Rows rows, int col) throws Exception {
        List<String> out = new ArrayList<>();
        while (rows.next()) out.add(rows.jsonValue(col));
        return out;
    }

    // --- Key listing --------------------------------------------------------

    @Test
    void keysListsEveryKeyWithTypeTtlAndSize() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("user:1", "alice");
            server.expire("user:1", 3600);
            server.hash("user:2", Map.of("name", "bob"));
            server.list("queue:jobs", List.of("a", "b", "c"));

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<Map<String, String>> rows = drain(src.execute("KEYS *", 0).rows);
                assertEquals(3, rows.size());

                Map<String, String> user1 = rows.stream()
                    .filter(r -> r.get("key").equals("user:1")).findFirst().orElseThrow();
                assertEquals("string", user1.get("type"));
                assertEquals("3600", user1.get("ttl"));
                assertEquals("5", user1.get("size"));       // STRLEN("alice")

                Map<String, String> queue = rows.stream()
                    .filter(r -> r.get("key").equals("queue:jobs")).findFirst().orElseThrow();
                assertEquals("list", queue.get("type"));
                assertEquals("3", queue.get("size"));       // LLEN
                assertEquals("", queue.get("ttl"));         // no expiry -> blank
            }
        }
    }

    @Test
    void keysAppliesGlobPattern() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("user:1", "a");
            server.set("user:2", "b");
            server.set("session:x", "c");

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<Map<String, String>> rows = drain(src.execute("KEYS user:*", 0).rows);
                assertEquals(2, rows.size());
                assertTrue(rows.stream().allMatch(r -> r.get("key").startsWith("user:")));
                assertTrue(server.scanCalls() > 0, "a glob pattern must go through SCAN");
            }
        }
    }

    /** The cursor loop must cover a keyspace larger than one SCAN batch. */
    @Test
    void keysWalksTheWholeKeyspaceAcrossScanBatches() throws Exception {
        try (FakeRedis server = new FakeRedis(3, false, null)) {
            for (int i = 0; i < 10; i++) server.set("k:" + i, "v" + i);

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                assertEquals(10, drain(src.execute("KEYS *", 0).rows).size());
            }
        }
    }

    /** SCAN may return a key twice; the listing must not. */
    @Test
    void keysDeduplicatesRepeatedScanResults() throws Exception {
        try (FakeRedis server = new FakeRedis(3, true, null)) {
            for (int i = 0; i < 7; i++) server.set("k:" + i, "v");

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<Map<String, String>> rows = drain(src.execute("KEYS *", 0).rows);
                assertEquals(7, rows.size());
                assertEquals(7, rows.stream().map(r -> r.get("key")).distinct().count());
            }
        }
    }

    /**
     * A pattern with no glob metacharacters is a key name. It must resolve
     * without a keyspace walk — verified by pointing it at a server whose SCAN
     * would have to be called to find anything.
     */
    @Test
    void exactKeyLookupSkipsScanEntirely() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.hash("user:263842-madfk623-2324", Map.of("a", "1", "b", "2"));
            server.set("noise", "x");

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<Map<String, String>> rows =
                    drain(src.execute("KEYS user:263842-madfk623-2324", 0).rows);
                assertEquals(1, rows.size());
                assertEquals("hash", rows.get(0).get("type"));
                assertEquals("2", rows.get(0).get("size"));
                assertEquals(0, server.scanCalls(), "exact key must not trigger a keyspace scan");
            }
        }
    }

    @Test
    void exactKeyLookupOfMissingKeyReturnsNoRows() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("present", "x");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("KEYS absent", 0).rows;
                assertArrayEquals(new String[] { "key", "type", "ttl", "size" }, rows.columns());
                assertTrue(drain(rows).isEmpty());
                assertEquals(0, server.scanCalls(), "exact key must not trigger a keyspace scan");
            }
        }
    }

    @Test
    void keysRespectsMaxRows() throws Exception {
        try (FakeRedis server = new FakeRedis(3, false, null)) {
            for (int i = 0; i < 20; i++) server.set("k:" + i, "v");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                assertEquals(5, drain(src.execute("KEYS *", 5).rows).size());
            }
        }
    }

    // --- Reply shaping ------------------------------------------------------

    @Test
    void hashBecomesFieldValueColumns() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            LinkedHashMap<String, String> fields = new LinkedHashMap<>();
            fields.put("name", "Aaron");
            fields.put("email", "a@example.com");
            server.hash("user:1", fields);

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("HGETALL user:1", 0).rows;
                assertArrayEquals(new String[] { "field", "value" }, rows.columns());
                List<Map<String, String>> drained = drain(rows);
                assertEquals(2, drained.size());
                assertEquals("name", drained.get(0).get("field"));
                assertEquals("Aaron", drained.get(0).get("value"));
            }
        }
    }

    @Test
    void sortedSetWithScoresBecomesMemberScoreColumns() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            LinkedHashMap<String, Double> z = new LinkedHashMap<>();
            z.put("alice", 991.0);
            z.put("bob", 847.0);
            server.zset("leaderboard", z);

            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("ZRANGE leaderboard 0 -1 WITHSCORES", 0).rows;
                assertArrayEquals(new String[] { "member", "score" }, rows.columns());
                List<Map<String, String>> drained = drain(rows);
                assertEquals("alice", drained.get(0).get("member"));
                assertEquals("991", drained.get(0).get("score"));
            }
            // Scores must reach the editor as JSON numbers, not quoted strings.
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("ZRANGE leaderboard 0 -1 WITHSCORES", 0).rows;
                assertEquals(List.of("991", "847"), jsonCells(rows, 2));
            }
        }
    }

    @Test
    void sortedSetWithoutScoresStaysAList() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            LinkedHashMap<String, Double> z = new LinkedHashMap<>();
            z.put("alice", 1.0);
            server.zset("lb", z);
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("ZRANGE lb 0 -1", 0).rows;
                assertArrayEquals(new String[] { "index", "value" }, rows.columns());
            }
        }
    }

    @Test
    void listBecomesIndexValueColumns() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.list("q", List.of("first", "second"));
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("LRANGE q 0 -1", 0).rows;
                assertArrayEquals(new String[] { "index", "value" }, rows.columns());
                List<Map<String, String>> drained = drain(rows);
                assertEquals("0", drained.get(0).get("index"));
                assertEquals("first", drained.get(0).get("value"));
                assertEquals("1", drained.get(1).get("index"));
            }
        }
    }

    @Test
    void infoBecomesSectionFieldValueColumns() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("INFO", 0).rows;
                assertArrayEquals(new String[] { "section", "field", "value" }, rows.columns());
                List<Map<String, String>> drained = drain(rows);
                Map<String, String> role = drained.stream()
                    .filter(r -> r.get("field").equals("role")).findFirst().orElseThrow();
                assertEquals("Replication", role.get("section"));
                assertEquals("master", role.get("value"));
            }
        }
    }

    @Test
    void configGetBecomesFieldValueColumns() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("CONFIG GET maxmemory", 0).rows;
                assertArrayEquals(new String[] { "field", "value" }, rows.columns());
            }
        }
    }

    /** The editor completes against this list, so its shape has to be stable. */
    @Test
    void commandReplyBecomesNameArityFlagsColumns() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("COMMAND", 0).rows;
                assertArrayEquals(new String[] { "name", "arity", "flags" }, rows.columns());
                List<Map<String, String>> drained = drain(rows);
                assertEquals(2, drained.size());
                assertEquals("get", drained.get(0).get("name"));
                assertEquals("2", drained.get(0).get("arity"));
                assertEquals("readonly fast", drained.get(0).get("flags"));
                assertEquals("hgetall", drained.get(1).get("name"));
            }
        }
    }

    // --- JSON ---------------------------------------------------------------

    @Test
    void jsonValueIsTaggedAsJsonColumnType() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("cfg", "{\"theme\":\"dark\",\"notify\":{\"email\":true}}");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("GET cfg", 0).rows;
                assertArrayEquals(new String[] { "result" }, rows.columns());
                assertArrayEquals(new String[] { "json" }, rows.columnTypes());
            }
        }
    }

    @Test
    void plainStringIsNotTaggedAsJson() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("greeting", "hello");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("GET greeting", 0).rows;
                assertArrayEquals(new String[] { "string" }, rows.columnTypes());
            }
        }
    }

    /** A truncated document must not be advertised as JSON. */
    @Test
    void malformedJsonIsNotTaggedAsJson() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("broken", "{\"a\": 1, \"b\":");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                assertArrayEquals(new String[] { "string" },
                    src.execute("GET broken", 0).rows.columnTypes());
            }
        }
    }

    @Test
    void jsonlValueExpandsToOneRowPerRecord() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("events", "{\"id\":1}\n{\"id\":2}\n{\"id\":3}");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("GET events", 0).rows;
                assertArrayEquals(new String[] { "line", "value" }, rows.columns());
                assertArrayEquals(new String[] { "index", "json" }, rows.columnTypes());
                List<Map<String, String>> drained = drain(rows);
                assertEquals(3, drained.size());
                assertEquals("{\"id\":2}", drained.get(1).get("value"));
            }
        }
    }

    /** A pretty-printed single document also has newlines; it must stay one cell. */
    @Test
    void prettyPrintedJsonIsNotTreatedAsJsonl() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("doc", "{\n  \"a\": 1,\n  \"b\": 2\n}");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("GET doc", 0).rows;
                assertArrayEquals(new String[] { "result" }, rows.columns());
                assertEquals(1, drain(rows).size());
            }
        }
    }

    @Test
    void hashOfJsonValuesTagsTheValueColumnAsJson() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            LinkedHashMap<String, String> fields = new LinkedHashMap<>();
            fields.put("a", "{\"x\":1}");
            fields.put("b", "{\"y\":2}");
            server.hash("docs", fields);
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                assertArrayEquals(new String[] { "string", "json" },
                    src.execute("HGETALL docs", 0).rows.columnTypes());
            }
        }
    }

    @Test
    void mixedValuesDoNotClaimTheJsonTag() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            LinkedHashMap<String, String> fields = new LinkedHashMap<>();
            fields.put("a", "{\"x\":1}");
            fields.put("b", "not json");
            server.hash("docs", fields);
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                assertArrayEquals(new String[] { "string", "string" },
                    src.execute("HGETALL docs", 0).rows.columnTypes());
            }
        }
    }

    // --- Values that broke the redis-cli round trip -------------------------

    /** The limitation redis.nvim documents: newlines must survive intact. */
    @Test
    void valueContainingNewlinesSurvivesRoundTrip() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                src.execute("SET note \"line one\\nline two\\nline three\"", 0);
                Rows rows = src.execute("GET note", 0).rows;
                List<Map<String, String>> drained = drain(rows);
                assertEquals("line one\nline two\nline three", drained.get(0).get("result"));
            }
        }
    }

    @Test
    void valueContainingSpacesSurvivesRoundTrip() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                src.execute("SET m 'member with spaces'", 0);
                assertEquals("member with spaces",
                    drain(src.execute("GET m", 0).rows).get(0).get("result"));
            }
        }
    }

    @Test
    void jsonValueSurvivesRoundTripUnescaped() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            String doc = "{\"msg\": \"hi, there\", \"n\": 3}";
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                src.execute("SET doc '" + doc + "'", 0);
                assertEquals(doc, drain(src.execute("GET doc", 0).rows).get(0).get("result"));
            }
        }
    }

    // --- Command results ----------------------------------------------------

    @Test
    void okReplyIsReportedAsAnExecutedStatement() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Result r = src.execute("SET k v", 0);
                assertFalse(r.hasRows());
                assertEquals(-1, r.updateCount);
            }
        }
    }

    @Test
    void integerReplyIsShownAsASingleResultRow() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.set("k", "v");
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("DEL k", 0).rows;
                assertArrayEquals(new String[] { "result" }, rows.columns());
                assertEquals(List.of("1"), jsonCells(rows, 1));   // bare JSON number
            }
        }
    }

    @Test
    void nullReplyRendersAsJsonNull() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Rows rows = src.execute("GET missing", 0).rows;
                assertEquals(List.of("null"), jsonCells(rows, 1));
            }
        }
    }

    @Test
    void serverErrorReplyBecomesAnException() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            server.list("q", List.of("a"));
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Exception e = assertThrows(Exception.class, () -> src.execute("GET q", 0));
                assertTrue(e.getMessage().contains("WRONGTYPE"), e.getMessage());
            }
        }
    }

    @Test
    void unknownCommandSurfacesTheServerMessage() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                Exception e = assertThrows(Exception.class, () -> src.execute("NOPE arg", 0));
                assertTrue(e.getMessage().contains("unknown command"), e.getMessage());
            }
        }
    }

    @Test
    void emptyStatementIsRejected() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                assertThrows(Exception.class, () -> src.execute("   ", 0));
            }
        }
    }

    // --- Auth ---------------------------------------------------------------

    @Test
    void authenticatesWithPasswordFromUrl() throws Exception {
        try (FakeRedis server = new FakeRedis(3, false, "s3cr3t")) {
            String url = "redis://:s3cr3t@127.0.0.1:" + server.port();
            try (RedisSource src = new RedisSource(url, null, null)) {
                assertEquals(-1, src.execute("SET k v", 0).updateCount);
            }
        }
    }

    @Test
    void authenticatesWithPasswordFromEnvironment() throws Exception {
        try (FakeRedis server = new FakeRedis(3, false, "s3cr3t")) {
            try (RedisSource src = new RedisSource(server.url(), null, "s3cr3t")) {
                assertEquals(-1, src.execute("SET k v", 0).updateCount);
            }
        }
    }

    @Test
    void wrongPasswordFailsToConnect() throws Exception {
        try (FakeRedis server = new FakeRedis(3, false, "s3cr3t")) {
            assertThrows(Exception.class, () -> new RedisSource(server.url(), null, "wrong"));
        }
    }

    @Test
    void unreachableServerReportsHostAndPort() {
        Exception e = assertThrows(Exception.class,
            () -> new RedisSource("redis://127.0.0.1:1", null, null));
        assertTrue(e.getMessage().contains("127.0.0.1:1"), e.getMessage());
    }

    // --- Script mode --------------------------------------------------------

    /**
     * A command must be breakable across lines, or a JSON.SET with a document
     * argument is one unreadable line. The rules mirror dblite.query so that
     * `run at cursor` and a whole-buffer run agree on where a command ends.
     */
    @Test
    void splitJoinsAnUnterminatedQuoteAcrossLines() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<String> stmts = src.split("""
                    KEYS demo:*
                    JSON.SET doc:1 $ '{
                      "name": "widget",
                      "qty": 2
                    }'
                    GET cfg:app
                    """);
                assertEquals(3, stmts.size(), stmts.toString());
                assertEquals("KEYS demo:*", stmts.get(0));
                assertTrue(stmts.get(1).startsWith("JSON.SET doc:1 $ '{"),
                    stmts.get(1));
                // The newlines inside the quoted value are kept: they are part
                // of the argument, and the tokenizer treats them as data.
                assertTrue(stmts.get(1).contains("\n"), stmts.get(1));
                assertTrue(stmts.get(1).endsWith("}'"), stmts.get(1));
                assertEquals("GET cfg:app", stmts.get(2));
            }
        }
    }

    @Test
    void splitJoinsATrailingBackslashAndDropsIt() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<String> stmts = src.split("""
                    HSET user:1042 \\
                      email a@example.com \\
                      name Aaron
                    GET other
                    """);
                assertEquals(2, stmts.size(), stmts.toString());
                assertFalse(stmts.get(0).contains("\\"),
                    "the continuation backslash must be dropped: " + stmts.get(0));
                // Tokenising the joined command must recover the real arguments.
                assertEquals(
                    List.of("HSET", "user:1042", "email", "a@example.com", "name", "Aaron"),
                    Resp.tokenize(stmts.get(0)));
                assertEquals("GET other", stmts.get(1));
            }
        }
    }

    /** A backslash inside a comment is not a continuation. */
    @Test
    void splitDoesNotContinueFromInsideAComment() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<String> stmts = src.split("""
                    # a trailing backslash in prose \\
                    GET one
                    GET two
                    """);
                assertEquals(List.of("GET one", "GET two"), stmts);
            }
        }
    }

    /** A `#` inside a quoted value is data, not the start of a comment. */
    @Test
    void splitKeepsAHashInsideAQuotedValue() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<String> stmts = src.split("SET colour \"#ff0000\"\nGET colour");
                assertEquals(2, stmts.size(), stmts.toString());
                assertEquals(List.of("SET", "colour", "#ff0000"),
                    Resp.tokenize(stmts.get(0)));
            }
        }
    }

    @Test
    void splitTakesOneCommandPerLineAndDropsComments() throws Exception {
        try (FakeRedis server = new FakeRedis()) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                List<String> stmts = src.split("""
                    # purge expired sessions
                    DEL session:a

                    DEL session:b
                      SET marker done
                    """);
                assertEquals(List.of("DEL session:a", "DEL session:b", "SET marker done"), stmts);
            }
        }
    }
}
