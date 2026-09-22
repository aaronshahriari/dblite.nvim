package com.dblite.redis;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dblite.Rows;

import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

/**
 * Runs the client against a real server when DBLITE_REDIS_URL is set, e.g.
 *
 *   docker run -d --rm -p 6399:6379 redis:7-alpine
 *   DBLITE_REDIS_URL=redis://127.0.0.1:6399/0 mvn test
 *
 * Skipped otherwise so the suite stays self-contained. Everything it touches is
 * namespaced under `dblite:it:` and removed afterwards.
 */
@EnabledIfEnvironmentVariable(named = "DBLITE_REDIS_URL", matches = ".+")
class RedisIntegrationTest {

    private static final String PREFIX = "dblite:it:";

    private static String url() {
        return System.getenv("DBLITE_REDIS_URL");
    }

    private static List<List<String>> drain(Rows rows) throws Exception {
        List<List<String>> out = new ArrayList<>();
        int n = rows.columns().length;
        while (rows.next()) {
            List<String> row = new ArrayList<>(n);
            for (int i = 1; i <= n; i++) row.add(rows.csvValue(i));
            out.add(row);
        }
        return out;
    }

    private static void cleanup(RedisSource src) throws Exception {
        Rows rows = src.execute("KEYS " + PREFIX + "*", 0).rows;
        for (List<String> row : drain(rows)) {
            src.execute("DEL " + row.get(0), 0);
        }
    }

    @Test
    void roundTripsEveryTypeAgainstARealServer() throws Exception {
        try (RedisSource src = new RedisSource(url(), null, null)) {
            cleanup(src);
            try {
                src.execute("SET " + PREFIX + "str \"hello world\"", 0);
                src.execute("EXPIRE " + PREFIX + "str 600", 0);
                src.execute("HSET " + PREFIX + "hash name Aaron email a@example.com", 0);
                src.execute("RPUSH " + PREFIX + "list a b c", 0);
                src.execute("SADD " + PREFIX + "set x y", 0);
                src.execute("ZADD " + PREFIX + "zset 991 alice 847 bob", 0);

                List<List<String>> keys = drain(src.execute("KEYS " + PREFIX + "*", 0).rows);
                assertEquals(6, keys.size());

                List<String> str = keys.stream().filter(r -> r.get(0).endsWith(":str"))
                    .findFirst().orElseThrow();
                assertEquals("string", str.get(1));
                assertTrue(Integer.parseInt(str.get(2)) > 0, "TTL should count down");
                assertEquals("11", str.get(3));

                Rows hash = src.execute("HGETALL " + PREFIX + "hash", 0).rows;
                assertArrayEquals(new String[] { "field", "value" }, hash.columns());
                assertEquals(2, drain(hash).size());

                Rows zset = src.execute("ZRANGE " + PREFIX + "zset 0 -1 WITHSCORES", 0).rows;
                assertArrayEquals(new String[] { "member", "score" }, zset.columns());
                List<List<String>> scores = drain(zset);
                assertEquals("bob", scores.get(0).get(0));
                assertEquals("847", scores.get(0).get(1));

                Rows list = src.execute("LRANGE " + PREFIX + "list 0 -1", 0).rows;
                assertArrayEquals(new String[] { "index", "value" }, list.columns());
            } finally {
                cleanup(src);
            }
        }
    }

    /** The redis-cli round-trip limitations, verified against the real thing. */
    @Test
    void awkwardValuesSurviveARealRoundTrip() throws Exception {
        try (RedisSource src = new RedisSource(url(), null, null)) {
            cleanup(src);
            try {
                src.execute("SET " + PREFIX + "nl \"line one\\nline two\"", 0);
                assertEquals("line one\nline two",
                    drain(src.execute("GET " + PREFIX + "nl", 0).rows).get(0).get(0));

                src.execute("ZADD " + PREFIX + "z 1 'member with spaces'", 0);
                List<List<String>> z = drain(
                    src.execute("ZRANGE " + PREFIX + "z 0 -1 WITHSCORES", 0).rows);
                assertEquals("member with spaces", z.get(0).get(0));

                String doc = "{\"msg\": \"hi, there\", \"n\": 3}";
                src.execute("SET " + PREFIX + "doc '" + doc + "'", 0);
                Rows got = src.execute("GET " + PREFIX + "doc", 0).rows;
                assertArrayEquals(new String[] { "json" }, got.columnTypes());
                assertEquals(doc, drain(got).get(0).get(0));
            } finally {
                cleanup(src);
            }
        }
    }

    @Test
    void infoParsesOnARealServer() throws Exception {
        try (RedisSource src = new RedisSource(url(), null, null)) {
            Rows rows = src.execute("INFO", 0).rows;
            assertArrayEquals(new String[] { "section", "field", "value" }, rows.columns());
            List<List<String>> drained = drain(rows);
            assertTrue(drained.stream().anyMatch(r -> r.get(1).equals("redis_version")),
                "INFO should expose redis_version");
        }
    }

    /** A keyspace larger than one SCAN batch must come back whole. */
    @Test
    void scanLoopCoversALargeKeyspace() throws Exception {
        try (RedisSource src = new RedisSource(url(), null, null)) {
            cleanup(src);
            try {
                for (int i = 0; i < 2000; i++) {
                    src.execute("SET " + PREFIX + "bulk:" + i + " v", 0);
                }
                assertEquals(2000, drain(src.execute("KEYS " + PREFIX + "bulk:*", 0).rows).size());
                assertEquals(50, drain(src.execute("KEYS " + PREFIX + "bulk:*", 50).rows).size());
            } finally {
                cleanup(src);
            }
        }
    }
}
