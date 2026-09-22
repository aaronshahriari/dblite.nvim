package com.dblite.redis;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * RESP codec. Commands are written as RESP2 arrays of bulk strings, which every
 * Redis, Valkey and Dragonfly release understands. The reader additionally
 * handles the RESP3 types so a server that has been switched to RESP3 (by a
 * HELLO the user issued themselves) still decodes cleanly.
 */
public final class Resp {
    private Resp() {}

    private static final int MAX_BULK = 512 * 1024 * 1024; // Redis' own 512MB cap

    // --- Writing -----------------------------------------------------------

    /** Writes one command as a RESP array of bulk strings. */
    public static void writeCommand(OutputStream out, List<String> args) throws IOException {
        StringBuilder sb = new StringBuilder();
        sb.append('*').append(args.size()).append("\r\n");
        for (String arg : args) {
            byte[] b = arg.getBytes(StandardCharsets.UTF_8);
            sb.append('$').append(b.length).append("\r\n").append(arg).append("\r\n");
        }
        out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    // --- Reading -----------------------------------------------------------

    public static RespValue read(InputStream in) throws IOException {
        int marker = in.read();
        if (marker < 0) throw new EOFException("connection closed by server");
        switch (marker) {
            case '+': return RespValue.simple(readLine(in));
            case '-': return RespValue.error(readLine(in));
            case ':': return RespValue.integer(parseLong(readLine(in)));
            case '$': return readBulk(in, readLine(in));
            case '=': return readVerbatim(in);
            case '!': return readBlobError(in);
            case '*': return readAggregate(in, RespValue.Kind.ARRAY, 1);
            case '%': return readAggregate(in, RespValue.Kind.MAP,   2);
            case '~': return readAggregate(in, RespValue.Kind.SET,   1);
            case '>': return readAggregate(in, RespValue.Kind.PUSH,  1);
            case '_': readLine(in); return RespValue.nil();
            case ',': return RespValue.dbl(Bytes.parseDouble(readLine(in)));
            case '#': return RespValue.bool("t".equalsIgnoreCase(readLine(in).trim()));
            case '(': return RespValue.bigNumber(readLine(in));
            default:
                throw new IOException("Unexpected RESP type byte: '" + (char) marker + "'");
        }
    }

    private static RespValue readBulk(InputStream in, String lengthLine) throws IOException {
        long len = parseLong(lengthLine);
        if (len < 0) return RespValue.nil();          // RESP2 null bulk string
        if (len > MAX_BULK) throw new IOException("Bulk reply exceeds 512MB: " + len);
        byte[] buf = readExactly(in, (int) len);
        expectCrlf(in);
        return RespValue.bulk(buf);
    }

    /**
     * RESP3 verbatim strings carry a three-char format hint ("txt:", "mkd:").
     * The hint is metadata about rendering, not part of the value, so it is
     * stripped — the payload itself is what belongs in a cell.
     */
    private static RespValue readVerbatim(InputStream in) throws IOException {
        long len = parseLong(readLine(in));
        if (len < 0) return RespValue.nil();
        if (len > MAX_BULK) throw new IOException("Verbatim reply exceeds 512MB: " + len);
        byte[] buf = readExactly(in, (int) len);
        expectCrlf(in);
        if (buf.length >= 4 && buf[3] == ':') {
            byte[] stripped = new byte[buf.length - 4];
            System.arraycopy(buf, 4, stripped, 0, stripped.length);
            return RespValue.bulk(stripped);
        }
        return RespValue.bulk(buf);
    }

    private static RespValue readBlobError(InputStream in) throws IOException {
        long len = parseLong(readLine(in));
        if (len < 0) return RespValue.error("");
        byte[] buf = readExactly(in, (int) len);
        expectCrlf(in);
        String msg = Bytes.toText(buf);
        return RespValue.error(msg == null ? Bytes.binaryPlaceholder(buf) : msg);
    }

    /**
     * `unitsPerElement` is 2 for maps, whose header counts pairs rather than
     * entries; flattening them here keeps RESP2 and RESP3 shapes identical.
     */
    private static RespValue readAggregate(InputStream in, RespValue.Kind kind, int unitsPerElement)
            throws IOException {
        long count = parseLong(readLine(in));
        if (count < 0) return RespValue.nil();        // RESP2 null array
        long total = count * unitsPerElement;
        if (total > Integer.MAX_VALUE) throw new IOException("Aggregate reply too large: " + total);
        List<RespValue> items = new ArrayList<>((int) Math.min(total, 1024));
        for (long i = 0; i < total; i++) {
            items.add(read(in));
        }
        return RespValue.aggregate(kind, items);
    }

    // --- Low-level framing -------------------------------------------------

    /** Reads up to CRLF. Protocol framing lines are always ASCII. */
    private static String readLine(InputStream in) throws IOException {
        java.io.ByteArrayOutputStream buf = new java.io.ByteArrayOutputStream(32);
        while (true) {
            int c = in.read();
            if (c < 0) throw new EOFException("connection closed mid-reply");
            if (c == '\r') {
                int lf = in.read();
                if (lf < 0) throw new EOFException("connection closed mid-reply");
                if (lf != '\n') throw new IOException("Malformed RESP framing: expected LF after CR");
                break;
            }
            if (c == '\n') break;   // tolerate a bare LF
            buf.write(c);
        }
        return buf.toString(StandardCharsets.UTF_8);
    }

    private static byte[] readExactly(InputStream in, int len) throws IOException {
        byte[] buf = new byte[len];
        int off = 0;
        while (off < len) {
            int read = in.read(buf, off, len - off);
            if (read < 0) throw new EOFException("connection closed mid-payload");
            off += read;
        }
        return buf;
    }

    private static void expectCrlf(InputStream in) throws IOException {
        int cr = in.read();
        int lf = in.read();
        if (cr < 0 || lf < 0) throw new EOFException("connection closed after payload");
        if (cr != '\r' || lf != '\n') throw new IOException("Malformed RESP framing after payload");
    }

    private static long parseLong(String s) throws IOException {
        try {
            return Long.parseLong(s.trim());
        } catch (NumberFormatException e) {
            throw new IOException("Malformed RESP length: '" + s + "'");
        }
    }

    // --- Command tokenising ------------------------------------------------

    /**
     * Splits one command line into arguments the way redis-cli does: whitespace
     * separates, double quotes allow escapes (including \xHH), single quotes are
     * literal apart from \'. This is what lets a value containing spaces or a
     * newline be typed directly into a buffer.
     */
    public static List<String> tokenize(String line) {
        List<String> out = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean inToken = false;
        int i = 0;
        int n = line.length();

        while (i < n) {
            char c = line.charAt(i);

            if (!inToken && Character.isWhitespace(c)) { i++; continue; }

            if (c == '"') {
                inToken = true;
                i++;
                while (i < n && line.charAt(i) != '"') {
                    char d = line.charAt(i);
                    if (d == '\\' && i + 1 < n) {
                        i++;
                        char e = line.charAt(i);
                        switch (e) {
                            case 'n': cur.append('\n'); break;
                            case 'r': cur.append('\r'); break;
                            case 't': cur.append('\t'); break;
                            case 'b': cur.append('\b'); break;
                            case 'f': cur.append('\f'); break;
                            case 'a': cur.append((char) 7); break;
                            case '\\': cur.append('\\'); break;
                            case '"': cur.append('"'); break;
                            case 'x':
                                if (i + 2 < n && isHex(line.charAt(i + 1)) && isHex(line.charAt(i + 2))) {
                                    cur.append((char) Integer.parseInt(line.substring(i + 1, i + 3), 16));
                                    i += 2;
                                } else {
                                    cur.append('x');
                                }
                                break;
                            default: cur.append(e);
                        }
                        i++;
                    } else {
                        cur.append(d);
                        i++;
                    }
                }
                if (i < n) i++;   // closing quote
                continue;
            }

            if (c == '\'') {
                inToken = true;
                i++;
                while (i < n && line.charAt(i) != '\'') {
                    char d = line.charAt(i);
                    if (d == '\\' && i + 1 < n && line.charAt(i + 1) == '\'') {
                        cur.append('\'');
                        i += 2;
                    } else {
                        cur.append(d);
                        i++;
                    }
                }
                if (i < n) i++;   // closing quote
                continue;
            }

            if (Character.isWhitespace(c)) {
                out.add(cur.toString());
                cur.setLength(0);
                inToken = false;
                i++;
                continue;
            }

            inToken = true;
            cur.append(c);
            i++;
        }

        if (inToken) out.add(cur.toString());
        return out;
    }

    private static boolean isHex(char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
}
