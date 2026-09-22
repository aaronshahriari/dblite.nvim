-- End-to-end spec for the headless `dblite.inline` API.
--
-- Registers a throwaway SQLite connection, so it must run against a scratch
-- data dir rather than your real connections.json:
--
--   XDG_DATA_HOME=$(mktemp -d) nvim -l tests/lua/inline_spec.lua

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

assert(vim.env.XDG_DATA_HOME and vim.env.XDG_DATA_HOME ~= "",
  "run with XDG_DATA_HOME set to a scratch dir — this spec writes connections.json")

local config      = require("dblite.config")
local connections = require("dblite.connections")
local binds       = require("dblite.binds")
local inline      = require("dblite.inline")

-- --- bind helpers (extracted from init.lua, shared with the run paths) ------

assert(vim.deep_equal(binds.parse_names("select * from t where id = :id and d > :since"),
  { "id", "since" }))
assert(vim.deep_equal(binds.parse_names("select col::text from t"), {}),
  ":: is a cast, not a bind")
assert(vim.deep_equal(binds.parse_names("select ':nope' from t -- :also"), {}),
  "literals and comments are not binds")
assert(binds.apply("where id = :id", { id = 7 }) == "where id = 7")
assert(binds.apply("where n = :n", { n = "o'neill" }) == "where n = 'o''neill'")
assert(binds.apply("where d > :d", { d = "~sysdate" }) == "where d > sysdate",
  "~ prefix passes raw SQL through")
assert(vim.deep_equal(binds.missing("where a = :a and b = :b", { a = 1 }), { "b" }))
assert(vim.deep_equal(binds.flatten({ env = { user = "bob" }, n = 1 }),
  { ["env.user"] = "bob", n = 1 }))

-- --- connection env --------------------------------------------------------

local sqlite_env = connections.env({ type = "sqlite", path = root .. "/README.md" })
assert(sqlite_env.DB_URL:match("^jdbc:sqlite:"))
assert(sqlite_env.DB_USER == nil, "sqlite has no credentials")

vim.env.DBLITE_SPEC_PW = "s3cret"
local ora_env = connections.env({
  type = "oracle", host = "h", port = 1521, service = "s",
  user = "scott", password = "$DBLITE_SPEC_PW",
})
assert(ora_env.DB_PASSWORD == "s3cret", "$VAR credentials are expanded")

local krb_env = connections.env({
  type = "sqlserver", host = "h", port = 1433, database = "d", auth = "kerberos",
})
assert(krb_env.DB_USER == nil, "kerberos takes credentials from the ticket cache")

-- --- validation (no connection or binary needed) ---------------------------

local function err_of(opts)
  local _, e = inline.run(opts)
  return e or ""
end

assert(err_of({ conn = "x" }):match("sql is required"))
assert(err_of({ sql = "  " , conn = "x" }):match("sql is required"))
assert(err_of({ sql = "select 1" }):match("conn is required"))

-- --- end-to-end ------------------------------------------------------------

if vim.fn.executable(config.binary) ~= 1 then
  print("inline_spec: bind/env/validation OK; skipped query run (no dblite binary)")
  return
end

local db_path = vim.fn.tempname() .. ".sqlite"
assert(io.open(db_path, "w")):close()

connections.add({ name = "spec_inline", type = "sqlite", path = db_path })
assert(err_of({ sql = "select 1", conn = "nope" }):match("no saved connection named 'nope'"))

local function run(opts)
  local res, e = inline.run(vim.tbl_extend("keep", opts, { conn = "spec_inline", sync = true }))
  assert(res, e)
  return res
end

local ddl = run({ sql = "create table creds (id integer, service text, note text)" })
assert(ddl.update_count ~= nil, "DDL reports an update count, not rows")

run({ sql = "insert into creds values (1, 'prod-aws', null)" })
local ins = run({ sql = "insert into creds values (2, 'staging', 'rotate me')" })
assert(ins.update_count == 1, "got " .. tostring(ins.update_count))

local res = run({ sql = "select id, service, note from creds order by id" })
assert(res.count == 2)
assert(res.conn == "spec_inline")
assert(vim.deep_equal(res.columns, { "id", "service", "note" }))
assert(res.rows[1].service == "prod-aws", "rows are keyed by column label")
assert(res.rows[2].note == "rotate me")
assert(res.rows[1].note == vim.NIL, "SQL NULL is vim.NIL by default")
assert(type(res.json) == "string" and res.json:match("prod%-aws"), "raw JSON is passed through")
assert(type(res.elapsed) == "number")

-- `values` is the same rows positionally, built on first access only
assert(rawget(res, "values") == nil, "values is lazy")
assert(vim.deep_equal(res.values[2], { 2, "staging", "rotate me" }))
assert(rawget(res, "values") ~= nil, "values is memoized")

local nils = run({ sql = "select note from creds where id = 1", null_as_nil = true })
assert(nils.rows[1].note == nil, "null_as_nil drops NULL keys")

-- binds
local bound = run({ sql = "select service from creds where id = :id", binds = { id = 2 } })
assert(bound.count == 1 and bound.rows[1].service == "staging")
assert(err_of({ sql = "select :a, :b", conn = "spec_inline", binds = { a = 1 }, sync = true })
  :match("missing bind params: b"))

-- max_rows caps the result
assert(run({ sql = "select * from creds", max_rows = 1 }).count == 1)

-- a bad statement surfaces the binary's stderr rather than throwing
local bad, bad_err = inline.run({ sql = "select * from nope", conn = "spec_inline", sync = true })
assert(bad == nil and bad_err:match("inline:"), "got " .. tostring(bad_err))

-- async form delivers on the main loop and returns a killable handle
local got
local handle = inline.run({ conn = "spec_inline", sql = "select count(*) c from creds" },
  function(e, r) got = { err = e, res = r } end)
assert(type(handle) == "table" and type(handle.kill) == "function", "async returns the job handle")
vim.wait(30000, function() return got ~= nil end)
assert(got, "async callback never fired")
assert(not got.err, got.err)
assert(got.res.rows[1].c == 2)

-- the API is exposed on the top-level module and left no UI behind
assert(require("dblite").inline == inline.run)
assert(#vim.api.nvim_list_bufs() == 1, "inline must not open a result buffer")

connections.delete(connections.get_by_name("spec_inline").id)
assert(os.remove(db_path))
print("inline_spec: OK")
