package com.dblite;

/** JSON/CSV text helpers shared by every source. */
public final class Json {
    private Json() {}

    /** Escapes a string for embedding in a JSON double-quoted literal. */
    public static String escape(String s) {
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }

    /** A quoted, escaped JSON string literal. */
    public static String quote(String s) {
        return "\"" + escape(s) + "\"";
    }

    public static boolean isJsonNumber(String value) {
        return value.matches("-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?");
    }

    /**
     * Mirrors the Lua CSV escaper: newlines become the literal "\n", and a field
     * containing a comma or quote is wrapped in quotes with quotes doubled.
     */
    public static String csvEscape(String val) {
        if (val == null) val = "";
        String s = val.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n");
        if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0) {
            s = "\"" + s.replace("\"", "\"\"") + "\"";
        }
        return s;
    }

    /**
     * True when `s` is a self-contained JSON object or array. Used to tag Redis
     * values as `json` so the editor knows a cell is structured before expanding
     * it. Deliberately strict: a bare number or quoted string is not a document.
     */
    public static boolean isJsonDocument(String s) {
        if (s == null) return false;
        String t = s.trim();
        if (t.length() < 2) return false;
        char first = t.charAt(0);
        char last  = t.charAt(t.length() - 1);
        if (!((first == '{' && last == '}') || (first == '[' && last == ']'))) return false;
        return wellFormed(t);
    }

    /**
     * Minimal structural validator — balanced braces/brackets outside of strings,
     * with backslash escapes honoured. Enough to avoid tagging a truncated or
     * accidental "{...}" value as JSON without pulling in a parser dependency.
     */
    private static boolean wellFormed(String t) {
        java.util.ArrayDeque<Character> stack = new java.util.ArrayDeque<>();
        boolean inString = false;
        boolean escaped  = false;
        for (int i = 0; i < t.length(); i++) {
            char c = t.charAt(i);
            if (inString) {
                if (escaped)            escaped = false;
                else if (c == '\\')     escaped = true;
                else if (c == '"')      inString = false;
                continue;
            }
            switch (c) {
                case '"': inString = true; break;
                case '{': stack.push('}'); break;
                case '[': stack.push(']'); break;
                case '}':
                case ']':
                    if (stack.isEmpty() || stack.pop() != c) return false;
                    break;
                default: break;
            }
        }
        return !inString && stack.isEmpty();
    }
}
