package com.dblite;

/**
 * A forward-only, source-agnostic result set. JDBC streams through this over a
 * live cursor; Redis serves it from an already-decoded reply. Keeping the
 * printer and the bulk file writer behind this interface is what lets a
 * non-SQL source reuse the whole output path.
 *
 * Column indexes are 1-based, matching JDBC.
 */
public interface Rows extends AutoCloseable {
    String[] columns();

    /** Per-column type label, shown by the editor's column-type toggle. */
    String[] columnTypes();

    /** Advances to the next row; false when exhausted. */
    boolean next() throws Exception;

    /** The cell as a JSON fragment — a quoted string, a bare number, or null. */
    String jsonValue(int col) throws Exception;

    /** The cell as plain unquoted text, for CSV output. */
    String csvValue(int col) throws Exception;

    @Override
    default void close() throws Exception {}
}
