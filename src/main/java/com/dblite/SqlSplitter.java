package com.dblite;

/**
 * Dialect-aware SQL script splitting. Extracted from App so that non-SQL
 * sources can supply their own notion of "a statement".
 */
final class SqlSplitter {
    private SqlSplitter() {}

    // Splits a script according to the dialect identified by its JDBC URL.
    //   - for Oracle, a line containing only "/" terminates the current statement
    //     (the canonical PL/SQL block terminator)
    //   - Oracle PL/SQL blocks and SQLite trigger bodies retain inner semicolons
    //   - string literals ('...' with '' escape), quoted identifiers ("..."),
    //     line comments (--) and block comments (/* */) are skipped so their
    //     contents never trigger a split
    static java.util.List<String> split(String sql, String url) {
        java.util.List<String> out = new java.util.ArrayList<>();
        StringBuilder cur = new StringBuilder();
        String lowerUrl = url.toLowerCase(java.util.Locale.ROOT);
        boolean oracle = lowerUrl.startsWith("jdbc:oracle:");
        boolean sqlite = lowerUrl.startsWith("jdbc:sqlite:");
        int n = sql.length();
        boolean inSingle = false, inDouble = false, inBacktick = false, inBracket = false;
        boolean inLine = false, inBlock = false;
        boolean lineBlank = true; // only whitespace seen on the current line so far
        int i = 0;
        while (i < n) {
            char c = sql.charAt(i);
            char nx = i + 1 < n ? sql.charAt(i + 1) : '\0';

            if (inLine) {
                cur.append(c);
                if (c == '\n') { inLine = false; lineBlank = true; }
                i++; continue;
            }
            if (inBlock) {
                cur.append(c);
                if (c == '*' && nx == '/') { cur.append(nx); i += 2; inBlock = false; continue; }
                i++; continue;
            }
            if (inSingle) {
                cur.append(c);
                if (c == '\'') {
                    if (nx == '\'') { cur.append(nx); i += 2; continue; } // '' escape
                    inSingle = false;
                }
                i++; continue;
            }
            if (inDouble) {
                cur.append(c);
                if (c == '"') {
                    if (nx == '"') { cur.append(nx); i += 2; continue; }
                    inDouble = false;
                }
                i++; continue;
            }
            if (inBacktick) {
                cur.append(c);
                if (c == '`') {
                    if (nx == '`') { cur.append(nx); i += 2; continue; }
                    inBacktick = false;
                }
                i++; continue;
            }
            if (inBracket) {
                cur.append(c);
                if (c == ']') inBracket = false;
                i++; continue;
            }

            if (c == '-' && nx == '-') { inLine = true; cur.append(c); i++; lineBlank = false; continue; }
            if (c == '/' && nx == '*') { inBlock = true; cur.append(c); i++; lineBlank = false; continue; }
            if (c == '\'') { inSingle = true; cur.append(c); i++; lineBlank = false; continue; }
            if (c == '"') { inDouble = true; cur.append(c); i++; lineBlank = false; continue; }
            if (sqlite && c == '`') { inBacktick = true; cur.append(c); i++; lineBlank = false; continue; }
            if (sqlite && c == '[') { inBracket = true; cur.append(c); i++; lineBlank = false; continue; }

            if (c == '\n') { cur.append(c); lineBlank = true; i++; continue; }
            if (c == '\r') { cur.append(c); i++; continue; }

            // lone "/" on its own line -> terminate current statement
            if (oracle && c == '/' && lineBlank) {
                int j = i + 1;
                boolean rest = true;
                while (j < n) {
                    char d = sql.charAt(j);
                    if (d == '\n') break;
                    if (!Character.isWhitespace(d)) { rest = false; break; }
                    j++;
                }
                if (rest) {
                    flush(out, cur);
                    i = (j < n && sql.charAt(j) == '\n') ? j + 1 : j;
                    lineBlank = true;
                    continue;
                }
            }

            if (c == ';') {
                boolean terminate = sqlite
                    ? !isSqliteTrigger(cur) || isSqliteTriggerComplete(cur)
                    : !isPlsqlBlock(cur);
                if (terminate) {
                    flush(out, cur);
                    i++; lineBlank = false; continue;
                }
            }

            cur.append(c);
            if (!Character.isWhitespace(c)) lineBlank = false;
            i++;
        }
        flush(out, cur);
        return out;
    }

