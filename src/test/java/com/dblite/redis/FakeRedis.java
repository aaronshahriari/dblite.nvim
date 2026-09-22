package com.dblite.redis;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;

/**
 * An in-process Redis stand-in that speaks real RESP over a real socket.
 *
 * It stores real data and implements enough of the command set to exercise the
 * whole client path — including a genuinely batched SCAN cursor — so the tests
 * do not depend on a Redis being installed. Behaviour that the client relies on
 * is modelled faithfully: SCAN batches, may repeat a key across iterations, and
 * applies MATCH after retrieval.
 */
final class FakeRedis implements AutoCloseable {

    /** Value types mirroring Redis' own TYPE names. */
    private enum Type { STRING, LIST, SET, ZSET, HASH, STREAM }

    private static final class Entry {
        Type type;
        String string;
        List<String> list;
        LinkedHashSet<String> set;
        LinkedHashMap<String, Double> zset;
        LinkedHashMap<String, String> hash;
        long ttl = -1;
    }

    private final ServerSocket server;
    private final Thread acceptor;
    private final Map<String, Entry> data = new LinkedHashMap<>();
    private volatile boolean running = true;

    /** Keys per SCAN iteration — deliberately small so the cursor loop is exercised. */
    private final int scanBatch;

    /** When set, SCAN repeats the first key of each batch, as a real SCAN may. */
    private final boolean scanDuplicates;

    private final String requiredPassword;

    /** Counts SCAN calls so tests can prove the exact-key path avoids one. */
    private final java.util.concurrent.atomic.AtomicInteger scanCalls =
        new java.util.concurrent.atomic.AtomicInteger();

    FakeRedis() throws IOException { this(3, false, null); }

    FakeRedis(int scanBatch, boolean scanDuplicates, String requiredPassword) throws IOException {
        this.scanBatch = scanBatch;
        this.scanDuplicates = scanDuplicates;
        this.requiredPassword = requiredPassword;
        this.server = new ServerSocket(0);
        this.acceptor = new Thread(this::acceptLoop, "fake-redis");
        this.acceptor.setDaemon(true);
        this.acceptor.start();
    }

    String url() { return "redis://127.0.0.1:" + server.getLocalPort(); }
    int scanCalls() { return scanCalls.get(); }
    int port()   { return server.getLocalPort(); }

    // --- Seeding (called from tests, before connecting) ---------------------

    void set(String key, String value) {
        Entry e = new Entry();
        e.type = Type.STRING;
        e.string = value;
        data.put(key, e);
    }

    void expire(String key, long seconds) {
        Entry e = data.get(key);
        if (e != null) e.ttl = seconds;
    }

    void hash(String key, Map<String, String> fields) {
        Entry e = new Entry();
        e.type = Type.HASH;
        e.hash = new LinkedHashMap<>(fields);
        data.put(key, e);
    }

    void list(String key, List<String> values) {
        Entry e = new Entry();
        e.type = Type.LIST;
        e.list = new ArrayList<>(values);
        data.put(key, e);
    }

    void setOf(String key, LinkedHashSet<String> members) {
        Entry e = new Entry();
        e.type = Type.SET;
        e.set = new LinkedHashSet<>(members);
        data.put(key, e);
    }

    void zset(String key, LinkedHashMap<String, Double> members) {
        Entry e = new Entry();
        e.type = Type.ZSET;
        e.zset = new LinkedHashMap<>(members);
        data.put(key, e);
    }

    // --- Server -------------------------------------------------------------

    private void acceptLoop() {
        while (running) {
            try {
                Socket s = server.accept();
                Thread t = new Thread(() -> serve(s), "fake-redis-conn");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                return;   // socket closed during shutdown
            }
        }
    }

    private void serve(Socket socket) {
        try (socket;
             InputStream in = new BufferedInputStream(socket.getInputStream());
             OutputStream out = new BufferedOutputStream(socket.getOutputStream())) {
            socket.setTcpNoDelay(true);
            while (running) {
                List<String> args = readCommand(in);
                if (args == null) return;
                if (args.isEmpty()) continue;
                boolean quit = dispatch(args, out);
                out.flush();
                if (quit) return;
            }
        } catch (IOException ignored) {
            // client went away
        }
    }

