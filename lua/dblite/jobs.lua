-- The dblite activity panel: background export jobs, plus the watches owned by
-- `dblite.watch`.
--
-- A "job" is a long-running query whose result set is streamed straight to a
-- file by the native binary (`--to-file`). Jobs run detached from the main
-- dblite result buffer so the user can keep running normal queries while a big
-- dump churns in the background. This module owns the job registry, the shared
-- job history file, and the panel that renders both jobs and watches.
--
-- The panel shows live work first (watches, then running exports) and folds
-- finished exports behind a single collapsible line, because the live region is
-- what you open the panel to check.
local config = require("dblite.config")

local M = {}

local ns = vim.api.nvim_create_namespace("dblite_jobs_panel")

vim.api.nvim_set_hl(0, "DbliteJobsTitle",     { link = "Title",           default = true })
vim.api.nvim_set_hl(0, "DbliteJobsSep",       { link = "Comment",         default = true })
vim.api.nvim_set_hl(0, "DbliteJobsSection",   { link = "Type",            default = true })
vim.api.nvim_set_hl(0, "DbliteJobsRunning",   { link = "Function",        default = true })
vim.api.nvim_set_hl(0, "DbliteJobsDone",      { link = "String",          default = true })
vim.api.nvim_set_hl(0, "DbliteJobsError",     { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "DbliteJobsCancelled", { link = "WarningMsg",      default = true })
vim.api.nvim_set_hl(0, "DbliteJobsMeta",      { link = "Comment",         default = true })
vim.api.nvim_set_hl(0, "DbliteJobsWatch",     { link = "Constant",        default = true })

local ICON = {
  running   = "⋯",  -- export in flight
  done      = "✓",
  error     = "✗",
  cancelled = "✗",
  watch     = "◐",  -- watch still polling
  matched   = "✓",  -- watch found what it was waiting for
  expired   = "○",  -- watch hit its tick cap without matching
  stopped   = "⊘",  -- watch stopped by hand
}

local jobs = {}   -- live job records for THIS instance (running + pending cleanup)

-- Globally-unique job id: time + pid + counter, so entries from concurrent
-- Neovim instances never collide when merged into the shared history file.
local pid         = vim.fn.getpid()
local id_counter  = 0
local function new_id()
  id_counter = id_counter + 1
  return string.format("%d-%d-%d", os.time(), pid, id_counter)
end

local state = {
  bufnr        = nil,
  winnr        = nil,
  line_map     = {},    -- panel line (1-based) → { kind = "job"|"watch"|"history_toggle", id }
  prev_winnr   = nil,
  history_open = false, -- finished exports start folded
  ticker       = nil,   -- 1s redraw while the panel is open and work is live
}

-- --- Persistent history ---------------------------------------------------
-- Terminal jobs (done/error/cancelled) are appended to a shared JSON file so
-- history survives restarts and is visible across all Neovim instances. Only
-- terminal jobs are persisted — running jobs live in the owning instance's
-- memory, so a killed instance never leaves a stuck "running" ghost. Watches are
-- never written here either; they are session-local by design.

local history_cache = {}  -- past terminal jobs, newest-first (in-memory mirror)

local function history_cfg()
  return (config.jobs and config.jobs.history) or {}
end

local function history_enabled()
  return history_cfg().enabled ~= false  -- default on
end

local function history_path()
  return history_cfg().file or (vim.fn.stdpath("data") .. "/dblite/jobs.json")
end

local function read_history_file()
  local f = io.open(history_path(), "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw or "")
  return (ok and type(data) == "table" and vim.islist(data)) and data or {}
end

local function write_history_file(list)
  local p = history_path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local tmp = p .. ".tmp." .. pid
  local f = io.open(tmp, "wb")
  if not f then return end
  local ok = pcall(function() f:write(vim.json.encode(list)) end)
  f:close()
  if ok then os.rename(tmp, p) else os.remove(tmp) end
end

local function newest_first(list)
  table.sort(list, function(a, b) return (a.finished_at or 0) > (b.finished_at or 0) end)
  return list
end

-- The persisted shape of a job (runtime-only fields like handle/timers dropped).
local function to_record(j)
  return {
    id        = j.id,        label     = j.label,   path    = j.path,
    format    = j.format,    conn_name = j.conn_name, query = j.query,
    status    = j.status,    started_at = j.started_at, finished_at = j.finished_at,
    duration  = j.duration,  rows      = j.rows,    error   = j.error,
  }
end

-- Read → merge this job by id → sort → trim to max_entries → atomic write.
local function persist(j)
  if not history_enabled() then return end
  local list = read_history_file()
  local replaced = false
  for i, e in ipairs(list) do
    if e.id == j.id then list[i] = to_record(j); replaced = true; break end
  end
  if not replaced then table.insert(list, to_record(j)) end
  newest_first(list)
  local cap = history_cfg().max_entries or 200
  if cap > 0 and #list > cap then
    for i = #list, cap + 1, -1 do table.remove(list, i) end
  end
  write_history_file(list)
  history_cache = list
end

-- Refresh the in-memory mirror from disk (called on panel open + after writes).
local function load_history()
  history_cache = history_enabled() and newest_first(read_history_file()) or {}
end

-- --- Registry -------------------------------------------------------------

local function job_by_id(id)
  for _, j in ipairs(jobs) do
    if j.id == id then return j end
  end
end

-- Find a displayed entry (live job or history record) by id.
local function entry_by_id(id)
  local j = job_by_id(id)
  if j then return j end
  for _, e in ipairs(history_cache) do
    if e.id == id then return e end
  end
end

-- Register a new running job. `rec` supplies: label, path, format, conn_name,
-- query. Returns the job id used by set_handle / finish.
function M.register(rec)
  rec.id         = new_id()
  rec.status     = "running"
  rec.start      = vim.uv.now()  -- monotonic; live elapsed only (not persisted)
  rec.started_at = os.time()     -- wall clock; persisted
  table.insert(jobs, rec)
  M.refresh()
  return rec.id
end

function M.set_handle(id, handle)
  local j = job_by_id(id)
  if j then j.handle = handle end
end

-- Mark a job finished (status = "done" | "error" | "cancelled") and merge any
-- extra fields (rows, error). Persists it to history and schedules removal of
-- the live copy after cleanup_delay (it stays visible via history afterwards).
function M.finish(id, fields)
  local j = job_by_id(id)
  if not j then return end
  for k, v in pairs(fields or {}) do j[k] = v end
  j.finished_at = os.time()
  j.duration    = j.start and (vim.uv.now() - j.start) / 1000 or 0
  j.handle      = nil
  persist(j)
  local delay = config.jobs and config.jobs.cleanup_delay or 300
  if delay and delay > 0 then
    j.cleanup = vim.defer_fn(function() M.remove(id) end, delay * 1000)
  end
  M.refresh()
end

-- Remove a job from the live registry (and cancel its pending cleanup timer).
-- Does not touch history — see M.forget.
function M.remove(id)
  for i, j in ipairs(jobs) do
    if j.id == id then
      if j.cleanup then pcall(function() j.cleanup:stop(); j.cleanup:close() end) end
      table.remove(jobs, i)
      break
    end
  end
  M.refresh()
end

-- Permanently delete a job from the shared history file.
function M.forget(id)
  if not history_enabled() then return end
  local list = read_history_file()
  local changed = false
  for i = #list, 1, -1 do
    if list[i].id == id then table.remove(list, i); changed = true end
  end
  if changed then write_history_file(list) end
  history_cache = newest_first(list)
  M.refresh()
end

function M.has_running()
  for _, j in ipairs(jobs) do
    if j.status == "running" then return true end
  end
  return false
end

-- --- Rendering ------------------------------------------------------------
--
-- The panel is deliberately flat: one title, then a live region (watches and
-- running exports, the things you actually came to look at), then finished work
-- folded behind a single collapsible line. No section headers, no rules, no
-- column alignment beyond right-aligning the meta column.

local function trunc(s, n)
  if vim.fn.strchars(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

-- 5412 → "5,412". Long-running exports report big numbers and unseparated
-- digits are hard to read at a glance.
local function commas(n)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

local function format_duration(j)
  if j.status == "running" then return "running" end
  if not j.duration then return "?s" end
  return string.format("%.1fs", j.duration)
end

local function format_rows(rows)
  return (rows ~= nil and commas(rows) or "?") .. " rows"
end

local function file_name(j)
  local name = j.label or j.path or "?"
  return name == "?" and name or vim.fn.fnamemodify(name, ":t")
end

local function confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

local function id_counter(id)
  return tonumber(tostring(id or ""):match("%-(%d+)$")) or 0
end

local function newer_running_first(a, b)
  local ast, bst = a.started_at or 0, b.started_at or 0
  if ast ~= bst then return ast > bst end
  local am, bm = a.start or 0, b.start or 0
  if am ~= bm then return am > bm end
  return id_counter(a.id) > id_counter(b.id)
end

local function newer_history_first(a, b)
  local aft, bft = a.finished_at or 0, b.finished_at or 0
  if aft ~= bft then return aft > bft end
  local ast, bst = a.started_at or 0, b.started_at or 0
  if ast ~= bst then return ast > bst end
  return id_counter(a.id) > id_counter(b.id)
end

local function watch_mod()
  local ok, w = pcall(require, "dblite.watch")
  return ok and w or nil
end

-- Watches render as `tick/cap · rows · next tick`, so a glance answers "how far
-- along is it and when does it look again".
local function watch_line_parts(w)
  local icon, hl
  if w.status == "running" then
    icon, hl = ICON.watch, "DbliteJobsWatch"
  elseif w.status == "matched" then
    icon, hl = ICON.matched, "DbliteJobsDone"
  elseif w.status == "error" then
    icon, hl = ICON.error, "DbliteJobsError"
  elseif w.status == "stopped" then
    icon, hl = ICON.stopped, "DbliteJobsCancelled"
  else -- done: ran to the cap without matching
    icon, hl = ICON.expired, "DbliteJobsCancelled"
  end

  local cap  = (w.max and w.max > 0) and tostring(w.max) or "∞"
  local meta = w.tick .. "/" .. cap .. " · " .. format_rows(w.rows)

  if w.status == "running" then
    local wm = watch_mod()
    local nxt = wm and wm.next_in(w) or nil
    if w.running_since then
      meta = meta .. " · run"
    elseif nxt then
      meta = meta .. " · " .. wm.fmt_duration(nxt)
    end
  elseif w.status == "matched" then
    meta = meta .. " · matched"
  elseif w.status == "error" then
    meta = meta .. " · failed"
  elseif w.status == "done" then
    meta = meta .. " · no match"
  else
    meta = meta .. " · stopped"
  end

  return icon, hl, meta
end

local function job_line_parts(j)
  local icon, hl, tail
  if j.status == "running" then
    icon, hl, tail = ICON.running, "DbliteJobsRunning", format_rows(j.rows)
  elseif j.status == "done" then
    icon, hl, tail = ICON.done, "DbliteJobsDone", format_rows(j.rows)
  elseif j.status == "error" then
    -- A failed export wrote no rows, so "? rows" is noise; say what happened.
    icon, hl, tail = ICON.error, "DbliteJobsError", "failed"
  else
    icon, hl, tail = ICON.cancelled, "DbliteJobsCancelled", "cancelled"
  end
  return icon, hl, format_duration(j) .. " · " .. tail
end

-- One entry line: `  <icon> <label>        <meta>`, meta right-aligned.
local function append_entry(ctx, icon, status_hl, label, meta, ref)
  local prefix = "  "
  local mid    = " "
  local label_width = math.max(8, ctx.width - 7 - vim.fn.strdisplaywidth(meta))
  local labelf = trunc(label, label_width)
  local pad    = string.rep(" ", math.max(1, label_width + 1 - vim.fn.strdisplaywidth(labelf)))
  local line   = prefix .. icon .. mid .. labelf .. pad .. meta

  table.insert(ctx.lines, line)
  local row = #ctx.lines - 1
  ctx.line_map[#ctx.lines] = ref

  local icon_col = #prefix
  local meta_col = #prefix + #icon + #mid + #labelf + #pad
  table.insert(ctx.hls, { row = row, col = icon_col, ecol = icon_col + #icon, group = status_hl })
  table.insert(ctx.hls, { row = row, col = meta_col, ecol = meta_col + #meta, group = "DbliteJobsMeta" })
end

-- Live jobs and terminal history are split: terminal live jobs stay in history
-- until cleanup drops the live copy, so recently finished work keeps its place.
local function display_groups()
  local running, history, seen_history = {}, {}, {}

  for _, j in ipairs(jobs) do
    if j.status == "running" then
      running[#running + 1] = j
    else
      history[#history + 1] = j
      seen_history[j.id] = true
    end
  end

  local show = history_cfg().show or 20
  for _, e in ipairs(history_cache) do
    if not seen_history[e.id] then
      history[#history + 1] = e
    end
  end

  table.sort(running, newer_running_first)
  table.sort(history, newer_history_first)
  if show > 0 and #history > show then
    for i = #history, show + 1, -1 do table.remove(history, i) end
  end

  return running, history
end

local function build_lines()
  local width = (config.jobs and config.jobs.panel and config.jobs.panel.width) or 44
  local ctx   = { lines = { "  dblite", "" }, line_map = {}, hls = {}, width = width }
  table.insert(ctx.hls, { row = 0, col = 2, ecol = #ctx.lines[1], group = "DbliteJobsTitle" })

  -- Watches first: they are the reason the panel is open most of the time.
  local wm = watch_mod()
  local watches = wm and wm.list() or {}
  for _, w in ipairs(watches) do
    local icon, hl, meta = watch_line_parts(w)
    append_entry(ctx, icon, hl, w.label or "watch", meta, { kind = "watch", id = w.id })
  end

  local running, history = display_groups()
  for _, j in ipairs(running) do
    local icon, hl, meta = job_line_parts(j)
    append_entry(ctx, icon, hl, file_name(j), meta, { kind = "job", id = j.id })
  end

  if #watches == 0 and #running == 0 then
    table.insert(ctx.lines, "  nothing running")
    table.insert(ctx.hls, { row = #ctx.lines - 1, col = 0, ecol = #ctx.lines[#ctx.lines],
      group = "DbliteJobsMeta" })
  end

  -- Finished work folds behind one line; <Tab> on it expands.
  if #history > 0 then
    table.insert(ctx.lines, "")
    local arrow = state.history_open and "▾" or "▸"
    local line  = "  " .. arrow .. " History (" .. #history .. ")"
    table.insert(ctx.lines, line)
    table.insert(ctx.hls, { row = #ctx.lines - 1, col = 0, ecol = #line, group = "DbliteJobsMeta" })
    ctx.line_map[#ctx.lines] = { kind = "history_toggle" }

    if state.history_open then
      for _, j in ipairs(history) do
        local icon, hl, meta = job_line_parts(j)
        append_entry(ctx, icon, hl, file_name(j), meta, { kind = "job", id = j.id })
      end
    end
  end

  return ctx.lines, ctx.line_map, ctx.hls
end

local function render()
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local lines, line_map, hls = build_lines()
  state.line_map = line_map

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, h.row, h.col, { end_col = h.ecol, hl_group = h.group })
  end
end

-- Public refresh: re-render only if the panel is currently open.
function M.refresh()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then render() end
end

-- A watch's "next tick in 24s" only stays truthful if something redraws it, so
-- the panel ticks once a second while it is open and anything is still live.
local function stop_ticker()
  if state.ticker then
    pcall(function() state.ticker:stop(); state.ticker:close() end)
    state.ticker = nil
  end
end

local function start_ticker()
  stop_ticker()
  local t = vim.uv.new_timer()
  if not t then return end
  state.ticker = t
  t:start(1000, 1000, function()
    vim.schedule(function()
      if not (state.winnr and vim.api.nvim_win_is_valid(state.winnr)) then
        stop_ticker()
        return
      end
      local wm = watch_mod()
      if M.has_running() or (wm and wm.has_running()) then render() end
    end)
  end)
end

-- --- Panel window ---------------------------------------------------------

local function ref_at_cursor()
  if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  return state.line_map[row]
end

local function job_at_cursor()
  local ref = ref_at_cursor()
  if not ref or ref.kind ~= "job" then return nil end
  return entry_by_id(ref.id)
end

local function watch_at_cursor()
  local ref = ref_at_cursor()
  if not ref or ref.kind ~= "watch" then return nil end
  local wm = watch_mod()
  return wm and wm.get(ref.id) or nil
end

local function human_time(t)
  return t and os.date("%Y-%m-%d %H:%M:%S", t) or "?"
end

-- Re-point a job at a new output path (e.g. after it was moved/renamed on disk)
-- and persist it, so future opens jump to the right place. Updates the live copy
-- and the history record for the same id together.
local function update_path(entry, new_path)
  entry.path = new_path
  local j = job_by_id(entry.id)
  if j and j ~= entry then j.path = new_path end
  persist(entry)  -- merge into the shared history file + refresh the cache
  M.refresh()
end

-- Prompt for the file's new location (prefilled with the last-known path) and,
-- if the entered path is readable, remember it. `on_ok` runs after a successful
-- relocate — used so the open flow can chain straight into opening the file.
local function relocate(entry, on_ok)
  vim.ui.input({
    prompt   = "New path for \"" .. file_name(entry) .. "\": ",
    default  = entry.path or "",
    completion = "file",
  }, function(input)
    if not input or input == "" then return end
    local path = vim.fn.fnamemodify(vim.fn.expand(input), ":p")
    if vim.fn.filereadable(path) ~= 1 then
      vim.notify("dblite: file not found: " .. path, vim.log.levels.WARN)
      return
    end
    update_path(entry, path)
    vim.notify("dblite: job re-pointed → " .. path, vim.log.levels.INFO)
    if on_ok then on_ok(path) end
  end)
end

-- Hover-style details float. open_floating_preview anchors at the cursor, so in
-- the narrow panel it only gets the panel's width and clips long paths/queries.
-- Instead we anchor to the editor and open leftward into the main area, sizing
-- to the content up to the full editor width. Auto-closes on the next cursor
-- move, like a hover.
local function open_details_float(lines)
  local content_w = 0
  for _, l in ipairs(lines) do
    content_w = math.max(content_w, vim.fn.strdisplaywidth(l))
  end

  local panel_w = (config.jobs and config.jobs.panel and config.jobs.panel.width) or 44
  local max_w   = math.max(20, vim.o.columns - panel_w - 4)  -- room left of the panel
  local width   = math.max(20, math.min(content_w + 1, max_w))
  local height  = math.min(#lines, math.max(3, vim.o.lines - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  -- Right edge just left of the panel; clamp so a very wide float stays on-screen.
  local col = math.max(0, vim.o.columns - panel_w - width - 2)
  local row = math.min(math.max(vim.fn.screenrow() - 1, 1), math.max(1, vim.o.lines - height - 2))

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
  })
  vim.wo[win].wrap = false

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
    buffer = state.bufnr,
    once   = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end,
  })
  return win
end

-- Details for a watch: what it is waiting for, how far it has got, and the
-- per-tick log so you can see when the row count moved.
local function watch_details(w)
  local wm = watch_mod()
  local lines = {
    "Status:    " .. (w.status or "?") .. (w.detail and ("  (" .. w.detail .. ")") or ""),
    "Waiting:   " .. (w.cond and w.cond.describe or "?"),
    "Conn:      " .. (w.conn_name or "?"),
    "Every:     " .. (wm and wm.fmt_duration(w.every) or (w.every .. "s")),
    "Ticks:     " .. w.tick .. "/" .. ((w.max and w.max > 0) and w.max or "∞"),
    "Rows:      " .. (w.rows ~= nil and tostring(w.rows) or "?"),
    "Started:   " .. human_time(w.started_at),
  }
  if w.status == "running" then
    local nxt = wm and wm.next_in(w)
    table.insert(lines, "Next tick: " ..
      (w.running_since and "running now" or (nxt and wm.fmt_duration(nxt) or "?")))
  else
    table.insert(lines, "Finished:  " .. human_time(w.finished_at))
  end
  if w.last_err then
    table.insert(lines, "Error:     " .. (wm and wm.brief_error(w.last_err) or tostring(w.last_err)))
  end

  table.insert(lines, "")
  table.insert(lines, "Query:")
  for _, q in ipairs(vim.split(w.sql or "", "\n", { plain = true })) do
    table.insert(lines, "  " .. q)
  end

  if #(w.log or {}) > 0 then
    table.insert(lines, "")
    table.insert(lines, "Ticks:")
    for i, e in ipairs(w.log) do
      local when = os.date("%H:%M:%S", e.at)
      local body
      if e.err then
        body = "error: " .. tostring(e.err)
      else
        body = string.format("%s rows  %.2fs%s",
          e.rows ~= nil and tostring(e.rows) or "?", e.elapsed or 0,
          e.note and ("  — " .. e.note) or "")
      end
      table.insert(lines, string.format("  %3d  %s  %s", i, when, body))
    end
  end
  return lines
end

local function job_details(j)
  local missing = j.status == "done" and vim.fn.filereadable(j.path or "") ~= 1
  local lines = {
    "Status:   " .. (j.status or "?") .. (missing and "  (file missing)" or ""),
    "File:     " .. (j.path or "?"),
    "Format:   " .. (j.format or "?"),
    "Conn:     " .. (j.conn_name or "?"),
    "Rows:     " .. (j.rows ~= nil and tostring(j.rows) or "?"),
    "Duration: " .. format_duration(j),
    "Started:  " .. human_time(j.started_at),
    "Finished: " .. human_time(j.finished_at),
  }
  if j.error and j.error ~= "" then
    table.insert(lines, "Error:    " .. tostring(j.error))
  end
  if j.query and j.query ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Query:")
    for _, q in ipairs(vim.split(j.query, "\n", { plain = true })) do
      table.insert(lines, "  " .. q)
    end
  end
  return lines
end

local function setup_keymaps(bufnr)
  local km = (config.keymaps and config.keymaps.jobs) or {}

  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end

  -- Open a job's output file in a new tab (leaving the panel per close_on_open).
  local function open_output(path)
    local target = state.prev_winnr
    if target and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
    if not (config.jobs and config.jobs.close_on_open == false) then
      M.close()
    end
    vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  end

  -- A watch's latest snapshot goes into the normal result window, so paging,
  -- `gi` inspect, export and history navigation all work on it unchanged.
  local function open_watch(w)
    if not w.last_result then
      vim.notify("dblite: watch has no result yet", vim.log.levels.INFO)
      return
    end
    local target = state.prev_winnr
    if target and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
    if not (config.jobs and config.jobs.close_on_open == false) then
      M.close()
    end
    require("dblite").show_result(w.last_result, { query = w.sql, conn = w.conn_name })
  end

  map(km.open or "<CR>", function()
    local ref = ref_at_cursor()
    if not ref then return end

    if ref.kind == "history_toggle" then
      state.history_open = not state.history_open
      render()
      return
    end

    if ref.kind == "watch" then
      local w = watch_at_cursor()
      if w then open_watch(w) end
      return
    end

    local j = job_at_cursor()
    if not j then return end
    if j.status == "running" then
      vim.notify("dblite: job still running — " .. (j.path or ""), vim.log.levels.INFO)
      return
    end
    if j.status ~= "done" then
      vim.notify("dblite: no output file (" .. j.status .. ")", vim.log.levels.WARN)
      return
    end
    -- The file may have been moved/renamed on disk since the export ran. Rather
    -- than dead-end, offer to re-point the job at its new location and open it.
    if vim.fn.filereadable(j.path) ~= 1 then
      if confirm("Output file not found:\n\n" .. tostring(j.path) .. "\n\nLocate it now?") then
        relocate(j, function(path) open_output(path) end)
      end
      return
    end
    open_output(j.path)
  end, "dblite: open entry under cursor")

  -- <Tab> folds/unfolds history from anywhere in the panel.
  map(km.fold or "<Tab>", function()
    state.history_open = not state.history_open
    render()
  end, "dblite: fold/unfold history")

  map(km.hover or "K", function()
    local w = watch_at_cursor()
    if w then open_details_float(watch_details(w)); return end
    local j = job_at_cursor()
    if j then open_details_float(job_details(j)) end
  end, "dblite: hover entry details")

  map(km.relocate or "r", function()
    local j = job_at_cursor()
    if not j then return end
    if j.status ~= "done" then
      vim.notify("dblite: nothing to relocate (" .. j.status .. ")", vim.log.levels.INFO)
      return
    end
    relocate(j)
  end, "dblite: relocate job output file")

  local function cancel_or_delete()
    local w = watch_at_cursor()
    if w then
      local wm = watch_mod()
      if not wm then return end
      if w.status == "running" then
        if not confirm("Stop watch?\n\n" .. (w.label or "")) then return end
        wm.stop(w.id)
        vim.notify("dblite: watch stopped — " .. (w.label or ""), vim.log.levels.INFO)
      else
        wm.remove(w.id)
      end
      return
    end

    local j = job_at_cursor()
    if not j then return end
    if j.status == "running" then
      if not confirm("Cancel running job?\n\n" .. file_name(j)) then return end
      if j.handle then pcall(function() j.handle:kill(15) end) end
      vim.notify("dblite: cancelling job → " .. (j.path or ""), vim.log.levels.INFO)
    else
      if not confirm("Delete job from history?\n\n" .. file_name(j)) then return end
      M.remove(j.id)   -- drop the live copy (if any)
      M.forget(j.id)   -- and delete it from the shared history
    end
  end

  local cancel_lhs = km.cancel or "x"
  map(cancel_lhs, cancel_or_delete, "dblite: stop / delete entry")
  if cancel_lhs == "x" then
    map("X", cancel_or_delete, "dblite: stop / delete entry")
  end

  map(km.close or "q", function() M.close() end, "dblite: close panel")

  -- Optional: same key you opened the panel with can close it from inside.
  -- Off by default (""); set to your open key's lhs for symmetry.
  map(km.toggle, function() M.toggle() end, "dblite: toggle panel")
end

-- Open the panel. opts.focus = false leaves the cursor in the previous window
-- (used when auto-opening on job start so we don't steal focus from the editor).
-- When opts.focus is nil, fall back to `config.jobs.focus` (default true).
function M.open(opts)
  opts = opts or {}
  if opts.focus == nil then
    local jc = config.jobs
    opts.focus = not (jc and jc.focus == false)
  end
  local prev = vim.api.nvim_get_current_win()

  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    if opts.focus == false then return end
    vim.api.nvim_set_current_win(state.winnr)
    return
  end

  state.prev_winnr = prev

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype   = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile  = false
    state.bufnr = bufnr
    setup_keymaps(bufnr)
  end

  -- A right-side vertical split (like the connections panel), not a float, so it
  -- coexists with the editor/result windows. winfixwidth keeps its width steady
  -- as other splits open and close.
  local panel_cfg = config.jobs and config.jobs.panel or {}
  local width = panel_cfg.width or 44
  vim.cmd("botright " .. width .. "vsplit")
  local winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winnr, state.bufnr)
  state.winnr = winnr

  vim.wo[winnr].number         = false
  vim.wo[winnr].relativenumber = false
  vim.wo[winnr].signcolumn     = "no"
  vim.wo[winnr].wrap           = false
  vim.wo[winnr].cursorline     = true
  vim.wo[winnr].winfixwidth    = true

  load_history()  -- pick up entries from past sessions / other instances
  if history_cfg().start_open then state.history_open = true end
  render()
  start_ticker()

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(winnr),
    once     = true,
    callback = function()
      state.winnr = nil
      stop_ticker()
    end,
  })

  if opts.focus == false and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
end

function M.close()
  stop_ticker()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
  state.winnr = nil
  if state.prev_winnr and vim.api.nvim_win_is_valid(state.prev_winnr) then
    vim.api.nvim_set_current_win(state.prev_winnr)
  end
end

function M.toggle()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

return M
