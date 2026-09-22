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
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * A large synthetic keyspace that counts what the client asks of it.
 *
 * SCAN iterations are the number that matters: the cursor is sequential, so
 * each one is a blocking round trip that cannot be pipelined away. On a remote
 * server they are multiplied by the full network latency, which is where a
 * key listing's wall time actually goes.
 */
final class ScanCountingServer implements AutoCloseable {

    final AtomicInteger scanCalls    = new AtomicInteger();
    final AtomicInteger totalCommands = new AtomicInteger();

    private final ServerSocket server;
    private final List<String> keys;
    private final int keyspaceSize;
    private volatile boolean running = true;

    /**
     * `matching` keys named `<prefix>:<n>` are mixed into a keyspace of
     * `keyspaceSize`, so MATCH has to walk the whole thing to find them —
     * which is how Redis really behaves.
     */
    ScanCountingServer(int keyspaceSize, int matching, String prefix) throws IOException {
        this.keyspaceSize = keyspaceSize;
        this.keys = new ArrayList<>(keyspaceSize);
        int stride = matching > 0 ? Math.max(1, keyspaceSize / matching) : keyspaceSize + 1;
        for (int i = 0; i < keyspaceSize; i++) {
            keys.add(i % stride == 0 ? prefix + ":" + i : "other:" + i);
        }
        this.server = new ServerSocket(0);
        Thread t = new Thread(this::acceptLoop, "scan-counting-server");
        t.setDaemon(true);
        t.start();
    }

    String url() { return "redis://127.0.0.1:" + server.getLocalPort(); }

    private void acceptLoop() {
        while (running) {
            try {
                Socket s = server.accept();
                Thread t = new Thread(() -> serve(s), "scan-conn");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                return;
            }
        }
    }

    private void serve(Socket socket) {
        try (socket;
             InputStream in = new BufferedInputStream(socket.getInputStream(), 1 << 16);
             OutputStream out = new BufferedOutputStream(socket.getOutputStream(), 1 << 16)) {
            socket.setTcpNoDelay(true);
            while (running) {
                List<String> args = readCommand(in);
                if (args == null) return;
                if (args.isEmpty()) continue;
                totalCommands.incrementAndGet();
                String c = args.get(0).toUpperCase(java.util.Locale.ROOT);
                switch (c) {
                    case "QUIT": simple(out, "OK"); out.flush(); return;
                    case "SCAN": scan(args, out); break;
                    case "TYPE": simple(out, "string"); break;
                    case "TTL":  integer(out, -1); break;
                    default:     integer(out, 0); break;   // STRLEN and friends
                }
                // Flush only when nothing more is buffered to read, so a
                // pipelined batch is answered in one go — as Redis does.
                if (in.available() == 0) out.flush();
            }
        } catch (IOException ignored) {
        }
    }

    private void scan(List<String> args, OutputStream out) throws IOException {
        scanCalls.incrementAndGet();
        int cursor = Integer.parseInt(args.get(1));
        String match = "*";
        int count = 10;
        for (int i = 2; i + 1 < args.size(); i += 2) {
            if (args.get(i).equalsIgnoreCase("MATCH")) match = args.get(i + 1);
            if (args.get(i).equalsIgnoreCase("COUNT")) count = Integer.parseInt(args.get(i + 1));
        }

        // COUNT bounds the keys examined, not the keys returned: MATCH is applied
        // after retrieval, exactly as Redis documents.
        int end = Math.min(cursor + count, keyspaceSize);
        List<String> batch = new ArrayList<>();
        for (int i = cursor; i < end; i++) {
            if (FakeRedis.glob(match, keys.get(i))) batch.add(keys.get(i));
        }
        int next = end >= keyspaceSize ? 0 : end;

        out.write("*2\r\n".getBytes(StandardCharsets.UTF_8));
        writeBulk(out, Integer.toString(next));
        out.write(("*" + batch.size() + "\r\n").getBytes(StandardCharsets.UTF_8));
        for (String k : batch) writeBulk(out, k);
    }

    private static List<String> readCommand(InputStream in) throws IOException {
        int marker = in.read();
        if (marker < 0) return null;
        if (marker != '*') throw new IOException("expected array");
        int n = Integer.parseInt(line(in));
        List<String> args = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            if (in.read() != '$') throw new IOException("expected bulk");
            int len = Integer.parseInt(line(in));
            byte[] buf = new byte[len];
            int off = 0;
            while (off < len) {
                int r = in.read(buf, off, len - off);
                if (r < 0) throw new IOException("short read");
                off += r;
            }
            in.read(); in.read();
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

    private static void simple(OutputStream out, String s) throws IOException {
        out.write(("+" + s + "\r\n").getBytes(StandardCharsets.UTF_8));
    }

    private static void integer(OutputStream out, long v) throws IOException {
        out.write((":" + v + "\r\n").getBytes(StandardCharsets.UTF_8));
    }

    private static void writeBulk(OutputStream out, String s) throws IOException {
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        out.write(("$" + b.length + "\r\n").getBytes(StandardCharsets.UTF_8));
        out.write(b);
        out.write("\r\n".getBytes(StandardCharsets.UTF_8));
    }

    @Override
    public void close() throws IOException {
        running = false;
        server.close();
    }
}
