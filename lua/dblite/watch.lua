-- Repeating queries ("watches").
--
-- A watch re-runs one statement on a fixed interval until something you are
-- waiting for happens: a row count crosses a threshold, a value shows up in a
-- column, or the result simply changes. It is the "stop tapping <CR> to see if
-- the row landed yet" feature.
--
-- Watches are built on `dblite.inline`, so a tick touches no UI state: no
-- result buffer, no spinner, no query history, and the active connection is
-- left alone. The connection name and the fully bind-substituted SQL are frozen
-- when the watch starts, so switching connections or editing dblite.binds.json
-- mid-flight never changes what is being polled.
--
-- Ticks are chained, not intervalled: the next run is scheduled from the
-- previous one's completion callback. A query that outlives its interval delays
-- the next tick instead of stacking a second one on top of it.
--
-- Watches are session-local and never persisted. A killed Neovim leaves no
-- ghost watch behind.

local config = require("dblite.config")
local inline = require("dblite.inline")

local M = {}

local watches = {}  -- live registry for this Neovim instance

local pid        = vim.fn.getpid()
local id_counter = 0
local function new_id()
  id_counter = id_counter + 1
  return string.format("w-%d-%d-%d", os.time(), pid, id_counter)
end

local function cfg()
  return config.watch or {}
end

-- --- Durations ------------------------------------------------------------

-- "30s" | "2m" | "1h" | "90" (bare = seconds) → seconds, or nil + error.
function M.parse_duration(s)
  s = tostring(s or ""):gsub("%s+", ""):lower()
  if s == "" then return nil, "empty duration" end
  local n, unit = s:match("^(%d+%.?%d*)([smh]?)$")
  if not n then return nil, "bad duration '" .. s .. "' (try 30s, 2m, 1h)" end
  local mult = ({ s = 1, m = 60, h = 3600 })[unit ~= "" and unit or "s"]
  local secs = tonumber(n) * mult
  if secs <= 0 then return nil, "duration must be > 0" end
  return secs
end

local function fmt_duration(secs)
  secs = math.max(0, math.floor(secs or 0))
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then
    local m, s = math.floor(secs / 60), secs % 60
    return s == 0 and (m .. "m") or string.format("%dm%ds", m, s)
  end
  local h, m = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
  return m == 0 and (h .. "h") or string.format("%dh%dm", h, m)
end
M.fmt_duration = fmt_duration

-- --- Conditions -----------------------------------------------------------
--
-- The thing you are waiting for, expressed in the watch rather than buried in
-- the SQL. Supported specs:
--
--   changed          result differs from the first tick          (default)
--   never            never match; just run to the tick cap
--   rows>5           row-count comparison: > >= < <= = != (== and <> too)
--   STATUS=DONE      any row whose STATUS column equals DONE
--   NAME~aaron       any row whose NAME column contains "aaron" (case-insensitive)
--   STATUS!=PENDING  any row whose STATUS column is not PENDING
--
-- Column names are matched case-insensitively, which matters for databases that
-- hand back upper-case labels.

local CMP = {
  [">"]  = function(a, b) return a >  b end,
  [">="] = function(a, b) return a >= b end,
  ["<"]  = function(a, b) return a <  b end,
  ["<="] = function(a, b) return a <= b end,
  ["="]  = function(a, b) return a == b end,
  ["=="] = function(a, b) return a == b end,
  ["!="] = function(a, b) return a ~= b end,
  ["<>"] = function(a, b) return a ~= b end,
}

-- Row values arrive as strings, numbers, or vim.NIL for SQL NULL.
local function cell_string(v)
  if v == nil or v == vim.NIL then return nil end
  return tostring(v)
end

-- Resolve a column label case-insensitively; returns the real key or nil.
local function find_column(columns, want)
  local lower = want:lower()
  for _, c in ipairs(columns or {}) do
    if tostring(c):lower() == lower then return c end
  end
  return nil
end

