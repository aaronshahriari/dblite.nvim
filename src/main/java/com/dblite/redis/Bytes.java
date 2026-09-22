package com.dblite.redis;

import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Byte/text conversions for Redis payloads. */
final class Bytes {
    private Bytes() {}

    /**
     * Strict UTF-8 decode. Returns null when the payload is not valid UTF-8, so
     * callers can render it as a binary placeholder rather than silently
     * corrupting it with replacement characters — the same treatment JDBC BLOBs
     * get elsewhere in dblite.
     */
    static String toText(byte[] b) {
        if (b == null) return null;
        CharsetDecoder decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT);
        try {
            CharBuffer out = decoder.decode(ByteBuffer.wrap(b));
            return out.toString();
        } catch (CharacterCodingException e) {
            return null;
        }
    }

    /** Human-readable placeholder for a value that is not displayable text. */
    static String binaryPlaceholder(byte[] b) {
        return "<BINARY " + (b == null ? 0 : b.length) + " bytes>";
    }

    /**
     * RESP doubles use "inf"/"-inf"/"nan" on the wire; keep integral values free
     * of a trailing ".0" so scores read naturally in the grid.
     */
    static String formatDouble(double d) {
        if (Double.isNaN(d)) return "nan";
        if (d == Double.POSITIVE_INFINITY) return "inf";
        if (d == Double.NEGATIVE_INFINITY) return "-inf";
        if (d == Math.rint(d) && Math.abs(d) < 1e15) return Long.toString((long) d);
        return Double.toString(d);
    }

    static double parseDouble(String s) {
        String t = s.trim().toLowerCase(java.util.Locale.ROOT);
        switch (t) {
            case "inf":
            case "+inf":  return Double.POSITIVE_INFINITY;
            case "-inf":  return Double.NEGATIVE_INFINITY;
            case "nan":   return Double.NaN;
            default:      return Double.parseDouble(t);
        }
    }
}
