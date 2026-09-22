package com.dblite.redis;

import com.dblite.Json;
import com.dblite.ListRows;
import com.dblite.ListRows.Cell;
import com.dblite.Rows;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Turns a decoded RESP reply into grid columns.
 *
 * The goal is that a Redis reply reads the way its data structure reads: a hash
 * becomes field/value, a sorted set becomes member/score, a list becomes
 * index/value. Anything that does not fit a known shape falls back to a single
 * `value` column rather than being force-fitted.
 */
final class RedisShaper {
    private RedisShaper() {}

    static final String T_STRING = "string";
    static final String T_INT    = "integer";
    static final String T_DOUBLE = "double";
    static final String T_BOOL   = "boolean";
    static final String T_JSON   = "json";
    static final String T_BINARY = "binary";
    static final String T_INDEX  = "index";

    /** Commands whose flat array reply is really field/value pairs. */
    private static boolean pairwise(String cmd, String sub, List<String> args) {
        if (cmd.equals("HGETALL")) return true;
        if (cmd.equals("CONFIG") && "GET".equals(sub)) return true;
        if (cmd.equals("ZPOPMIN") || cmd.equals("ZPOPMAX")) return true;
        if (cmd.equals("HRANDFIELD") && hasFlag(args, "WITHVALUES")) return true;
        return false;
    }

    /** Sorted-set reads that interleave scores after the member. */
    private static boolean scored(String cmd, List<String> args) {
        if (cmd.equals("ZPOPMIN") || cmd.equals("ZPOPMAX")) return true;
        return cmd.startsWith("Z") && hasFlag(args, "WITHSCORES");
    }

    private static boolean hasFlag(List<String> args, String flag) {
        for (String a : args) {
            if (a.equalsIgnoreCase(flag)) return true;
        }
        return false;
    }

    static Rows shape(List<String> args, RespValue reply) {
        String cmd = args.isEmpty() ? "" : args.get(0).toUpperCase(Locale.ROOT);
        String sub = args.size() > 1 ? args.get(1).toUpperCase(Locale.ROOT) : "";

        if (cmd.equals("INFO")) {
            String text = reply.asText();
            if (text != null) return info(text);
        }

        if (reply.kind == RespValue.Kind.MAP) {
            return pairs(reply.items, "field", "value");
        }

        if (reply.isAggregate()) {
            List<RespValue> items = reply.items;
            if (pairwise(cmd, sub, args) && items.size() % 2 == 0) {
                boolean isScore = scored(cmd, args);
                return pairs(items, isScore ? "member" : "field", isScore ? "score" : "value");
            }
            if (scored(cmd, args) && items.size() % 2 == 0) {
                return pairs(items, "member", "score");
            }
            return list(items);
        }

        return scalar(reply);
    }

    // --- Shapes ------------------------------------------------------------

    /** Flat k,v,k,v into two columns. */
    private static Rows pairs(List<RespValue> items, String leftName, String rightName) {
        // Scores arrive as bulk strings; emit them as JSON numbers so they sort
        // and export as numbers rather than text.
        boolean numericRight = rightName.equals("score");
        List<Cell[]> rows = new ArrayList<>(items.size() / 2);
        for (int i = 0; i + 1 < items.size(); i += 2) {
            RespValue right = items.get(i + 1);
            Cell rightCell = numericRight ? numericCell(right) : cellOf(right);
            rows.add(new Cell[] { cellOf(items.get(i)), rightCell });
        }
        String rightType = columnType(items, 1, 2, rightName.equals("score") ? T_DOUBLE : T_STRING);
        return new ListRows(
            new String[] { leftName, rightName },
            new String[] { T_STRING, rightType },
            rows);
    }

    /** A plain array becomes index/value so positions stay visible after paging. */
    private static Rows list(List<RespValue> items) {
        List<Cell[]> rows = new ArrayList<>(items.size());
        for (int i = 0; i < items.size(); i++) {
            rows.add(new Cell[] { Cell.of((long) i), cellOf(items.get(i)) });
        }
        return new ListRows(
            new String[] { "index", "value" },
            new String[] { T_INDEX, columnType(items, 0, 1, T_STRING) },
            rows);
    }

    /**
     * A single value. JSONL expands to one row per line so that paging, export
     * and the inspect view all operate on records instead of one giant cell.
     */
    private static Rows scalar(RespValue reply) {
        if (reply.isNull()) {
            return ListRows.single("result", "null", Cell.nil());
        }
        if (reply.kind == RespValue.Kind.BULK) {
            String text = reply.asText();
            if (text == null) {
                return ListRows.single("result", T_BINARY, Cell.of(Bytes.binaryPlaceholder(reply.bytes)));
            }
            List<String> lines = jsonLines(text);
            if (lines != null) {
                List<Cell[]> rows = new ArrayList<>(lines.size());
                for (int i = 0; i < lines.size(); i++) {
                    rows.add(new Cell[] { Cell.of((long) i), Cell.of(lines.get(i)) });
                }
                return new ListRows(
                    new String[] { "line", "value" },
                    new String[] { T_INDEX, T_JSON },
                    rows);
            }
            return ListRows.single("result", Json.isJsonDocument(text) ? T_JSON : T_STRING, Cell.of(text));
        }
        return ListRows.single("result", scalarType(reply), cellOf(reply));
    }

