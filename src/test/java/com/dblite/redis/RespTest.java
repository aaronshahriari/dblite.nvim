package com.dblite.redis;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;

import org.junit.jupiter.api.Test;

class RespTest {

    private static RespValue decode(String wire) throws IOException {
        return Resp.read(new ByteArrayInputStream(wire.getBytes(StandardCharsets.UTF_8)));
    }

    // --- Reading ------------------------------------------------------------

    @Test
    void readsResp2Scalars() throws Exception {
        assertEquals("OK", decode("+OK\r\n").asText());
        assertEquals(42L, decode(":42\r\n").integer);
        assertEquals("hello", decode("$5\r\nhello\r\n").asText());
        assertTrue(decode("$-1\r\n").isNull());
        assertTrue(decode("*-1\r\n").isNull());
        assertTrue(decode("-ERR nope\r\n").isError());
    }

    @Test
    void readsResp3Scalars() throws Exception {
        assertTrue(decode("_\r\n").isNull());
        assertEquals("1.5", decode(",1.5\r\n").asText());
        assertEquals("inf", decode(",inf\r\n").asText());
        assertEquals("true", decode("#t\r\n").asText());
        assertEquals("false", decode("#f\r\n").asText());
        assertEquals("12345678901234567890", decode("(12345678901234567890\r\n").asText());
    }

    @Test
    void readsNestedArrays() throws Exception {
        RespValue v = decode("*2\r\n$3\r\nfoo\r\n*2\r\n:1\r\n:2\r\n");
        assertEquals(2, v.items.size());
        assertEquals("foo", v.items.get(0).asText());
        assertEquals(2, v.items.get(1).items.size());
    }

    /** A RESP3 map must decode to the same flat shape as a RESP2 pair array. */
    @Test
    void flattensResp3MapsIntoPairs() throws Exception {
        RespValue v = decode("%2\r\n$1\r\na\r\n:1\r\n$1\r\nb\r\n:2\r\n");
        assertEquals(RespValue.Kind.MAP, v.kind);
        assertEquals(4, v.items.size());
        assertEquals("a", v.items.get(0).asText());
        assertEquals("1", v.items.get(1).asText());
        assertEquals("b", v.items.get(2).asText());
        assertEquals("2", v.items.get(3).asText());
    }

    @Test
    void stripsVerbatimStringFormatHint() throws Exception {
        assertEquals("hello", decode("=9\r\ntxt:hello\r\n").asText());
    }

    @Test
    void readsBlobErrorAsError() throws Exception {
        RespValue v = decode("!8\r\nBAD word\r\n");
        assertTrue(v.isError());
        assertEquals("BAD word", v.text);
    }

    /** Bulk payloads are length-prefixed, so embedded CRLF must survive intact. */
    @Test
    void bulkPayloadKeepsEmbeddedNewlines() throws Exception {
        assertEquals("a\r\nb", decode("$4\r\na\r\nb\r\n").asText());
    }

    @Test
    void nonUtf8BulkIsReportedAsBinaryRatherThanCorrupted() throws Exception {
        byte[] wire = new byte[] { '$', '2', '\r', '\n', (byte) 0xC3, (byte) 0x28, '\r', '\n' };
        RespValue v = Resp.read(new ByteArrayInputStream(wire));
        assertEquals(null, v.asText());
        assertArrayEquals(new byte[] { (byte) 0xC3, (byte) 0x28 }, v.bytes);
    }

    @Test
    void rejectsMalformedFraming() {
        assertThrows(IOException.class, () -> decode("$3\r\nab\r\n"));
        assertThrows(IOException.class, () -> decode("&nope\r\n"));
        assertThrows(IOException.class, () -> decode("$notanumber\r\n"));
    }

    // --- Writing ------------------------------------------------------------

    @Test
    void writesCommandAsBulkStringArray() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Resp.writeCommand(out, List.of("SET", "k", "v"));
        assertEquals("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n",
            out.toString(StandardCharsets.UTF_8));
    }

    /** Length prefixes are byte counts, not character counts. */
    @Test
    void writesMultibyteArgumentWithByteLength() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Resp.writeCommand(out, List.of("SET", "k", "é"));
        assertTrue(out.toString(StandardCharsets.UTF_8).endsWith("$2\r\né\r\n"));
    }

    // --- Tokenising ---------------------------------------------------------

    @Test
    void tokenizesPlainCommand() {
        assertEquals(List.of("GET", "user:1"), Resp.tokenize("GET user:1"));
        assertEquals(List.of("GET", "user:1"), Resp.tokenize("  GET   user:1  "));
    }

    @Test
    void tokenizesQuotedValueContainingSpaces() {
        assertEquals(List.of("SET", "k", "hello world"), Resp.tokenize("SET k \"hello world\""));
        assertEquals(List.of("SET", "k", "hello world"), Resp.tokenize("SET k 'hello world'"));
    }

    /** The fix for redis-cli's newline round-trip problem starts here. */
    @Test
    void tokenizesEscapesInsideDoubleQuotes() {
        assertEquals(List.of("SET", "k", "a\nb"), Resp.tokenize("SET k \"a\\nb\""));
        assertEquals(List.of("SET", "k", "a\tb"), Resp.tokenize("SET k \"a\\tb\""));
        assertEquals(List.of("SET", "k", "a\"b"), Resp.tokenize("SET k \"a\\\"b\""));
        assertEquals(List.of("SET", "k", "aAb"), Resp.tokenize("SET k \"a\\x41b\""));
    }

    @Test
    void singleQuotesAreLiteralApartFromEscapedQuote() {
        assertEquals(List.of("SET", "k", "a\\nb"), Resp.tokenize("SET k 'a\\nb'"));
        assertEquals(List.of("SET", "k", "it's"), Resp.tokenize("SET k 'it\\'s'"));
    }

    @Test
    void preservesEmptyQuotedArgument() {
        assertEquals(List.of("SET", "k", ""), Resp.tokenize("SET k \"\""));
    }

    @Test
    void tokenizesJsonValueWithoutMangling() {
        List<String> t = Resp.tokenize("SET cfg '{\"a\": 1, \"b\": [2, 3]}'");
        assertEquals(3, t.size());
        assertEquals("{\"a\": 1, \"b\": [2, 3]}", t.get(2));
    }

    @Test
    void emptyInputYieldsNoTokens() {
        assertTrue(Resp.tokenize("").isEmpty());
        assertTrue(Resp.tokenize("   ").isEmpty());
    }
}