-- Parse a condition spec into { describe = <string>, eval = function(w, res) }.
-- eval returns matched (boolean), detail (string|nil).
function M.parse_condition(spec)
  spec = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if spec == "" then spec = "changed" end
  local lowered = spec:lower()

  if lowered == "changed" or lowered == "change" then
    return {
      spec = "changed", describe = "result changes",
      eval = function(w, res)
        local hash = vim.fn.sha256(res.json or "")
        if w.baseline == nil then
          w.baseline = hash
          return false, "baseline · " .. #(res.rows or {}) .. " rows"
        end
        if hash ~= w.baseline then
          return true, "result changed"
        end
        return false, nil
      end,
    }
  end

  if lowered == "never" or lowered == "none" then
    return { spec = "never", describe = "never (run to cap)", eval = function() return false, nil end }
  end

  -- rows<op><number>
  local op, num = lowered:match("^rows%s*([<>=!]=?)%s*(%d+)$")
  if not op then op, num = lowered:match("^rows%s*(<>)%s*(%d+)$") end
  if op and CMP[op] then
    local want = tonumber(num)
    return {
      spec = "rows" .. op .. num, describe = "rows " .. op .. " " .. num,
      eval = function(_, res)
        local n = #(res.rows or {})
        if CMP[op](n, want) then return true, n .. " rows" end
        return false, nil
      end,
    }
  end

  -- <column><op><value>
  local col, cop, val = spec:match("^([%w_%.]+)%s*([~!<>=]=?)%s*(.*)$")
  if col and cop and val ~= "" then
    local contains = cop == "~"
    local cmp = CMP[cop]
    if contains or cmp then
      local want = contains and val:lower() or val
      return {
        spec = col .. cop .. val,
        describe = col .. " " .. cop .. " " .. val,
        eval = function(_, res)
          local key = find_column(res.columns, col)
          if not key then
            return false, nil, "no column '" .. col .. "' in result"
          end
          for i, row in ipairs(res.rows or {}) do
            local cv = cell_string(row[key])
            if cv ~= nil then
              local hit
              if contains then hit = cv:lower():find(want, 1, true) ~= nil
              else               hit = cmp(cv, want) end
              if hit then return true, key .. "=" .. cv .. " (row " .. i .. ")" end
            end
          end
          return false, nil
        end,
      }
    end
  end

  return nil, "bad condition '" .. spec .. "' (try: changed, rows>5, STATUS=DONE, NAME~aaron)"
end

-- --- Spec strings ---------------------------------------------------------
--
-- One line of `key=value` pairs, plus two shorthands so the common case stays
-- short: a bare duration sets the interval, and `x50` sets the tick cap.
--
--   30s x50                      every 30s, at most 50 ticks, stop on change
--   every=2m until=rows>5        every 2m, stop once more than 5 rows come back
--   1m for=1h until=STATUS=DONE  every 1m for an hour, stop when STATUS is DONE
--
-- Returns { every, max, cond, errors } or nil + error.
function M.parse_spec(str)
  local out = {}
  local for_secs

  for token in tostring(str or ""):gmatch("%S+") do
    local key, val = token:match("^([%w_]+)=(.*)$")
    if key then
      key = key:lower()
      if key == "every" or key == "interval" then
        local secs, err = M.parse_duration(val)
        if not secs then return nil, err end
        out.every = secs
      elseif key == "max" or key == "times" or key == "count" then
        out.max = tonumber(val) or 0
      elseif key == "for" then
        local secs, err = M.parse_duration(val)
        if not secs then return nil, err end
        for_secs = secs
      elseif key == "until" or key == "if" or key == "cond" then
        local cond, err = M.parse_condition(val)
        if not cond then return nil, err end
        out.cond = cond
      elseif key == "errors" then
        out.errors = tonumber(val) or 0
      else
        return nil, "unknown option '" .. key .. "'"
      end
    elseif token:match("^[xX]%d+$") then
      out.max = tonumber(token:sub(2))
    elseif token:match("^%d+[xX]$") then
      out.max = tonumber(token:sub(1, -2))
    else
      local secs = M.parse_duration(token)
      if not secs then
        return nil, "don't understand '" .. token .. "'"
      end
      out.every = secs
    end
  end

  -- `for=` is sugar: convert a wall-clock budget into a tick cap.
  if for_secs then
    local every = out.every or M.parse_duration(cfg().default_interval or "30s") or 30
    out.max = math.max(1, math.floor(for_secs / every))
  end

  return out
