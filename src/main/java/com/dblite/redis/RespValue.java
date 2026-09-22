package com.dblite.redis;

import java.util.List;

/**
 * A decoded RESP reply.
 *
 * RESP3's map type is flattened into key,value,key,value inside {@link #items}
 * so that a RESP3 map and the equivalent RESP2 flat array shape identically —
 * HGETALL and CONFIG GET then need no protocol-version branching downstream.
 *
 * Bulk payloads keep their raw bytes: Redis values are arbitrary binary, and
 * deciding whether something is displayable text belongs to the shaper.
 */
public final class RespValue {
    public enum Kind { SIMPLE, ERROR, INT, BULK, ARRAY, MAP, SET, PUSH, NULL, DOUBLE, BOOL, BIGNUM }

    public final Kind kind;
    public final String text;          // SIMPLE, ERROR, BIGNUM
    public final byte[] bytes;         // BULK
    public final long integer;         // INT
    public final double number;        // DOUBLE
    public final boolean bool;         // BOOL
    public final List<RespValue> items; // ARRAY, MAP (flattened), SET, PUSH

    private RespValue(Kind kind, String text, byte[] bytes, long integer,
                      double number, boolean bool, List<RespValue> items) {
        this.kind = kind;
        this.text = text;
        this.bytes = bytes;
        this.integer = integer;
        this.number = number;
        this.bool = bool;
        this.items = items;
    }

    public static RespValue simple(String s)    { return new RespValue(Kind.SIMPLE, s, null, 0, 0, false, null); }
    public static RespValue error(String s)     { return new RespValue(Kind.ERROR,  s, null, 0, 0, false, null); }
    public static RespValue bigNumber(String s) { return new RespValue(Kind.BIGNUM, s, null, 0, 0, false, null); }
    public static RespValue bulk(byte[] b)      { return new RespValue(Kind.BULK, null, b, 0, 0, false, null); }
    public static RespValue integer(long v)     { return new RespValue(Kind.INT, null, null, v, 0, false, null); }
    public static RespValue dbl(double v)       { return new RespValue(Kind.DOUBLE, null, null, 0, v, false, null); }
    public static RespValue bool(boolean v)     { return new RespValue(Kind.BOOL, null, null, 0, 0, v, null); }
    public static RespValue nil()               { return new RespValue(Kind.NULL, null, null, 0, 0, false, null); }

    public static RespValue aggregate(Kind kind, List<RespValue> items) {
        return new RespValue(kind, null, null, 0, 0, false, items);
    }

    public boolean isError()     { return kind == Kind.ERROR; }
    public boolean isNull()      { return kind == Kind.NULL; }
    public boolean isAggregate() { return items != null; }

    /**
     * Displayable text for a scalar reply, or null when the value is binary
     * that will not survive a round trip as UTF-8.
     */
    public String asText() {
        switch (kind) {
            case SIMPLE:
            case ERROR:
            case BIGNUM: return text;
            case BULK:   return Bytes.toText(bytes);
            case INT:    return Long.toString(integer);
            case DOUBLE: return Bytes.formatDouble(number);
            case BOOL:   return bool ? "true" : "false";
            case NULL:   return null;
            default:     return null;
        }
    }

    /** Scalar text for contexts that must not fail, e.g. a key name. */
    public String asTextOrEmpty() {
        String s = asText();
        return s == null ? "" : s;
    }
}
