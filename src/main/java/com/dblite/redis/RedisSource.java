package com.dblite.redis;

import com.dblite.ListRows;
import com.dblite.ListRows.Cell;
import com.dblite.Result;
import com.dblite.Rows;
import com.dblite.Source;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;

/**
 * Speaks RESP directly over a socket. There is no Redis client dependency: the
 * protocol is small, and hand-rolling it keeps the native image free of
 * reflection metadata while making every value binary-safe end to end.
 */
public final class RedisSource implements Source {

    /** Commands per pipeline flush. Bounded so neither side's socket buffer fills. */
    private static final int PIPELINE_CHUNK = 512;

    /** SCAN's COUNT hint. Larger than redis-cli's default: fewer round trips. */
    private static final int SCAN_COUNT = 500;

    /** Safety valve for an unbounded `KEYS *` against a huge keyspace. */
    private static final int SCAN_HARD_CAP = 1_000_000;

    private final RedisUrl url;
    private final Socket socket;
    private final InputStream in;
    private final OutputStream out;

    public RedisSource(String rawUrl, String envUser, String envPassword) throws IOException {
        this.url = RedisUrl.parse(rawUrl);

        try {
            this.socket = url.tls
                ? javax.net.ssl.SSLSocketFactory.getDefault().createSocket()
                : new Socket();
            socket.connect(new InetSocketAddress(url.host, url.port), 10_000);
            socket.setTcpNoDelay(true);
            socket.setSoTimeout(30_000);
            if (socket instanceof javax.net.ssl.SSLSocket ssl) {
                ssl.startHandshake();
            }
        } catch (IOException e) {
            throw new IOException("cannot reach Redis at " + url.host + ":" + url.port
                + " (" + e.getMessage() + ")", e);
        }

        this.in  = new BufferedInputStream(socket.getInputStream(), 64 * 1024);
        this.out = new BufferedOutputStream(socket.getOutputStream(), 64 * 1024);

        // URL credentials win over the environment, so a connection entry can
        // carry its own auth without disturbing DB_USER/DB_PASSWORD.
        String user     = url.user     != null ? url.user     : emptyToNull(envUser);
        String password = url.password != null ? url.password : emptyToNull(envPassword);

        try {
            if (password != null) {
                if (user != null && !user.equalsIgnoreCase("default")) {
                    command(List.of("AUTH", user, password));
                } else {
                    command(List.of("AUTH", password));
                }
            }
            if (url.db != 0) {
                command(List.of("SELECT", Integer.toString(url.db)));
            }
        } catch (IOException e) {
            closeQuietly();
            throw e;
        }
    }

    private static String emptyToNull(String s) {
        return (s == null || s.isEmpty()) ? null : s;
    }

    // --- Wire --------------------------------------------------------------

    /** Sends one command and returns its reply, converting an error reply to an exception. */
    private RespValue command(List<String> args) throws IOException {
        Resp.writeCommand(out, args);
        RespValue reply = Resp.read(in);
        if (reply.isError()) throw new IOException(reply.text);
        return reply;
    }

    /**
     * Sends many commands and collects their replies in order. Flushed in
     * bounded chunks so a large batch cannot deadlock against a full socket
     * buffer. Error replies are returned rather than thrown: a key that expired
     * mid-listing should not abort the whole listing.
     */
    private List<RespValue> pipeline(List<List<String>> commands) throws IOException {
        List<RespValue> replies = new ArrayList<>(commands.size());
        for (int start = 0; start < commands.size(); start += PIPELINE_CHUNK) {
            int end = Math.min(start + PIPELINE_CHUNK, commands.size());
            for (int i = start; i < end; i++) {
                Resp.writeCommand(out, commands.get(i));
            }
            out.flush();
            for (int i = start; i < end; i++) {
                replies.add(Resp.read(in));
            }
        }
        return replies;
    }

    // --- Source ------------------------------------------------------------

    @Override
    public Result execute(String statement, int maxRows) throws Exception {
        List<String> args = Resp.tokenize(statement);
        if (args.isEmpty()) throw new IOException("No Redis command given");

        String cmd = args.get(0).toUpperCase(Locale.ROOT);

        // KEYS is served by a SCAN loop: same answer, without blocking the
        // server for the duration of a full keyspace walk.
        if (cmd.equals("KEYS")) {
            return Result.of(keyListing(args.size() > 1 ? args.get(1) : "*", maxRows));
        }

        RespValue reply = command(args);

        // A bare +OK carries no information worth a grid; report it the way a
        // DDL statement is reported.
        if (reply.kind == RespValue.Kind.SIMPLE && "OK".equalsIgnoreCase(reply.text)) {
            return Result.updated(-1);
        }

        Rows rows = RedisShaper.shape(args, reply);
        return Result.of(maxRows > 0 ? truncate(rows, maxRows) : rows);
    }

    @Override
    public List<String> split(String script) {
        List<String> out2 = new ArrayList<>();
        for (String raw : script.split("\r\n|\n|\r")) {
            String line = raw.trim();
            if (line.isEmpty()) continue;
            if (line.startsWith("#")) continue;   // comment
            out2.add(line);
        }
        return out2;
    }

    @Override
    public String describe() {
        return url.toString();
    }

    @Override
    public void close() throws Exception {
        try {
            // A polite QUIT, but never at the cost of hanging on exit: the
            // socket close below is what actually frees the connection.
            socket.setSoTimeout(2_000);
            Resp.writeCommand(out, List.of("QUIT"));
            Resp.read(in);
        } catch (IOException ignored) {
            // Server may have closed first, or a pipeline left the stream mid
            // reply; either way there is nothing left to salvage.
        } finally {
            closeQuietly();
        }
    }

