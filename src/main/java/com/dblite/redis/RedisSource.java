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

    /**
     * SCAN's COUNT hint, i.e. keys examined per iteration.
     *
     * This is the single biggest lever on how long a key listing takes. The
     * cursor is sequential, so a listing costs roughly keyspace_size / COUNT
     * blocking round trips, each one multiplied by the full network latency —
     * at COUNT 500 a million-key keyspace is 2000 round trips, which is tens of
     * seconds on anything but a local server. MATCH does not help: Redis
     * examines every key and filters afterwards.
     *
     * 10000 keeps a million keys to ~100 round trips while staying within the
     * range Redis tolerates without a noticeable single-command stall.
     */
    private static final int DEFAULT_SCAN_COUNT = 10_000;

    private final int scanCount;

    /** Whether a key listing enriches each key with type, TTL and size. */
    private final boolean keyDetails;

    /** Safety valve for an unbounded `KEYS *` against a huge keyspace. */
    private static final int SCAN_HARD_CAP = 1_000_000;

    private final RedisUrl url;
    private final Socket socket;
    private final InputStream in;
    private final OutputStream out;

    public RedisSource(String rawUrl, String envUser, String envPassword) throws IOException {
        this(rawUrl, envUser, envPassword, scanCountFromEnv());
    }

    /**
     * DBLITE_SCAN_COUNT overrides the COUNT hint, so a very large keyspace can
     * trade a longer single-command stall for far fewer round trips without a
     * rebuild. Anything unparseable falls back to the default rather than
     * failing a query over a malformed tuning knob.
     */
    /**
     * DBLITE_KEY_DETAILS=0 drops the type/TTL/size columns from a key listing.
     *
     * Those three cost one command per key — 30,000 commands for a 10,000-key
     * listing — so on a remote server they can outweigh the scan itself. When
     * the task is just finding which keys exist, paying for them is optional.
     */
    private static boolean keyDetailsFromEnv() {
        String raw = System.getenv("DBLITE_KEY_DETAILS");
        if (raw == null || raw.isBlank()) return true;
        String v = raw.trim().toLowerCase(Locale.ROOT);
        return !(v.equals("0") || v.equals("false") || v.equals("no"));
    }

    private static int scanCountFromEnv() {
        String raw = System.getenv("DBLITE_SCAN_COUNT");
        if (raw == null || raw.isBlank()) return DEFAULT_SCAN_COUNT;
        try {
            int n = Integer.parseInt(raw.trim());
            return n > 0 ? n : DEFAULT_SCAN_COUNT;
        } catch (NumberFormatException e) {
            return DEFAULT_SCAN_COUNT;
        }
    }

    public RedisSource(String rawUrl, String envUser, String envPassword, int scanCount)
            throws IOException {
        this(rawUrl, envUser, envPassword, scanCount, keyDetailsFromEnv());
    }

    public RedisSource(String rawUrl, String envUser, String envPassword,
                       int scanCount, boolean keyDetails) throws IOException {
        this.scanCount  = scanCount > 0 ? scanCount : DEFAULT_SCAN_COUNT;
        this.keyDetails = keyDetails;
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
        Resp.sendCommand(out, args);
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

    /**
     * One command per line, with continuations.
     *
     * Redis has no statement terminator, so a line is a command — but a single
     * command still has to be breakable across lines, or a JSON.SET with a
     * document argument is one unreadable line. A command continues when a
     * quote opened on the line is still open at its end (the newline is part of
     * the value) or when the line ends with a backslash outside quotes, which
     * is dropped. Outside quotes `#` starts a comment; inside one it is data.
     *
     * The rules are mirrored in dblite.query on the editor side, so what
     * `run at cursor` sends and what a whole-buffer run splits agree.
     */
    @Override
    public List<String> split(String script) {
        List<String> statements = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        char quote = 0;

        for (String raw : script.split("\r\n|\n|\r")) {
            boolean continuing = quote != 0 || current.length() > 0;

            // A blank or comment line only matters when it is not inside a
            // quoted value, where it is ordinary data.
            if (quote == 0 && !continuing) {
                String t = raw.trim();
                if (t.isEmpty() || t.startsWith("#")) continue;
            }

            LineScan scan = scanLine(raw, quote);
            String piece = scan.code;
            if (scan.continues && quote == 0 && scan.trailingBackslash) {
                // Drop the backslash; the newline that follows separates the
                // arguments on its own.
                piece = piece.substring(0, scan.backslashAt);
            }

            if (current.length() > 0) current.append('\n');
            current.append(piece);
            quote = scan.quote;

            if (!scan.continues) {
                String done = current.toString().trim();
                if (!done.isEmpty()) statements.add(done);
                current.setLength(0);
            }
        }

        // An unterminated command at end of input is still worth running: the
        // server's error is more useful than silently dropping it.
        String tail = current.toString().trim();
        if (!tail.isEmpty()) statements.add(tail);
        return statements;
    }

    /** Result of scanning one line for quote state and continuation. */
    private static final class LineScan {
        char quote;
        boolean continues;
        boolean trailingBackslash;
        int backslashAt;
        String code;
    }

    private static LineScan scanLine(String line, char quote) {
        LineScan r = new LineScan();
        int n = line.length();
        int codeEnd = n;
        int i = 0;

        while (i < n) {
            char c = line.charAt(i);
            if (quote == '"') {
                if (c == '\\') i += 2;
                else if (c == '"') { quote = 0; i++; }
                else i++;
            } else if (quote == '\'') {
                if (c == '\\' && i + 1 < n && line.charAt(i + 1) == '\'') i += 2;
                else if (c == '\'') { quote = 0; i++; }
                else i++;
            } else {
                if (c == '#') { codeEnd = i; break; }
                if (c == '"' || c == '\'') quote = c;
                i++;
            }
        }

        r.quote = quote;
        r.code = line.substring(0, Math.min(codeEnd, n));

        if (quote != 0) {
            r.continues = true;
            return r;
        }

        // A lone trailing backslash outside quotes continues explicitly.
        int end = r.code.length();
        while (end > 0 && Character.isWhitespace(r.code.charAt(end - 1))) end--;
        if (end > 0 && r.code.charAt(end - 1) == '\\') {
            r.continues = true;
            r.trailingBackslash = true;
            r.backslashAt = end - 1;
        }
        return r;
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
            Resp.sendCommand(out, List.of("QUIT"));
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
        return keyDetails ? describeKeys(keys) : keysOnly(keys);
    }

    /** Just the names — no follow-up command per key. */
    private static Rows keysOnly(List<String> keys) {
        List<Cell[]> rows = new ArrayList<>(keys.size());
        for (String k : keys) rows.add(new Cell[] { Cell.of(k) });
        return new ListRows(new String[] { "key" }, new String[] { "string" }, rows);
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
                "SCAN", cursor, "MATCH", pattern, "COUNT", Integer.toString(scanCount)));
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
