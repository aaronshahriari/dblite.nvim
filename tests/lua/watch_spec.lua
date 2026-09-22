-- Spec for the watch condition/spec parsers.
--
-- Pure parsing and condition evaluation — no database, no timers, no UI:
--
--   nvim -l tests/lua/watch_spec.lua

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local watch = require("dblite.watch")

-- --- durations -------------------------------------------------------------

assert(watch.parse_duration("30s") == 30)
assert(watch.parse_duration("2m")  == 120)
assert(watch.parse_duration("1h")  == 3600)
assert(watch.parse_duration("90")  == 90, "bare number is seconds")
assert(watch.parse_duration("1.5m") == 90)
assert(watch.parse_duration("0s") == nil, "zero is rejected")
assert(watch.parse_duration("banana") == nil)
assert(watch.parse_duration("") == nil)

assert(watch.fmt_duration(45)   == "45s")
assert(watch.fmt_duration(120)  == "2m")
assert(watch.fmt_duration(90)   == "1m30s")
assert(watch.fmt_duration(3600) == "1h")
assert(watch.fmt_duration(5400) == "1h30m")

-- --- spec strings ----------------------------------------------------------

local s = assert(watch.parse_spec("30s x50"))
assert(s.every == 30 and s.max == 50, "bare duration + xN shorthand")

s = assert(watch.parse_spec("every=2m max=10"))
assert(s.every == 120 and s.max == 10)

s = assert(watch.parse_spec("1m for=1h"))
assert(s.every == 60 and s.max == 60, "for= converts a budget into a tick cap")

s = assert(watch.parse_spec("times=7"))
assert(s.max == 7 and s.every == nil, "interval falls back to config later")

s = assert(watch.parse_spec("20s until=rows>5"))
assert(s.every == 20 and s.cond.spec == "rows>5")

assert(watch.parse_spec("every=nope") == nil, "bad duration rejected")
assert(watch.parse_spec("bogus=1") == nil, "unknown key rejected")
assert(watch.parse_spec("until=???") == nil, "bad condition rejected")

-- --- conditions ------------------------------------------------------------

