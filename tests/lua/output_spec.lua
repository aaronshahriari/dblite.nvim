-- The result window picks its renderer from the reply, not from a global
-- setting: a JSON document has to stop being a one-cell grid truncated at
-- `max_col_width`.

vim.o.columns = 200
vim.o.lines   = 50

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local dblite = require("dblite")
local config = require("dblite.config")
local output = require("dblite.output")
local json   = require("dblite.json")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

-- ── the JSON re-indenter keeps the server's bytes ───────────────────────────

eq(json.format('{"b":1,"a":2}'), '{\n  "b": 1,\n  "a": 2\n}', "key order survives")
eq(json.format('{"n":1.50}'), '{\n  "n": 1.50\n}', "number formatting survives")
eq(json.format('{"a":{},"b":[]}'), '{\n  "a": {},\n  "b": []\n}', "empty containers stay inline")
eq(json.format('{"s":"a,b:{c}"}'), '{\n  "s": "a,b:{c}"\n}', "punctuation inside strings is literal")
eq(json.format('{"s":"quote\\" here","t":2}'),
   '{\n  "s": "quote\\" here",\n  "t": 2\n}', "escaped quotes do not end the string")
eq(json.format('{"a":1}', 4), '{\n    "a": 1\n}', "indent width is honoured")
eq(json.is_document('{"a":1}'), true,  "object is a document")
eq(json.is_document('[1,2]'),   true,  "array is a document")
eq(json.is_document('"a"'),     false, "a bare string is not a document")
eq(json.is_document('{oops'),   false, "malformed input is not a document")

-- ── the command a statement names ───────────────────────────────────────────

eq(output.command("JSON.GET user:1 $"), "JSON.GET", "dotted module command is one token")
eq(output.command("# a comment\nHGETALL k"), "HGETALL", "comments are skipped")
eq(output.command("  \n\nget k"), "GET", "leading blank lines are skipped")
eq(output.command("-- sql comment\nselect 1 from dual"), "SELECT", "sql comments are skipped")
eq(output.command(nil), nil, "no query, no command")

-- ── detection ───────────────────────────────────────────────────────────────

local function result(columns, types, rows)
  return { columns = columns, column_types = types, rows = rows, elapsed = 0.01 }
end

local doc = result({ "result" }, { "json" }, { { result = '{"id":1,"tags":["a","b"]}' } })
eq(output.resolve(doc, { cfg = config.output }), "json", "a lone json cell renders as json")

local grid = result({ "field", "value" }, { "string", "string" },
  { { field = "a", value = "1" }, { field = "b", value = "2" } })
eq(output.resolve(grid, { cfg = config.output }), "grid", "two columns stay a grid")

local counted = result({ "result" }, { "integer" }, { { result = 42 } })
eq(output.resolve(counted, { cfg = config.output }), "grid", "a lone integer stays a grid")

local multiline = result({ "result" }, { "string" }, { { result = "line one\nline two" } })
eq(output.resolve(multiline, { cfg = config.output }), "text", "a multi-line cell renders as text")

-- ── precedence: forced beats per-command beats default beats detection ──────

local cfg = { mode = "auto", commands = { ["json.get"] = "text", INFO = "grid" } }
eq(output.resolve(doc, { cfg = cfg, query = "JSON.GET k $" }), "text",
  "a per-command pin matches case-insensitively and beats detection")
eq(output.resolve(doc, { cfg = cfg, query = "GET k" }), "json",
  "an unpinned command still falls through to detection")
eq(output.resolve(doc, { cfg = cfg, query = "JSON.GET k $", forced = "grid" }), "grid",
  "a forced mode beats the per-command pin")
eq(output.resolve(doc, { cfg = { mode = "grid" } }), "grid",
  "a configured default beats detection")
eq(output.resolve(doc, { cfg = { mode = "grid" }, forced = "auto" }), "grid",
  "forcing 'auto' does not override the configured default")

-- ── the rendered buffer ─────────────────────────────────────────────────────

local function dbout_lines()
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buftype == "nofile" and vim.api.nvim_buf_is_loaded(b) then buf = b end
  end
  return vim.api.nvim_buf_get_lines(assert(buf), 0, -1, false), buf
end

dblite.show_result(doc, { query = "JSON.GET user:1 $", conn = "spec" })
local lines, buf = dbout_lines()
eq(vim.bo[buf].filetype, "jsonc", "the json view uses a comment-tolerant dialect")
assert(lines[1]:match("^// "), "the status line is commented out: " .. lines[1])
assert(lines[1]:match("json, 7 lines"), "the status reports the document size: " .. lines[1])
eq(lines[3], "{", "the document starts after the blank line")
eq(lines[4], '  "id": 1,', "the document is indented")

-- The whole value is present: the grid would have cut it at max_col_width.
local body = table.concat(vim.list_slice(lines, 3), "\n")
eq(body, json.format('{"id":1,"tags":["a","b"]}'), "the document is rendered whole")

-- ── :DbliteOutput pins, and persists across the next result ─────────────────

dblite.set_output_mode("grid")
lines = dbout_lines()
assert(lines[3]:match("^result"), "forcing grid brings the table back: " .. lines[3])

dblite.show_result(doc, { query = "JSON.GET user:2 $", conn = "spec" })
lines = dbout_lines()
assert(lines[3]:match("^result"), "the pin outlives the query that set it: " .. lines[3])

dblite.set_output_mode("auto")
lines = dbout_lines()
assert(lines[1]:match("^// "), "auto hands the decision back to detection: " .. lines[1])

-- A tabular reply is unaffected by a json-capable window.
dblite.show_result(grid, { query = "HGETALL session:1", conn = "spec" })
lines, buf = dbout_lines()
eq(vim.bo[buf].filetype, "", "a grid drops the json dialect")
assert(lines[3]:match("^field"), "a two-column reply is still a table: " .. lines[3])

print("output_spec: ok")
