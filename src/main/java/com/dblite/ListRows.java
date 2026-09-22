package com.dblite;

import java.util.ArrayList;
import java.util.List;

/**
 * An in-memory {@link Rows}. Redis replies arrive fully materialised, so there
 * is no cursor to stream; this adapts them to the shared output path.
 */
public final class ListRows implements Rows {

    /** One cell, carrying both its plain text and its JSON encoding. */
    public static final class Cell {
        final String text;
        final String json;

        private Cell(String text, String json) {
            this.text = text;
            this.json = json;
        }

        /** A text cell; emitted as a quoted, escaped JSON string. */
        public static Cell of(String s) {
            if (s == null) return nil();
            return new Cell(s, Json.quote(s));
        }

        /** A numeric cell; emitted bare so it stays a JSON number. */
        public static Cell of(long v) {
            String s = Long.toString(v);
            return new Cell(s, s);
        }

        /** A cell whose text is already valid JSON and should not be re-quoted. */
        public static Cell number(String s) {
            return Json.isJsonNumber(s) ? new Cell(s, s) : of(s);
        }

        public static Cell bool(boolean v) {
            return new Cell(v ? "true" : "false", v ? "true" : "false");
        }

        /** Reuses an already-rendered pair, e.g. when re-wrapping another Rows. */
        public static Cell preformatted(String text, String json) {
            return new Cell(text == null ? "" : text, json == null ? "null" : json);
        }

        public static Cell nil() {
            return new Cell("", "null");
        }
    }

    private final String[] columns;
    private final String[] types;
    private final List<Cell[]> rows;
    private int cursor = -1;

    public ListRows(String[] columns, String[] types, List<Cell[]> rows) {
        this.columns = columns;
        this.types   = types;
        this.rows    = rows;
    }

    public static ListRows single(String column, String type, Cell value) {
        List<Cell[]> rows = new ArrayList<>(1);
        rows.add(new Cell[] { value });
        return new ListRows(new String[] { column }, new String[] { type }, rows);
    }

    public static ListRows empty(String[] columns, String[] types) {
        return new ListRows(columns, types, new ArrayList<>());
    }

    public int size() { return rows.size(); }

    @Override public String[] columns()     { return columns; }
    @Override public String[] columnTypes() { return types; }

    @Override
    public boolean next() {
        if (cursor + 1 >= rows.size()) return false;
        cursor++;
        return true;
    }

    @Override
    public String jsonValue(int col) {
        return cell(col).json;
    }

    @Override
    public String csvValue(int col) {
        return cell(col).text;
    }

    private Cell cell(int col) {
        Cell[] row = rows.get(cursor);
        return col <= row.length ? row[col - 1] : Cell.nil();
    }
}
