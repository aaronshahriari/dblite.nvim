package com.dblite;

/**
 * What a statement produced: either a result set or an update count.
 * `updateCount` of -1 means "executed, nothing to report" (DDL and the like).
 */
public final class Result {
    public final Rows rows;
    public final int  updateCount;

    private Result(Rows rows, int updateCount) {
        this.rows = rows;
        this.updateCount = updateCount;
    }

    public static Result of(Rows rows)        { return new Result(rows, -1); }
    public static Result updated(int count)   { return new Result(null, count); }

    public boolean hasRows() { return rows != null; }
}
