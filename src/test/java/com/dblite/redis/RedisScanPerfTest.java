package com.dblite.redis;

import static org.junit.jupiter.api.Assertions.assertTrue;

import com.dblite.Rows;

import org.junit.jupiter.api.Test;

/**
 * Round-trip accounting for a key listing.
 *
 * Wall time on a remote Redis is dominated by sequential round trips, not by
 * bytes or server work. SCAN's cursor cannot be pipelined, so a listing costs
 * roughly keyspace_size / COUNT blocking round trips — each one multiplied by
 * the full network latency. At 5ms RTT, 6000 iterations is half a minute.
 *
 * These are the numbers to keep honest.
 */
class RedisScanPerfTest {

    private static int drainCount(Rows rows) throws Exception {
        int n = 0;
        while (rows.next()) n++;
        return n;
    }

    private static void report(String label, int keyspace, int matching) throws Exception {
        report(label, keyspace, matching, 0);
    }

    /** Reports the cost of listing a prefix out of a keyspace of `keyspace` keys. */
    private static void report(String label, int keyspace, int matching, int maxRows)
            throws Exception {
        try (ScanCountingServer server = new ScanCountingServer(keyspace, matching, "user")) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                long start = System.nanoTime();
                int found = drainCount(src.execute("KEYS user:*", maxRows).rows);
                long ms = (System.nanoTime() - start) / 1_000_000;

                int scans = server.scanCalls.get();
                System.out.printf(
                    "%-22s keyspace=%,-10d matched=%,-7d scans=%,-7d commands=%,-9d local=%,dms%n",
                    label, keyspace, found, scans, server.totalCommands.get(), ms);
                System.out.printf(
                    "%-22s   at 1ms RTT the scans alone cost %,.1fs; at 5ms %,.1fs%n",
                    "", scans / 1000.0, scans * 5 / 1000.0);
            }
        }
    }

    @Test
    void reportsScanCostAcrossKeyspaceSizes() throws Exception {
        report("sparse/small", 10_000, 100);
        report("sparse/medium", 100_000, 500);
        report("sparse/large", 1_000_000, 2_000);
        // A prefix that matches a lot is the common case interactively, and the
        // row cap should end the walk early instead of finishing the keyspace.
        report("dense, capped 10k", 1_000_000, 200_000, 10_000);
        report("dense, uncapped", 1_000_000, 200_000, 0);
        reportKeysOnly("dense, no details", 1_000_000, 200_000, 0);
    }

    /** The same listing with type/ttl/size switched off. */
    private static void reportKeysOnly(String label, int keyspace, int matching, int maxRows)
            throws Exception {
        try (ScanCountingServer server = new ScanCountingServer(keyspace, matching, "user")) {
            try (RedisSource src = new RedisSource(server.url(), null, null, 10_000, false)) {
                long start = System.nanoTime();
                int found = drainCount(src.execute("KEYS user:*", maxRows).rows);
                long ms = (System.nanoTime() - start) / 1_000_000;
                System.out.printf(
                    "%-22s keyspace=%,-10d matched=%,-7d scans=%,-7d commands=%,-9d local=%,dms%n",
                    label, keyspace, found, server.scanCalls.get(),
                    server.totalCommands.get(), ms);
            }
        }
    }

    /**
     * With details off, a listing costs the scan and nothing else — no
     * per-key follow-up. That is the difference between 600,000 commands and
     * 100 for a 200,000-key match.
     */
    @Test
    void withoutDetailsAListingCostsOnlyTheScan() throws Exception {
        try (ScanCountingServer server = new ScanCountingServer(1_000_000, 200_000, "user")) {
            try (RedisSource src = new RedisSource(server.url(), null, null, 10_000, false)) {
                Rows rows = src.execute("KEYS user:*", 0).rows;
                assertTrue(rows.columns().length == 1 && rows.columns()[0].equals("key"),
                    "a scan-only listing returns just the key column");
                drainCount(rows);
                int commands = server.totalCommands.get();
                int scans = server.scanCalls.get();
                assertTrue(commands <= scans + 2,
                    "no per-key commands expected, got " + commands + " for " + scans + " scans");
            }
        }
    }

    /**
     * With a row cap set, a dense match must stop as soon as the cap is met.
     * Walking the rest of the keyspace to find rows that will be discarded is
     * the difference between an instant listing and a visible wait.
     */
    @Test
    void aDenseMatchStopsAtTheRowCap() throws Exception {
        try (ScanCountingServer server = new ScanCountingServer(1_000_000, 200_000, "user")) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                int found = drainCount(src.execute("KEYS user:*", 10_000).rows);
                assertTrue(found <= 10_000, "the row cap must be respected, got " + found);
                int scans = server.scanCalls.get();
                assertTrue(scans <= 15,
                    "a dense match capped at 10k rows should stop after a few SCANs, took " + scans);
            }
        }
    }

    /**
     * The invariant that keeps a listing usable on a remote server: the number
     * of sequential SCAN round trips must stay proportional to keyspace/COUNT
     * with a COUNT large enough that a million keys is hundreds of trips, not
     * thousands.
     */
    @Test
    void aMillionKeyKeyspaceStaysUnderAFewHundredRoundTrips() throws Exception {
        try (ScanCountingServer server = new ScanCountingServer(1_000_000, 2_000, "user")) {
            try (RedisSource src = new RedisSource(server.url(), null, null)) {
                drainCount(src.execute("KEYS user:*", 0).rows);
                int scans = server.scanCalls.get();
                assertTrue(scans <= 250,
                    "a 1M-key keyspace should cost at most ~250 sequential SCAN round trips, took " + scans);
            }
        }
    }
}