    /** `INFO` returns an ini-style blob; section/field/value makes it filterable. */
    private static Rows info(String text) {
        List<Cell[]> rows = new ArrayList<>();
        String section = "";
        for (String raw : text.split("\r\n|\n|\r")) {
            String line = raw.trim();
            if (line.isEmpty()) continue;
            if (line.startsWith("#")) {
                section = line.substring(1).trim();
                continue;
            }
            int colon = line.indexOf(':');
            if (colon < 0) continue;
            rows.add(new Cell[] {
                Cell.of(section),
                Cell.of(line.substring(0, colon)),
                Cell.number(line.substring(colon + 1)),
            });
        }
        return new ListRows(
            new String[] { "section", "field", "value" },
            new String[] { T_STRING, T_STRING, T_STRING },
            rows);
    }

    // --- Cells -------------------------------------------------------------

    /** A cell that stays a JSON number when the payload is numeric. */
    private static Cell numericCell(RespValue v) {
        if (v == null || v.isNull()) return Cell.nil();
        String text = v.asText();
        return text == null ? cellOf(v) : Cell.number(text);
    }

    static Cell cellOf(RespValue v) {
        if (v == null || v.isNull()) return Cell.nil();
        switch (v.kind) {
            case INT:    return Cell.of(v.integer);
            case DOUBLE: return Cell.number(Bytes.formatDouble(v.number));
            case BOOL:   return Cell.bool(v.bool);
            case BULK: {
                String text = v.asText();
                return text == null ? Cell.of(Bytes.binaryPlaceholder(v.bytes)) : Cell.of(text);
            }
            case ARRAY:
            case SET:
            case PUSH:
            case MAP:
                // Nested structures (XRANGE entries, CLUSTER SLOTS) keep their
                // shape as JSON text so the inspect view can expand them.
                return Cell.of(toJsonText(v));
            default: {
                String text = v.asText();
                return text == null ? Cell.nil() : Cell.of(text);
            }
        }
    }

    private static String scalarType(RespValue v) {
        switch (v.kind) {
            case INT:    return T_INT;
            case DOUBLE: return T_DOUBLE;
            case BOOL:   return T_BOOL;
            case NULL:   return "null";
            default:     return T_STRING;
        }
    }

    /**
     * Column type for the value column: `json` only when every non-empty value
     * in it is a JSON document, so the tag is a reliable signal.
     */
    private static String columnType(List<RespValue> items, int offset, int stride, String fallback) {
        boolean sawValue = false;
        for (int i = offset; i < items.size(); i += stride) {
            RespValue v = items.get(i);
            if (v == null || v.isNull()) continue;
            String text = v.asText();
            if (text == null) return T_BINARY;
            if (text.isEmpty()) continue;
            sawValue = true;
            if (!Json.isJsonDocument(text)) return fallback;
        }
        return sawValue ? T_JSON : fallback;
    }

    /**
     * Splits a value into JSONL records, or returns null when it is not JSONL.
     * Requires at least two records so a pretty-printed single document (which
     * also contains newlines) is left intact.
     */
    private static List<String> jsonLines(String text) {
        if (text.indexOf('\n') < 0) return null;
        List<String> out = new ArrayList<>();
        for (String raw : text.split("\r\n|\n|\r")) {
            String line = raw.trim();
            if (line.isEmpty()) continue;
            if (!Json.isJsonDocument(line)) return null;
            out.add(line);
        }
        return out.size() >= 2 ? out : null;
    }

    /** Renders any reply as JSON text, for nesting inside a single cell. */
    static String toJsonText(RespValue v) {
        StringBuilder sb = new StringBuilder();
        writeJson(v, sb);
        return sb.toString();
    }

    private static void writeJson(RespValue v, StringBuilder sb) {
        if (v == null || v.isNull()) { sb.append("null"); return; }
        switch (v.kind) {
            case INT:    sb.append(v.integer); return;
            case DOUBLE: {
                String d = Bytes.formatDouble(v.number);
                sb.append(Json.isJsonNumber(d) ? d : Json.quote(d));
                return;
            }
            case BOOL:   sb.append(v.bool ? "true" : "false"); return;
            case MAP: {
                sb.append('{');
                for (int i = 0; i + 1 < v.items.size(); i += 2) {
                    if (i > 0) sb.append(", ");
                    sb.append(Json.quote(v.items.get(i).asTextOrEmpty())).append(": ");
                    writeJson(v.items.get(i + 1), sb);
                }
                sb.append('}');
                return;
            }
            case ARRAY:
            case SET:
            case PUSH: {
                sb.append('[');
                for (int i = 0; i < v.items.size(); i++) {
                    if (i > 0) sb.append(", ");
                    writeJson(v.items.get(i), sb);
                }
                sb.append(']');
                return;
            }
            case BULK: {
                String text = v.asText();
                sb.append(Json.quote(text == null ? Bytes.binaryPlaceholder(v.bytes) : text));
                return;
            }
            default:
                sb.append(Json.quote(v.asTextOrEmpty()));
        }
    }
}