    private void closeQuietly() {
        try { socket.close(); } catch (IOException ignored) { /* already gone */ }
    }

    // --- Key listing -------------------------------------------------------

    /** Glob metacharacters that make a pattern a search rather than a lookup. */
    private static boolean isGlob(String pattern) {
        for (int i = 0; i < pattern.length(); i++) {
            char c = pattern.charAt(i);
            if (c == '\\') { i++; continue; }        // escaped: not a metachar
            if (c == '*' || c == '?' || c == '[') return true;
        }
        return false;
    }

    /**
     * key/type/ttl/size for every key matching `pattern`.
     *
     * A pattern with no glob metacharacters is a key name, so it skips SCAN
     * entirely — an exact lookup is O(1) where a scan is a full keyspace walk.
     */
    private Rows keyListing(String pattern, int maxRows) throws IOException {
        List<String> keys = isGlob(pattern) ? scanKeys(pattern, maxRows) : exactKey(pattern);
        return describeKeys(keys);
    }

    private List<String> exactKey(String key) throws IOException {
        RespValue exists = command(List.of("EXISTS", key));
        return exists.integer > 0 ? List.of(key) : List.of();
    }

    /**
     * Full SCAN cursor loop. SCAN may return the same key more than once across
     * iterations, so results are de-duplicated while preserving arrival order.
     */
    private List<String> scanKeys(String pattern, int maxRows) throws IOException {
        LinkedHashSet<String> keys = new LinkedHashSet<>();
        String cursor = "0";
        int limit = maxRows > 0 ? Math.min(maxRows, SCAN_HARD_CAP) : SCAN_HARD_CAP;

        do {
            RespValue reply = command(List.of(
                "SCAN", cursor, "MATCH", pattern, "COUNT", Integer.toString(SCAN_COUNT)));
            if (!reply.isAggregate() || reply.items.size() < 2) {
                throw new IOException("Unexpected SCAN reply shape");
            }
            cursor = reply.items.get(0).asTextOrEmpty();
            RespValue batch = reply.items.get(1);
            if (batch.isAggregate()) {
                for (RespValue k : batch.items) {
                    String text = k.asText();
                    if (text != null) keys.add(text);
                    if (keys.size() >= limit) return new ArrayList<>(keys);
                }
            }
        } while (!"0".equals(cursor));

        return new ArrayList<>(keys);
    }

    /**
     * Enriches key names with type, TTL and size using three pipelined passes.
     * The size command depends on the type, so types must come back first.
     *
     * `ttl` holds remaining seconds, or null when the key has no expiry set or
     * disappeared between passes — both mean "no countdown to show".
     */
    private Rows describeKeys(List<String> keys) throws IOException {
        String[] columns = { "key", "type", "ttl", "size" };
        String[] types   = { "string", "string", "integer", "integer" };
        if (keys.isEmpty()) return ListRows.empty(columns, types);

        // TYPE and TTL do not depend on each other, so they share one pipeline;
        // only the size command needs the type, so it takes a second pass.
        List<List<String>> probe = new ArrayList<>(keys.size() * 2);
        for (String k : keys) {
            probe.add(List.of("TYPE", k));
            probe.add(List.of("TTL", k));
        }
        List<RespValue> probed = pipeline(probe);

        List<List<String>> sizeCmds = new ArrayList<>(keys.size());
        for (int i = 0; i < keys.size(); i++) {
            sizeCmds.add(sizeCommand(probed.get(i * 2).asTextOrEmpty(), keys.get(i)));
        }
        List<RespValue> sizeReplies = pipeline(sizeCmds);

        List<Cell[]> rows = new ArrayList<>(keys.size());
        for (int i = 0; i < keys.size(); i++) {
            rows.add(new Cell[] {
                Cell.of(keys.get(i)),
                Cell.of(probed.get(i * 2).asTextOrEmpty()),
                ttlCell(probed.get(i * 2 + 1)),
                countCell(sizeReplies.get(i)),
            });
        }
        return new ListRows(columns, types, rows);
    }

    /**
     * Size means bytes for a string and element count for every collection —
     * the number you actually want when scanning a keyspace for outliers.
     */
    private static List<String> sizeCommand(String type, String key) {
        switch (type) {
            case "string": return List.of("STRLEN", key);
            case "list":   return List.of("LLEN",   key);
            case "set":    return List.of("SCARD",  key);
            case "zset":   return List.of("ZCARD",  key);
            case "hash":   return List.of("HLEN",   key);
            case "stream": return List.of("XLEN",   key);
            default:       return List.of("EXISTS", key);  // harmless placeholder
        }
    }

    private static Cell ttlCell(RespValue v) {
        if (v.isError() || v.kind != RespValue.Kind.INT) return Cell.nil();
        return v.integer < 0 ? Cell.nil() : Cell.of(v.integer);
    }

    private static Cell countCell(RespValue v) {
        if (v.isError() || v.kind != RespValue.Kind.INT) return Cell.nil();
        return Cell.of(v.integer);
    }

    // --- Row capping -------------------------------------------------------

    /** Applies --max-rows to an already-materialised reply. */
    private static Rows truncate(Rows rows, int maxRows) throws Exception {
        if (rows instanceof ListRows list && list.size() <= maxRows) return rows;
        List<Cell[]> kept = new ArrayList<>(maxRows);
        String[] columns = rows.columns();
        int n = columns.length;
        while (kept.size() < maxRows && rows.next()) {
            Cell[] row = new Cell[n];
            for (int i = 1; i <= n; i++) {
                row[i - 1] = Cell.preformatted(rows.csvValue(i), rows.jsonValue(i));
            }
            kept.add(row);
        }
        return new ListRows(columns, rows.columnTypes(), kept);
    }
}