end

-- --- Registry -------------------------------------------------------------

function M.get(id)
  for _, w in ipairs(watches) do
    if w.id == id then return w end
  end
end

-- Live watches, newest first.
function M.list()
  local copy = {}
  for i, w in ipairs(watches) do copy[i] = w end
  table.sort(copy, function(a, b)
    if (a.started_at or 0) ~= (b.started_at or 0) then
      return (a.started_at or 0) > (b.started_at or 0)
    end
    return a.id > b.id
  end)
  return copy
end

function M.active()
  return vim.tbl_filter(function(w) return w.status == "running" end, watches)
end

function M.has_running()
  return #M.active() > 0
end

local function refresh_panel()
  local ok, jobs = pcall(require, "dblite.jobs")
  if ok then jobs.refresh() end
end

local function notify(msg, level)
  if cfg().notify == false then return end
  vim.notify("dblite: " .. msg, level or vim.log.levels.INFO)
end

-- The binary writes JVM warnings to stderr ahead of the real message, which is
-- fine in the result buffer but drowns a notification. Keep the last meaningful
-- line for display; the full text stays on the watch for the hover view.
function M.brief_error(err)
  local best
  for line in tostring(err or ""):gmatch("[^\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= ""
      and not trimmed:match("^WARNING:")
      and not trimmed:match("^inline:%s*WARNING:") then
      best = trimmed
    end
  end
  return best or tostring(err or "?")
end

-- --- The loop -------------------------------------------------------------

local function stop_timer(w)
  if w.timer then
    pcall(function() w.timer:stop(); w.timer:close() end)
    w.timer = nil
  end
end

local function terminate(w, status, detail)
  if w.status ~= "running" then return end
  w.status      = status
  w.detail      = detail
  w.finished_at = os.time()
  w.next_at     = nil
  stop_timer(w)
  if w.handle then pcall(function() w.handle:kill(15) end) end
  w.handle = nil

  if status == "matched" then
    notify(string.format("watch matched — %s · %s", w.label, detail or w.cond.describe))
  elseif status == "error" then
    notify(string.format("watch stopped after %d errors — %s: %s",
      w.errors or 0, w.label, M.brief_error(detail)), vim.log.levels.ERROR)
  elseif status == "done" then
    notify(string.format("watch finished (%d ticks, no match) — %s", w.tick, w.label),
      vim.log.levels.WARN)
  end

  local delay = cfg().cleanup_delay or 300
  if delay and delay > 0 then
    w.cleanup = vim.defer_fn(function() M.remove(w.id) end, delay * 1000)
  end
  refresh_panel()
end

local run_tick  -- forward declaration

local function schedule_next(w)
  if w.status ~= "running" then return end
  if w.max and w.max > 0 and w.tick >= w.max then
    terminate(w, "done")
    return
  end
  w.next_at = os.time() + w.every
  w.timer = vim.defer_fn(function()
    w.timer = nil
    run_tick(w)
  end, w.every * 1000)
  refresh_panel()
end

-- One tick: run the statement, log the outcome, test the condition, and either
-- stop or schedule the next run.
local function record(w, entry)
  table.insert(w.log, entry)
  local cap = cfg().log_size or 100
  if cap > 0 and #w.log > cap then table.remove(w.log, 1) end
end

run_tick = function(w)
  if w.status ~= "running" then return end
  w.tick = w.tick + 1
  w.running_since = vim.uv.now()
  refresh_panel()

  w.handle = inline.run({
    conn     = w.conn_name,
    sql      = w.sql,
    max_rows = w.max_rows,
    timeout  = w.timeout,
  }, function(err, res)
    w.handle        = nil
    w.running_since = nil
    if w.status ~= "running" then return end

    if err then
      w.errors   = (w.errors or 0) + 1
      w.last_err = err
      record(w, { at = os.time(), err = err })
      local limit = w.stop_after_errors or 0
      if limit > 0 and w.errors >= limit then
        terminate(w, "error", err)
        return
      end
      schedule_next(w)
      return
    end

    w.errors      = 0
    w.last_err    = nil
    w.last_result = res
    w.rows        = res.count

    local matched, detail, warn = w.cond.eval(w, res)
    record(w, {
      at      = os.time(),
      rows    = res.count,
      elapsed = res.elapsed,
      note    = detail or warn,
      matched = matched or nil,
    })
    if warn and not w.warned then
      w.warned = true
      notify("watch: " .. warn .. " — " .. w.label, vim.log.levels.WARN)
    end

    if matched then
      terminate(w, "matched", detail)
      return
    end
    schedule_next(w)
  end)

  if not w.handle then
    -- inline refused before spawning (bad conn, missing binary); fail loudly
    -- rather than spinning on a broken watch.
    terminate(w, "error", "could not start query")
  end
end

-- --- Public control -------------------------------------------------------

-- Start a watch.
--
--   opts.sql               statement to poll, binds already applied  (required)
--   opts.conn              name of a saved connection                (required)
--   opts.label             short display name (default: first SQL line)
--   opts.every             seconds between ticks
--   opts.max               tick cap; 0 = unlimited
--   opts.cond              parsed condition (see M.parse_condition)
--   opts.stop_after_errors consecutive failures before giving up
--   opts.max_rows          row cap per tick
--   opts.timeout           ms before a single tick is killed
--
-- Returns the watch id, or nil + an error message.
function M.start(opts)
  opts = opts or {}
  if type(opts.sql) ~= "string" or opts.sql:match("^%s*$") then
    return nil, "watch: sql is required"
  end
  if type(opts.conn) ~= "string" or opts.conn == "" then
    return nil, "watch: conn is required"
  end

  local cap = cfg().max_active or 5
  if cap > 0 and #M.active() >= cap then
    return nil, string.format(
      "watch: %d watches already running (watch.max_active = %d) — stop one first", #M.active(), cap)
  end

  local every = opts.every
  if not every then
    every = M.parse_duration(cfg().default_interval or "30s") or 30
  end

  local w = {
    id                = new_id(),
    sql               = opts.sql,
    conn_name         = opts.conn,
    label             = opts.label or (opts.sql:gsub("%s+", " "):sub(1, 40)),
    every             = every,
    max               = opts.max or cfg().default_max or 50,
    cond              = opts.cond or M.parse_condition("changed"),
    stop_after_errors = opts.stop_after_errors or cfg().stop_after_errors or 3,
    max_rows          = opts.max_rows,
    timeout           = opts.timeout,
    status            = "running",
    tick              = 0,
    errors            = 0,
    log               = {},
    started_at        = os.time(),
    start             = vim.uv.now(),
  }
  table.insert(watches, w)
  refresh_panel()

  run_tick(w)  -- first tick fires immediately; the wait comes after
  return w.id
end

-- Stop a running watch (leaves it visible in the panel as "stopped").
function M.stop(id)
  local w = M.get(id)
  if not w then return end
  if w.status == "running" then
    terminate(w, "stopped")
  end
end

function M.stop_all()
  for _, w in ipairs(M.active()) do terminate(w, "stopped") end
end

-- Drop a watch from the registry entirely.
function M.remove(id)
  for i, w in ipairs(watches) do
    if w.id == id then
      stop_timer(w)
      if w.cleanup then pcall(function() w.cleanup:stop(); w.cleanup:close() end) end
      if w.handle then pcall(function() w.handle:kill(15) end) end
      table.remove(watches, i)
      break
    end
  end
  refresh_panel()
end

-- Seconds until the next tick, or nil when nothing is scheduled.
function M.next_in(w)
  if not w.next_at then return nil end
  return math.max(0, w.next_at - os.time())
end

-- --- The popup ------------------------------------------------------------
--
-- A plain scratch buffer rather than a form widget: the four settings are
-- ordinary text, so normal motions, `ciw` and counts all work on them. On <CR>
-- we read the known keys back out of the buffer and ignore everything else,
-- which is why the statement preview above them is harmless.

local PROMPT_KEYS = { every = true, ["until"] = true, max = true, errors = true }

vim.api.nvim_set_hl(0, "DbliteWatchTitle", { link = "Title",   default = true })
vim.api.nvim_set_hl(0, "DbliteWatchKey",   { link = "Type",    default = true })
vim.api.nvim_set_hl(0, "DbliteWatchHint",  { link = "Comment", default = true })

-- Pull `key   value` pairs back out of the buffer and fold them into a spec.
-- Only the field block is scanned, never the statement preview above it, so a
-- query containing something like `max  (id)` cannot be mistaken for a setting.
local function read_prompt(bufnr, from_line)
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, (from_line or 1) - 1, -1, false)) do
    local key, val = line:match("^%s*([%a]+)%s+(.-)%s*$")
    if key and PROMPT_KEYS[key:lower()] then
      out[key:lower()] = val
    end
  end

  local spec = {}
  if out.every then
    local secs, err = M.parse_duration(out.every)
    if not secs then return nil, err end
    spec.every = secs
  end
  if out.max then
    local n = tonumber(out.max)
    if not n then
      -- "unlimited" / "inf" / "∞" all mean "no cap"
      if out.max:lower():match("^unlim") or out.max:lower() == "inf" or out.max == "∞" then
        n = 0
      else
        return nil, "max must be a number (0 = unlimited)"
      end
    end
    spec.max = math.max(0, math.floor(n))
  end
  if out.errors then
    local n = tonumber(out.errors)
    if not n then return nil, "errors must be a number (0 = never give up)" end
    spec.stop_after_errors = math.max(0, math.floor(n))
  end
  if out["until"] then
    local cond, err = M.parse_condition(out["until"])
    if not cond then return nil, err end
    spec.cond = cond
  end
  return spec
