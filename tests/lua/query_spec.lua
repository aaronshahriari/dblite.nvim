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

-- ── multiline commands in line mode ────────────────────────────────────────
--
-- Redis has no statement terminator, but a command still has to be breakable
-- across lines or a JSON.SET with a document argument is one unreadable line.
-- A command continues when a quote opened on the line is still open at its end,
-- or when the line ends with a backslash outside quotes.

local ml = {
  "KEYS demo:*",                       -- 1
  "JSON.SET doc:1 $ '{",               -- 2  quote left open
  '  "name": "widget",',               -- 3
  '  "qty": 2',                        -- 4
  "}'",                                -- 5  closes it
  "HSET user:1042 \\",                 -- 6  explicit continuation
  "  email a@example.com \\",          -- 7
  "  name Aaron",                      -- 8
  "",                                  -- 9
  "# prose ending in a backslash \\",  -- 10 must not continue
  "GET demo:cfg:app",                  -- 11
}

local function span(lnum)
  local f, l = query.logical_range(ml, lnum)
  return f .. ".." .. l
end

eq(span(1), "1..1", "a single-line command stands alone")
for _, l in ipairs({ 2, 3, 4, 5 }) do
  eq(span(l), "2..5", "an open quote joins lines 2-5 from line " .. l)
end
for _, l in ipairs({ 6, 7, 8 }) do
  eq(span(l), "6..8", "a trailing backslash joins lines 6-8 from line " .. l)
end
eq(span(9), "9..9", "a blank line is its own span")
eq(span(10), "10..10", "a backslash inside a comment does not continue")
eq(span(11), "11..11", "the command after a comment stands alone")

-- Blanks and comments are not commands; a continued command is still one.
eq(query.logical_count(ml), 4, "four commands across eleven lines")
eq(query.logical_count({ "GET a", "GET b" }), 2, "two single-line commands")
eq(query.logical_count({ "", "# only prose" }), 0, "no commands at all")
eq(query.logical_count({ "SET k '", "still open" }), 1,
  "an unterminated command still counts as one")

-- at_cursor in line mode returns the whole logical command.
local mlbuf = buffer(ml)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
local sr, _, er, _, text = query.at_cursor(mlbuf, true)
eq(sr, 1, "the span starts at the command's first line")
eq(er, 4, "and ends at its last")
eq(text, table.concat({ ml[2], ml[3], ml[4], ml[5] }, "\n"),
  "the whole multiline command is returned from its middle")

-- The joined text must be the command as meant, not the raw lines: a literal
-- continuation backslash would otherwise become an argument, so
-- `HSET k \` + `f v` would store a field named `\`.
local _, _, _, _, bs = query.at_cursor(buffer(ml), true)
vim.api.nvim_win_set_cursor(0, { 7, 0 })
local _, _, _, _, joined = query.at_cursor(mlbuf, true)
assert(not joined:find("\\", 1, true),
  "continuation backslashes must be dropped, got: " .. vim.inspect(joined))
eq(joined:gsub("%s+", " "), "HSET user:1042 email a@example.com name Aaron",
  "the backslash-continued command joins to the real argument list")

-- A trailing comment is removed too, so `run at cursor` matches what a
-- whole-buffer script run sends.
local cbuf = buffer({ "GET key # why we do this" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local _, _, _, _, ctext = query.at_cursor(cbuf, true)
eq(ctext, "GET key ", "a trailing comment is stripped")

-- But a `#` inside a quoted value is data.
local qbuf = buffer({ 'SET colour "#ff0000"' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local _, _, _, _, qtext = query.at_cursor(qbuf, true)
eq(qtext, 'SET colour "#ff0000"', "a quoted # survives")

-- And a `#` on a continuation line inside an open quote is data as well.
local jbuf = buffer({ "SET doc '{", '  "c": "#ff0000"', "}'" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local _, _, _, _, jtext = query.at_cursor(jbuf, true)
eq(jtext, "SET doc '{\n  \"c\": \"#ff0000\"\n}'",
  "a # inside a multiline quoted value is not a comment")

-- A range touching the middle of a command grows to cover all of it.
local _, _, _, _, rtext = query.at_range(mlbuf, 3, 4, true)
eq(rtext, table.concat({ ml[2], ml[3], ml[4], ml[5] }, "\n"),
  "a range inside a command grows to the whole command")

-- A range spanning two commands covers both, whole — with continuation
-- backslashes dropped, same as any other joined command.
local _, _, _, _, two = query.at_range(mlbuf, 4, 7, true)
eq(two, query.logical_text(ml, 2, 8),
  "a range across two commands covers both entirely")
assert(two:find("JSON.SET", 1, true) and two:find("HSET", 1, true),
  "both commands are present")
assert(not two:find("\\", 1, true), "and neither keeps its continuation backslash")

-- A `#` inside a quoted value is data, so the command does not end there.
eq(query.logical_count({ 'SET colour "#ff0000"' }), 1, "a quoted # is not a comment")
