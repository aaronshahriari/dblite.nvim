-- Statement extraction. SQL is terminator-delimited; Redis is one command per
-- line, with no terminator at all — so the SQL heuristic (grow to the next
-- blank line or semicolon) would fold every following command into one.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local query = require("dblite.query")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

local function buffer(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- ── line mode: one command per line ─────────────────────────────────────────

local redis_lines = {
  "KEYS user:*",
  "HGETALL user:1042",
  "GET cfg:app",
}
local buf = buffer(redis_lines)

for line = 1, 3 do
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  local sr, _, er, _, text = query.at_cursor(buf, true)
  eq(text, redis_lines[line], "line mode returns only the cursor's line " .. line)
  eq(sr, line - 1, "start row for line " .. line)
  eq(er, line - 1, "end row for line " .. line)
end

-- Without line mode, the same buffer collapses into a single statement. This is
-- correct for SQL and is exactly what line mode exists to avoid.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local _, _, _, _, collapsed = query.at_cursor(buf)
eq(collapsed, table.concat(redis_lines, "\n"),
  "without line mode the SQL heuristic swallows every following command")

-- ── line mode over a range (visual selection) ───────────────────────────────

local sr, _, er, _, text = query.at_range(buf, 2, 3, true)
eq(text, "HGETALL user:1042\nGET cfg:app", "range in line mode is taken verbatim")
eq(sr, 1, "range start row")
eq(er, 2, "range end row")

-- A single-line range stays a single line.
_, _, _, _, text = query.at_range(buf, 2, 2, true)
eq(text, "HGETALL user:1042", "single-line range in line mode")

-- A reversed range is normalised, as in the SQL path.
_, _, _, _, text = query.at_range(buf, 3, 2, true)
eq(text, "HGETALL user:1042\nGET cfg:app", "reversed range is normalised")

-- Out-of-range edges clamp rather than erroring.
_, _, _, _, text = query.at_range(buf, 1, 99, true)
eq(text, table.concat(redis_lines, "\n"), "range clamps to the last line")

-- ── blank input ─────────────────────────────────────────────────────────────

local blank = buffer({ "", "   ", "" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
eq(query.at_cursor(blank, true), nil, "a blank line yields no statement in line mode")
eq(query.at_range(blank, 1, 3, true), nil, "an all-blank range yields no statement")

-- ── the SQL path is unchanged ───────────────────────────────────────────────

local sql = buffer({
  "select 1 from dual;",
  "",
  "select 2",
  "  from dual;",
})
vim.api.nvim_win_set_cursor(0, { 3, 0 })
local _, _, _, _, stmt = query.at_cursor(sql)
eq(stmt, "select 2\n  from dual;", "a SQL statement still spans its own lines")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
_, _, _, _, stmt = query.at_cursor(sql)
eq(stmt, "select 1 from dual;", "a semicolon still terminates a SQL statement")

print("query_spec: ok")