    /** Reads one inbound command, which is always a RESP array of bulk strings. */
    private static List<String> readCommand(InputStream in) throws IOException {
        int marker = in.read();
        if (marker < 0) return null;
        if (marker != '*') throw new IOException("expected array, got " + (char) marker);
        int count = Integer.parseInt(line(in));
        List<String> args = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            int dollar = in.read();
            if (dollar != '$') throw new IOException("expected bulk, got " + (char) dollar);
            int len = Integer.parseInt(line(in));
            byte[] buf = new byte[len];
            int off = 0;
            while (off < len) {
                int r = in.read(buf, off, len - off);
                if (r < 0) throw new IOException("short read");
                off += r;
            }
            in.read(); in.read();   // CRLF
            args.add(new String(buf, StandardCharsets.UTF_8));
        }
        return args;
    }

    private static String line(InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        int c;
        while ((c = in.read()) >= 0) {
            if (c == '\r') { in.read(); break; }
            sb.append((char) c);
        }
        return sb.toString();
    }

    // --- Dispatch -----------------------------------------------------------

    /** Returns true when the connection should close (QUIT). */
    private boolean dispatch(List<String> args, OutputStream out) throws IOException {
        String cmd = args.get(0).toUpperCase(java.util.Locale.ROOT);
        switch (cmd) {
            case "QUIT":   simple(out, "OK"); return true;
            case "PING":   simple(out, "PONG"); return false;
            case "AUTH": {
                String supplied = args.get(args.size() - 1);
                if (requiredPassword == null)             error(out, "ERR Client sent AUTH, but no password is set");
                else if (requiredPassword.equals(supplied)) simple(out, "OK");
                else                                       error(out, "WRONGPASS invalid username-password pair");
                return false;
            }
            case "SELECT": simple(out, "OK"); return false;
            case "SET":    set(args.get(1), args.get(2)); simple(out, "OK"); return false;
            case "DEL":    integer(out, data.remove(args.get(1)) != null ? 1 : 0); return false;
            case "EXISTS": integer(out, data.containsKey(args.get(1)) ? 1 : 0); return false;
            case "TYPE": {
                Entry e = data.get(args.get(1));
                simple(out, e == null ? "none" : e.type.name().toLowerCase(java.util.Locale.ROOT));
                return false;
            }
            case "TTL": {
                Entry e = data.get(args.get(1));
                integer(out, e == null ? -2 : e.ttl);
                return false;
            }
            case "GET": {
                Entry e = data.get(args.get(1));
                if (e == null)                  nil(out);
                else if (e.type != Type.STRING) error(out, "WRONGTYPE Operation against a key holding the wrong kind of value");
                else                            bulk(out, e.string);
                return false;
            }
            case "STRLEN": integer(out, sizeOf(args.get(1))); return false;
            case "LLEN":   integer(out, sizeOf(args.get(1))); return false;
            case "SCARD":  integer(out, sizeOf(args.get(1))); return false;
            case "ZCARD":  integer(out, sizeOf(args.get(1))); return false;
            case "HLEN":   integer(out, sizeOf(args.get(1))); return false;
            case "XLEN":   integer(out, sizeOf(args.get(1))); return false;
            case "HGETALL": {
                Entry e = data.get(args.get(1));
                if (e == null || e.hash == null) { array(out, List.of()); return false; }
                List<String> flat = new ArrayList<>();
                e.hash.forEach((k, v) -> { flat.add(k); flat.add(v); });
                array(out, flat);
                return false;
            }
            case "LRANGE": {
                Entry e = data.get(args.get(1));
                array(out, e == null || e.list == null ? List.of() : e.list);
                return false;
            }
            case "SMEMBERS": {
                Entry e = data.get(args.get(1));
                array(out, e == null || e.set == null ? List.of() : new ArrayList<>(e.set));
                return false;
            }
            case "ZRANGE": {
                Entry e = data.get(args.get(1));
                if (e == null || e.zset == null) { array(out, List.of()); return false; }
                boolean withScores = args.stream().anyMatch(a -> a.equalsIgnoreCase("WITHSCORES"));
                List<String> flat = new ArrayList<>();
                e.zset.forEach((m, s) -> {
                    flat.add(m);
                    if (withScores) flat.add(formatScore(s));
                });
                array(out, flat);
                return false;
            }
            case "INFO": {
                bulk(out, "# Server\r\nredis_version:7.2.4\r\nuptime_in_seconds:1234\r\n"
                        + "\r\n# Replication\r\nrole:master\r\nconnected_slaves:0\r\n");
                return false;
            }
            case "CONFIG": {
                if (args.size() > 1 && args.get(1).equalsIgnoreCase("GET")) {
                    array(out, List.of("maxmemory", "0", "appendonly", "no"));
                } else {
                    simple(out, "OK");
                }
                return false;
            }
            case "SCAN":   scan(args, out); return false;
            case "KEYS":   error(out, "ERR fake server does not serve KEYS directly"); return false;
            default:
                error(out, "ERR unknown command '" + args.get(0) + "'");
                return false;
        }
    }

    private static String formatScore(double d) {
        if (d == Math.rint(d) && Math.abs(d) < 1e15) return Long.toString((long) d);
        return Double.toString(d);
    }

    private long sizeOf(String key) {
        Entry e = data.get(key);
        if (e == null) return 0;
        switch (e.type) {
            case STRING: return e.string.length();
            case LIST:   return e.list.size();
            case SET:    return e.set.size();
            case ZSET:   return e.zset.size();
            case HASH:   return e.hash.size();
            default:     return 0;
        }
    }

    /**
     * Cursor-based SCAN over an index-ordered snapshot of the keyspace. MATCH is
     * applied after the batch is taken, exactly as Redis does, so a narrow
     * pattern really does yield mostly-empty iterations.
     */
    private void scan(List<String> args, OutputStream out) throws IOException {
        scanCalls.incrementAndGet();
        int cursor = Integer.parseInt(args.get(1));
        String match = "*";
        for (int i = 2; i + 1 < args.size(); i += 2) {
            if (args.get(i).equalsIgnoreCase("MATCH")) match = args.get(i + 1);
        }

        List<String> all = new ArrayList<>(data.keySet());
        int end = Math.min(cursor + scanBatch, all.size());
        List<String> batch = new ArrayList<>();
        for (int i = cursor; i < end; i++) {
            String k = all.get(i);
            if (glob(match, k)) batch.add(k);
        }
        // A real SCAN may hand back a key it already returned; make sure the
        // client de-duplicates rather than trusting the server.
        if (scanDuplicates && !batch.isEmpty()) batch.add(batch.get(0));

        int nextCursor = end >= all.size() ? 0 : end;

        out.write(("*2\r\n").getBytes(StandardCharsets.UTF_8));
        writeBulk(out, Integer.toString(nextCursor));
        out.write(("*" + batch.size() + "\r\n").getBytes(StandardCharsets.UTF_8));
        for (String k : batch) writeBulk(out, k);
    }

    /** Redis glob matching: * ? [abc] [a-c] [^a] with \ escaping. */
    static boolean glob(String pattern, String s) {
        return globMatch(pattern, 0, s, 0);
    }

    private static boolean globMatch(String p, int pi, String s, int si) {
        while (pi < p.length()) {
            char pc = p.charAt(pi);
            if (pc == '*') {
                for (int skip = si; skip <= s.length(); skip++) {
                    if (globMatch(p, pi + 1, s, skip)) return true;
                }
                return false;
            }
            if (si >= s.length()) return false;
            if (pc == '?') { pi++; si++; continue; }
            if (pc == '[') {
                int close = p.indexOf(']', pi + 1);
                if (close < 0) return false;
                String cls = p.substring(pi + 1, close);
                boolean negate = cls.startsWith("^");
                if (negate) cls = cls.substring(1);
                boolean hit = false;
                for (int i = 0; i < cls.length(); i++) {
                    if (i + 2 < cls.length() && cls.charAt(i + 1) == '-') {
                        if (s.charAt(si) >= cls.charAt(i) && s.charAt(si) <= cls.charAt(i + 2)) hit = true;
                        i += 2;
                    } else if (cls.charAt(i) == s.charAt(si)) {
                        hit = true;
                    }
                }
                if (hit == negate) return false;
                pi = close + 1;
                si++;
                continue;
            }
            if (pc == '\\' && pi + 1 < p.length()) pi++;
            if (p.charAt(pi) != s.charAt(si)) return false;
            pi++; si++;
        }
        return si == s.length();
    }

    // --- RESP writing -------------------------------------------------------

    private static void simple(OutputStream out, String s) throws IOException {
        out.write(("+" + s + "\r\n").getBytes(StandardCharsets.UTF_8));
    }

    private static void error(OutputStream out, String s) throws IOException {
        out.write(("-" + s + "\r\n").getBytes(StandardCharsets.UTF_8));
    }

    private static void integer(OutputStream out, long v) throws IOException {
        out.write((":" + v + "\r\n").getBytes(StandardCharsets.UTF_8));
    }

    private static void nil(OutputStream out) throws IOException {
        out.write("$-1\r\n".getBytes(StandardCharsets.UTF_8));
    }

    private static void bulk(OutputStream out, String s) throws IOException {
        writeBulk(out, s);
    }

    private static void writeBulk(OutputStream out, String s) throws IOException {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        out.write(("$" + b.length + "\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(b);
        out.write("\r\n".getBytes(StandardCharsets.UTF_8));
    }

    private static void array(OutputStream out, List<String> items) throws IOException {
        out.write(("*" + items.size() + "\r\n").getBytes(StandardCharsets.UTF_8));
        for (String i : items) writeBulk(out, i);
    }

    @Override
    public void close() throws IOException {
        running = false;
        server.close();
    }
}
