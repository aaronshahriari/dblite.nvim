package com.dblite.redis;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;

/**
 * Flush accounting. A pipeline's whole point is to put many commands on the
 * wire before reading any reply; flushing per command turns one batch into one
 * packet per command, which with TCP_NODELAY set is exactly what goes out.
 */
class RespWriteTest {

    /** Counts flushes and write calls without keeping the bytes. */
    private static final class CountingStream extends OutputStream {
        int flushes = 0;
        int writes  = 0;
        long bytes  = 0;

        @Override public void write(int b) { writes++; bytes++; }
        @Override public void write(byte[] b, int off, int len) { writes++; bytes += len; }
        @Override public void flush() { flushes++; }
    }

    @Test
    void writingACommandDoesNotFlushIt() throws IOException {
        CountingStream out = new CountingStream();
        Resp.writeCommand(out, List.of("TYPE", "user:1042"));
        assertEquals(0, out.flushes,
            "writeCommand must leave flushing to the caller, so a batch stays a batch");
    }

    /**
     * The shape that matters: 512 commands buffered, then one flush. Anything
     * more than a single flush here means the pipeline is emitting a packet per
     * command.
     */
    @Test
    void aBatchOfCommandsCostsOneFlush() throws IOException {
        CountingStream out = new CountingStream();
        List<List<String>> batch = new ArrayList<>();
        for (int i = 0; i < 512; i++) batch.add(List.of("TYPE", "user:" + i));

        for (List<String> cmd : batch) Resp.writeCommand(out, cmd);
        out.flush();

        assertEquals(1, out.flushes, "512 commands should cost exactly one flush");
    }
}