local function result(columns, rows, json)
  return { columns = columns, rows = rows, count = #rows, json = json or vim.json.encode(rows) }
end

-- changed (the default)
local c = assert(watch.parse_condition(""))
assert(c.spec == "changed", "empty spec defaults to changed")
local w = {}
local matched = c.eval(w, result({ "N" }, { { N = 1 } }))
assert(not matched, "first tick only establishes the baseline")
assert(not c.eval(w, result({ "N" }, { { N = 1 } })), "identical result does not match")
assert(c.eval(w, result({ "N" }, { { N = 2 } })), "different result matches")

-- never
c = assert(watch.parse_condition("never"))
assert(not c.eval({}, result({ "N" }, { { N = 1 } })))

-- row counts
local rows3 = result({ "N" }, { { N = 1 }, { N = 2 }, { N = 3 } })
assert(assert(watch.parse_condition("rows>2")).eval({}, rows3))
assert(not assert(watch.parse_condition("rows>3")).eval({}, rows3))
assert(assert(watch.parse_condition("rows>=3")).eval({}, rows3))
assert(assert(watch.parse_condition("rows=3")).eval({}, rows3))
assert(assert(watch.parse_condition("rows!=4")).eval({}, rows3))
assert(assert(watch.parse_condition("rows<5")).eval({}, rows3))
assert(not assert(watch.parse_condition("rows=0")).eval({}, rows3))
assert(assert(watch.parse_condition("rows = 3")).eval({}, rows3), "spaces around the operator are fine")

-- column equality, case-insensitive column lookup
local people = result({ "NAME", "STATUS" }, {
  { NAME = "beth",  STATUS = "PENDING" },
  { NAME = "Aaron", STATUS = "DONE"    },
})
local hit, detail = assert(watch.parse_condition("NAME=Aaron")).eval({}, people)
assert(hit and detail:match("row 2"), "reports which row matched: " .. tostring(detail))
assert(assert(watch.parse_condition("name=Aaron")).eval({}, people), "column lookup is case-insensitive")
assert(not assert(watch.parse_condition("NAME=aaron")).eval({}, people), "values are case-sensitive")
assert(assert(watch.parse_condition("NAME~aaron")).eval({}, people), "~ is a case-insensitive substring")
assert(assert(watch.parse_condition("STATUS!=PENDING")).eval({}, people), "any row that is not PENDING")

-- a column the result does not have warns rather than silently never matching
local _, _, warn = assert(watch.parse_condition("MISSING=1")).eval({}, people)
assert(warn and warn:match("no column"), "missing column is reported: " .. tostring(warn))

-- NULL cells are skipped, not stringified
local nulls = result({ "V" }, { { V = vim.NIL }, { V = "x" } })
assert(assert(watch.parse_condition("V=x")).eval({}, nulls))
assert(not assert(watch.parse_condition("V=nil")).eval({}, nulls), "NULL never matches a literal")

-- numeric cells compare as strings, which is what the display shows
local nums = result({ "ID" }, { { ID = 42 } })
assert(assert(watch.parse_condition("ID=42")).eval({}, nums))

assert(watch.parse_condition("!!!") == nil, "garbage is rejected up front")

-- --- the settings popup ----------------------------------------------------

local function field_line(buf, key)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match("^%s*" .. key .. "%s") then return i end
  end
end

local function set_field(buf, key, val)
  local ln = assert(field_line(buf, key), "no field line for " .. key)
  vim.api.nvim_buf_set_lines(buf, ln - 1, ln, false, { string.format("  %-7s %s", key, val) })
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- The preview contains `max (id)`, which must not be mistaken for the max field.
local captured, confirmed = nil, false
watch.prompt({ label = "orders.sql:12", sql = "select max (id) from orders" },
  function(spec) confirmed = true; captured = spec end)
local pbuf = vim.api.nvim_win_get_buf(0)
set_field(pbuf, "every",  "2m")
set_field(pbuf, "until",  "STATUS=DONE")
set_field(pbuf, "max",    "unlimited")
set_field(pbuf, "errors", "5")
press("<CR>")

assert(confirmed and captured, "<CR> confirms the popup")
assert(captured.every == 120, "every: " .. tostring(captured.every))
assert(captured.max == 0, "'unlimited' means no tick cap: " .. tostring(captured.max))
assert(captured.stop_after_errors == 5)
assert(captured.cond.describe:match("STATUS"), "condition parsed: " .. captured.cond.describe)

-- A bad value leaves the popup open rather than starting a broken watch.
local closed = false
watch.prompt({ label = "x", sql = "select 1" }, function() closed = true end)
local pbuf2 = vim.api.nvim_win_get_buf(0)
set_field(pbuf2, "every", "banana")
press("<CR>")
assert(not closed, "invalid duration keeps the popup open")

-- q cancels, handing back no spec.
local cancelled_spec, saw_cancel = "unset", false
set_field(pbuf2, "every", "30s")
press("q")
assert(closed, "q closes the popup")

watch.prompt({ label = "y", sql = "select 1" }, function(spec)
  saw_cancel = true; cancelled_spec = spec
end)
press("<Esc>")
assert(saw_cancel and cancelled_spec == nil, "<Esc> cancels with a nil spec")

-- --- end-to-end ------------------------------------------------------------
--
-- Drives real watches against a scratch SQLite database. Needs the native
-- binary and a throwaway data dir, since registering a connection writes
-- connections.json:
--
--   XDG_DATA_HOME=$(mktemp -d) nvim -l tests/lua/watch_spec.lua

local config = require("dblite.config")

if vim.fn.executable(config.binary) ~= 1 then
  print("watch_spec: parsers OK; skipped live watches (no dblite binary)")
  return
end
if not (vim.env.XDG_DATA_HOME and vim.env.XDG_DATA_HOME ~= "") then
  print("watch_spec: parsers OK; skipped live watches (set XDG_DATA_HOME to a scratch dir)")
  return
end

local connections = require("dblite.connections")
local inline      = require("dblite.inline")

local db_path = vim.fn.tempname() .. ".sqlite"
assert(io.open(db_path, "w")):close()
-- Drop any entry a previous (possibly aborted) run left behind, so the spec is
-- re-runnable rather than passing exactly once.
local stale = connections.get_by_name("spec_watch")
if stale then connections.delete(stale.id) end
connections.add({ name = "spec_watch", type = "sqlite", path = db_path })

local function sql(stmt)
  local res, e = inline.run({ conn = "spec_watch", sql = stmt, sync = true })
  assert(res, e)
  return res
end

sql("create table arrivals (id integer, who text)")
sql("insert into arrivals values (1, 'beth')")

-- Wait for a watch to leave the running state, pumping the event loop.
local function settle(id, timeout_ms)
  local ok = vim.wait(timeout_ms or 15000, function()
    local w = watch.get(id)
    return w ~= nil and w.status ~= "running"
  end, 50)
  assert(ok, "watch did not finish within the timeout")
  return watch.get(id)
end

-- 1. A column condition matches once the row it is waiting for lands.
local id = assert(watch.start({
  conn = "spec_watch",
  sql  = "select id, who from arrivals order by id",
  every = 1,
  max = 10,
  cond = assert(watch.parse_condition("who=aaron")),
  label = "arrivals",
}))
assert(watch.get(id).status == "running")

-- The row shows up only after the watch is already polling.
vim.wait(1200, function() return false end, 50)
sql("insert into arrivals values (2, 'aaron')")

local w = settle(id)
assert(w.status == "matched", "expected matched, got " .. w.status .. " / " .. tostring(w.detail))
assert(w.detail:match("aaron"), "match detail names the value: " .. tostring(w.detail))
assert(w.tick >= 2, "took at least two ticks")
assert(w.last_result.count == 2, "latest result is kept for the panel")
watch.remove(id)

-- 2. rows>N against a growing table.
id = assert(watch.start({
  conn = "spec_watch", sql = "select id from arrivals", every = 1, max = 10,
  cond = assert(watch.parse_condition("rows>2")), label = "count",
}))
vim.wait(1200, function() return false end, 50)
sql("insert into arrivals values (3, 'cass')")
w = settle(id)
assert(w.status == "matched", "expected matched, got " .. w.status)
watch.remove(id)

-- 3. A watch that never matches stops at its tick cap.
id = assert(watch.start({
  conn = "spec_watch", sql = "select 1 as x", every = 1, max = 2,
  cond = assert(watch.parse_condition("never")), label = "capped",
}))
w = settle(id)
assert(w.status == "done", "expected done, got " .. w.status)
assert(w.tick == 2, "ran exactly the cap: " .. w.tick)
watch.remove(id)

-- 4. `changed` does not fire on a stable result.
id = assert(watch.start({
  conn = "spec_watch", sql = "select 42 as x", every = 1, max = 3,
  cond = assert(watch.parse_condition("changed")), label = "stable",
}))
w = settle(id)
assert(w.status == "done", "stable result never 'changes': got " .. w.status)
watch.remove(id)

-- 5. Repeated failures give up instead of hammering the database.
id = assert(watch.start({
  conn = "spec_watch", sql = "select * from no_such_table", every = 1, max = 20,
  stop_after_errors = 2, label = "broken",
}))
w = settle(id)
assert(w.status == "error", "expected error, got " .. w.status)
assert(w.tick == 2, "stopped after 2 failed ticks, ran " .. w.tick)
-- JVM warnings on stderr must not drown the real message in a notification.
local brief = watch.brief_error(w.last_err)
assert(brief:match("no such table"), "brief error keeps the cause: " .. brief)
assert(not brief:match("WARNING"), "brief error drops JVM noise: " .. brief)
assert(not brief:match("\n"), "brief error is one line")
watch.remove(id)

-- 6. The registry empties out and the concurrency cap is enforced.
assert(#watch.list() == 0, "removed watches leave the registry")
config.watch.max_active = 1
local a = assert(watch.start({
  conn = "spec_watch", sql = "select 1 as x", every = 30, max = 0,
  cond = assert(watch.parse_condition("never")), label = "first",
}))
local b, cap_err = watch.start({
  conn = "spec_watch", sql = "select 1 as x", every = 30, max = 0,
  cond = assert(watch.parse_condition("never")), label = "second",
})
assert(b == nil and cap_err:match("max_active"), "second watch refused: " .. tostring(cap_err))
watch.stop(a)
assert(watch.get(a).status == "stopped")
watch.remove(a)

assert(not watch.has_running(), "nothing left polling")
os.remove(db_path)

print("watch_spec: all assertions passed")

-- Leave no trace in the user's saved connections.
local added = connections.get_by_name("spec_watch")
if added then connections.delete(added.id) end