end

-- Show the watch settings popup. `cb(spec)` runs with the parsed settings when
-- the user confirms, or `cb(nil)` if they cancel.
function M.prompt(opts, cb)
  opts = opts or {}
  local c = cfg()

  local every  = opts.every_str or c.default_interval or "30s"
  local cond   = opts.cond_str  or c.default_condition or "changed"
  local max    = opts.max       or c.default_max or 50
  local errors = opts.errors    or c.stop_after_errors or 3

  local sql_lines = vim.split((opts.sql or ""):gsub("%s+$", ""), "\n", { plain = true })
  if #sql_lines > 6 then
    sql_lines = vim.list_slice(sql_lines, 1, 6)
    table.insert(sql_lines, "…")
  end

  local lines = { "  watch · " .. (opts.label or "statement"), "" }
  for _, l in ipairs(sql_lines) do table.insert(lines, "  " .. l) end
  table.insert(lines, "")
  local first_field = #lines + 1
  table.insert(lines, "  every   " .. every)
  table.insert(lines, "  until   " .. cond)
  table.insert(lines, "  max     " .. tostring(max == 0 and "unlimited" or max))
  table.insert(lines, "  errors  " .. tostring(errors))
  table.insert(lines, "")
  table.insert(lines, "  <CR> start · q cancel")

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.max(46, math.min(width + 4, vim.o.columns - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype  = "dblitewatch"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row      = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col      = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width    = width,
    height   = #lines,
    style    = "minimal",
    border   = "rounded",
  })
  vim.wo[win].wrap = false

  local ns = vim.api.nvim_create_namespace("dblite_watch_prompt")
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "DbliteWatchTitle" })
  for i = 3, 2 + #sql_lines do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #lines[i], hl_group = "DbliteWatchHint" })
  end
  for i = first_field, first_field + 3 do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, { end_col = 8, hl_group = "DbliteWatchKey" })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0,
    { end_col = #lines[#lines], hl_group = "DbliteWatchHint" })

  -- Land on the interval value, the number most often tweaked.
  pcall(vim.api.nvim_win_set_cursor, win, { first_field, 10 })

  local done = false
  local function finish(spec)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    cb(spec)
  end

  local function start()
    local spec, err = read_prompt(buf, first_field)
    if not spec then
      vim.notify("dblite: " .. tostring(err), vim.log.levels.ERROR)
      return  -- leave the popup open so the bad value can be fixed
    end
    finish(spec)
  end

  local map = function(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true })
  end
  map("n", "<CR>", start)
  map("i", "<CR>", function() vim.cmd("stopinsert"); start() end)
  map("n", "q", function() finish(nil) end)
  map("n", "<Esc>", function() finish(nil) end)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once    = true,
    callback = function() finish(nil) end,
  })
end

return M
