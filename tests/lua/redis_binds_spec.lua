-- Redis keys are colon-namespaced (`user:1042`, `queue:jobs`, `session:a83f`),
-- which is exactly dblite's SQL bind-parameter syntax. Running a Redis command
-- must not mistake half a key name for a missing bind parameter.

vim.o.columns = 160
vim.o.lines   = 40

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local binds  = require("dblite.binds")
local dblite = require("dblite")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

-- The collision is real: the bind parser does see these as parameters, which is
-- correct for SQL and wrong for Redis. This pins the behaviour it is guarding.
local names = binds.parse_names("GET events:jsonl")
eq(names[1], "jsonl", "SQL bind parser treats a Redis key suffix as a bind")

-- A numeric suffix happens to dodge the pattern (`:name` must start with a
-- letter), but any word-shaped namespace collides.
eq(#binds.parse_names("KEYS user:263842-madfk623-2324"), 0,
  "a digit-led key suffix is not mistaken for a bind")
eq(binds.parse_names("KEYS session:active")[1], "active",
  "a word-shaped key suffix is mistaken for a bind")
eq(binds.parse_names("HGETALL queue:jobs")[1], "jobs",
  "a nested key namespace is mistaken for a bind")

-- Run a Redis command whose keys are full of colons. The binary is pointed at
-- a command that always fails, so the run ends immediately; what matters is
-- that dblite got as far as running it instead of stopping to prompt for binds.
local binds_path = binds.file_path()
os.remove(binds_path)

require("dblite.config").binary = "/bin/false"
local connections = require("dblite.connections")
local stale = connections.get_by_name("spec_redis_binds")
if stale then connections.delete(stale.id) end
connections.add({ name = "spec_redis_binds", type = "redis", host = "127.0.0.1", port = 6399 })
vim.cmd("DbliteUseConn spec_redis_binds")

local buf = vim.api.nvim_create_buf(true, false)
-- Word-shaped namespaces on both lines: each suffix is a bind candidate.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "HGETALL queue:jobs",
})
vim.api.nvim_set_current_buf(buf)
dblite.execute()
vim.wait(3000, function() return false end, 50)

eq(vim.fn.filereadable(binds_path), 0,
  "a Redis command must not trigger the missing-binds prompt")

-- The same guard has to hold on every path that resolves binds, not just the
-- run path: watch and bulk export each parse them separately.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
dblite.watch("every=1s max=1")
vim.wait(2500, function() return false end, 50)
eq(vim.fn.filereadable(binds_path), 0,
  "watching a Redis command must not trigger the missing-binds prompt")
pcall(vim.cmd, "DbliteWatchStop")

dblite.run_async("csv", vim.fn.tempname() .. ".csv")
vim.wait(2500, function() return false end, 50)
eq(vim.fn.filereadable(binds_path), 0,
  "bulk-exporting a Redis command must not trigger the missing-binds prompt")

-- The inline API resolves binds against its own connection, so it needs the
-- same scoping.
local inline = require("dblite.inline")
local _, ierr = inline.run({ conn = "spec_redis_binds", sql = "HGETALL queue:jobs", sync = true })
assert(not (ierr or ""):match("missing bind"),
  "inline must not report Redis key namespaces as missing binds, got: " .. tostring(ierr))

-- The same query on a SQL connection still goes through bind handling.
local db_path = vim.fn.tempname() .. ".sqlite"
assert(io.open(db_path, "w")):close()
stale = connections.get_by_name("spec_sql_binds")
if stale then connections.delete(stale.id) end
connections.add({ name = "spec_sql_binds", type = "sqlite", path = db_path })
vim.cmd("DbliteUseConn spec_sql_binds")

buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select * from t where id = :wanted" })
vim.api.nvim_set_current_buf(buf)
dblite.execute()
vim.wait(3000, function() return vim.fn.filereadable(binds_path) == 1 end, 50)

eq(vim.fn.filereadable(binds_path), 1,
  "a SQL query with a bind still prompts for the missing parameter")

os.remove(binds_path)
for _, n in ipairs({ "spec_redis_binds", "spec_sql_binds" }) do
  local c = connections.get_by_name(n)
  if c then connections.delete(c.id) end
end

print("redis_binds_spec: ok")
