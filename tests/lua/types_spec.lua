-- `config.types.<type>` overrides the top-level defaults for whichever
-- connection is active. Redis and a SQL database want different result
-- windows — one document reads well in a tall right-hand pane, a result grid
-- in a short wide one — and a single global setting cannot serve both.

vim.o.columns = 200
vim.o.lines   = 50

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

-- Placements persist to disk, and this spec both reads and writes them. Start
-- from an empty file — a `sqlite = "right"` left by a previous run would
-- outrank the config block under test, which is exactly the precedence the
-- spec asserts further down — and put the user's own state back at the end.
local ui_path = vim.fn.stdpath("data") .. "/dblite/ui.json"
local saved_ui
do
  local f = io.open(ui_path, "r")
  if f then saved_ui = f:read("*a"); f:close() end
end
os.remove(ui_path)

local dblite      = require("dblite")
local config      = require("dblite.config")
local connections = require("dblite.connections")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

config.binary = "/bin/false"   -- nothing here runs a query
config.split_dir = "below"     -- the generic default the per-type block overrides
config.types = {
  redis  = { split_dir = "right", filetype = "conf",
             output = { commands = { GET = "text" } } },
  sqlite = { split_dir = "below" },
}

for _, name in ipairs({ "spec_types_redis", "spec_types_sqlite" }) do
  local stale = connections.get_by_name(name)
  if stale then connections.delete(stale.id) end
end

local db_path = vim.fn.tempname() .. ".sqlite"
assert(io.open(db_path, "w")):close()
connections.add({ name = "spec_types_redis", type = "redis", host = "127.0.0.1", port = 6399 })
connections.add({ name = "spec_types_sqlite", type = "sqlite", path = db_path })

local doc = {
  columns = { "result" }, column_types = { "json" },
  rows = { { result = '{"id":1}' } }, elapsed = 0.01,
}
local grid = {
  columns = { "field", "value" }, column_types = { "string", "string" },
  rows = { { field = "a", value = "1" } }, elapsed = 0.01,
}

local function dbout_win()
  local wins = vim.api.nvim_list_wins()
  if #wins ~= 2 then return nil end
  local cur = vim.api.nvim_get_current_win()
  return wins[1] == cur and wins[2] or wins[1]
end

-- A left/right split sits at a non-zero column, an above/below split at a
-- non-zero row. Exactly one holds for two windows.
local function placement(win)
  local row, col = unpack(vim.api.nvim_win_get_position(win))
  if col > 0 then return "right" end
  if row > 0 then return "below" end
  return "unknown"
end

-- ── placement follows the active connection's type ──────────────────────────

vim.cmd("DbliteUseConn spec_types_redis")
dblite.show_result(doc, { query = "JSON.GET user:1 $", conn = "spec_types_redis" })
eq(placement(assert(dbout_win(), "dbout should be open")), "right",
  "a Redis result lands in the placement configured for redis")

dblite.toggle_dbout()  -- close, so the next connection re-opens it fresh
vim.cmd("DbliteUseConn spec_types_sqlite")
dblite.show_result(grid, { query = "select 1", conn = "spec_types_sqlite" })
eq(placement(assert(dbout_win(), "dbout should reopen")), "below",
  "a SQL result lands in the placement configured for sqlite")

-- ── :DbliteSplit is remembered per type, not globally ───────────────────────

dblite.set_split_dir("right")
eq(placement(assert(dbout_win())), "right", "moving dbout on the sqlite connection works")

dblite.toggle_dbout()
vim.cmd("DbliteUseConn spec_types_redis")
dblite.show_result(doc, { query = "JSON.GET user:1 $", conn = "spec_types_redis" })
eq(placement(assert(dbout_win())), "right", "the redis placement is unchanged by the sqlite move")

local ui = vim.json.decode(assert(io.open(vim.fn.stdpath("data") .. "/dblite/ui.json")):read("*a"))
eq(ui.split_dir.sqlite, "right", "the move was stored under the connection's type")
assert(ui.split_dir.redis == nil, "the other type was left alone")

-- ── other settings resolve per type too ─────────────────────────────────────

-- A per-type `output.commands` entry pins one command without restating the
-- top-level table.
dblite.show_result(doc, { query = "GET blob", conn = "spec_types_redis" })
local buf = vim.api.nvim_win_get_buf(assert(dbout_win()))
eq(vim.bo[buf].filetype, "conf", "text mode uses the per-type result filetype")
eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1], '{"id":1}',
  "the pinned command rendered as raw text, not re-indented JSON")

-- The same reply on a connection with no such pin goes back to detection.
dblite.toggle_dbout()
vim.cmd("DbliteUseConn spec_types_sqlite")
dblite.show_result(doc, { query = "GET blob", conn = "spec_types_sqlite" })
buf = vim.api.nvim_win_get_buf(assert(dbout_win()))
eq(vim.bo[buf].filetype, "jsonc", "the pin does not leak to another connection type")

for _, name in ipairs({ "spec_types_redis", "spec_types_sqlite" }) do
  local c = connections.get_by_name(name)
  if c then connections.delete(c.id) end
end
os.remove(db_path)

os.remove(ui_path)
if saved_ui then
  local f = assert(io.open(ui_path, "w"))
  f:write(saved_ui)
  f:close()
end

print("types_spec: ok")