    private static void flush(java.util.List<String> out, StringBuilder cur) {
        String s = cur.toString().trim();
        if (!s.isEmpty()) out.add(s);
        cur.setLength(0);
    }

    // Is the statement accumulated so far a PL/SQL block (where ";" is internal)?
    private static boolean isPlsqlBlock(CharSequence csq) {
        String s = csq.toString();
        int i = 0, n = s.length();
        while (i < n) { // skip leading whitespace and comments
            char c = s.charAt(i);
            if (Character.isWhitespace(c)) { i++; continue; }
            if (c == '-' && i + 1 < n && s.charAt(i + 1) == '-') {
                while (i < n && s.charAt(i) != '\n') i++;
                continue;
            }
            if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                i += 2;
                while (i + 1 < n && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/')) i++;
                i += 2;
                continue;
            }
            break;
        }
        String head = s.substring(Math.min(i, n)).toUpperCase();
        if (startsWithWord(head, "DECLARE") || startsWithWord(head, "BEGIN")) return true;
        if (startsWithWord(head, "CREATE")) {
            String r = head.replaceFirst(
                "^CREATE\\s+(OR\\s+REPLACE\\s+)?(EDITIONABLE\\s+|NONEDITIONABLE\\s+)?", "");
            for (String kw : new String[]{"PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE"}) {
                if (startsWithWord(r, kw)) return true;
            }
        }
        return false;
    }

    private static boolean isSqliteTrigger(CharSequence csq) {
        java.util.List<String> words = sqlWords(csq);
        if (words.isEmpty() || !"CREATE".equals(words.get(0))) return false;
        int i = 1;
        if (i < words.size() && ("TEMP".equals(words.get(i)) || "TEMPORARY".equals(words.get(i)))) i++;
        return i < words.size() && "TRIGGER".equals(words.get(i));
    }

    private static boolean isSqliteTriggerComplete(CharSequence csq) {
        java.util.List<String> words = sqlWords(csq);
        boolean inBody = false;
        int caseDepth = 0;
        String last = null;
        for (String word : words) {
            if (!inBody) {
                if ("BEGIN".equals(word)) inBody = true;
                continue;
            }
            if ("CASE".equals(word)) {
                caseDepth++;
            } else if ("END".equals(word)) {
                if (caseDepth > 0) caseDepth--;
                else last = "END";
            } else {
                last = word;
            }
        }
        return inBody && caseDepth == 0 && "END".equals(last);
    }

    private static java.util.List<String> sqlWords(CharSequence csq) {
        java.util.List<String> words = new java.util.ArrayList<>();
        int i = 0, n = csq.length();
        while (i < n) {
            char c = csq.charAt(i);
            char nx = i + 1 < n ? csq.charAt(i + 1) : '\0';
            if (c == '-' && nx == '-') {
                i += 2;
                while (i < n && csq.charAt(i) != '\n') i++;
            } else if (c == '/' && nx == '*') {
                i += 2;
                while (i + 1 < n && !(csq.charAt(i) == '*' && csq.charAt(i + 1) == '/')) i++;
                i = Math.min(i + 2, n);
            } else if (c == '\'' || c == '"' || c == '`') {
                char quote = c;
                i++;
                while (i < n) {
                    if (csq.charAt(i) == quote) {
                        if (i + 1 < n && csq.charAt(i + 1) == quote) i += 2;
                        else { i++; break; }
                    } else i++;
                }
            } else if (c == '[') {
                i++;
                while (i < n && csq.charAt(i++) != ']') { }
            } else if (Character.isLetter(c) || c == '_') {
                int start = i++;
                while (i < n && (Character.isLetterOrDigit(csq.charAt(i)) || csq.charAt(i) == '_')) i++;
                words.add(csq.subSequence(start, i).toString().toUpperCase(java.util.Locale.ROOT));
            } else {
                i++;
            }
        }
        return words;
    }

    private static boolean startsWithWord(String s, String w) {
        if (!s.startsWith(w)) return false;
        if (s.length() == w.length()) return true;
        char c = s.charAt(w.length());
        return !(Character.isLetterOrDigit(c) || c == '_');
    }
}
