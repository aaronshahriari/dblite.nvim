local config       = require("dblite.config")
local connections  = require("dblite.connections")
local panel        = require("dblite.panel")
local telescope    = require("dblite.telescope")
local query_module = require("dblite.query")
local load_mod     = require("dblite.load")
local jobs         = require("dblite.jobs")
local binds_mod    = require("dblite.binds")
local inline       = require("dblite.inline")
local watch        = require("dblite.watch")
local output       = require("dblite.output")
local json_fmt     = require("dblite.json")
local devicons     = require("dblite.devicons")

local M = {}

-- Resolve plugin root from this file's location (lua/dblite/init.lua → root)
local _plugin_root = (function()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    return src:sub(2):gsub("/lua/dblite/init%.lua$", "")
  end
end)()

-- "vertical"/"horizontal" describe the split line, not where the window lands,
-- which is a coin flip to remember. The directional names are aliases for the
-- same placements and are what :DbliteSplit accepts.
local split_cmds = {
  vertical   = "botright vnew",
  horizontal = "botright new",
  tab        = "tabnew",
  right      = "botright vnew",
  left       = "topleft vnew",
  below      = "botright new",
  above      = "topleft new",
}

-- Which dimension a placement is sized by, and its config.split_size key.
local split_axis = {
  vertical = "width", right = "width", left = "width",
  horizontal = "height", below = "height", above = "height",
}

local ns        = vim.api.nvim_create_namespace("dblite")
local flash_ns  = vim.api.nvim_create_namespace("dblite_flash")
local search_ns = vim.api.nvim_create_namespace("dblite_search")
vim.api.nvim_set_hl(0, "DbliteStatusPage",      { link = "Title",           default = true })
vim.api.nvim_set_hl(0, "DbliteFlash",           { link = "Visual",          default = true })
vim.api.nvim_set_hl(0, "DbliteSearch",          { link = "Search",          default = true })
vim.api.nvim_set_hl(0, "DbliteCancelled",       { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "DbliteColumnType",      { link = "Comment",         default = true })

local state = {
  result_bufnr    = nil,
  current_job     = nil,
  rows            = {},
  columns         = {},
  widths          = {},
  page            = 1,
  active_conn     = nil,
  spinner_timer   = nil,
  spinner_start   = 0,
  last_elapsed    = nil,
  flash_bufnr     = nil,
  raw_json        = nil,
  search_matches  = {},  -- global row indices (1-based) matching current search
  search_current  = 0,   -- index into search_matches of the highlighted match
  search_pattern  = nil, -- active pattern string; nil = no search
  history         = {},  -- ring of past query results
  history_idx     = 0,   -- current position in history; 0 = no entries
  column_types    = {},  -- parallel array to columns: type name per column
  show_types      = nil, -- nil = use config default; true/false = user toggled
  fullscreen_tab  = nil, -- tabpage handle when dbout is fullscreen
  split_dir       = {},  -- live placement, keyed by connection type; falls back to config
  split_size      = {},  -- last size the user left dbout at, per axis
  render_mode     = "grid", -- how the current result is drawn: grid | json | text
  forced_mode     = nil, -- mode pinned by :DbliteOutput; nil/"auto" = decide per result
  dbout_filetype  = nil, -- filetype dbout currently carries, to avoid redundant resets
}

-- ── per-connection-type config ─────────────────────────────────────────────
-- `config.types.<type>` overrides the top-level default for whichever
-- connection is active. Redis and a SQL database want different result
-- windows often enough that a single global setting is the wrong shape.

local function conn_type()
  return (state.active_conn and state.active_conn.type) or "_default"
end

-- A scalar setting, per-type block first.
local function opt(key)
  local per = (config.types or {})[conn_type()]
  local v = per and per[key]
  if v ~= nil then return v end
  return config[key]
end

-- `output` is merged rather than replaced, so a per-type block can pin one
-- command without restating the whole table.
local function output_cfg()
  local base = config.output or {}
  local per  = ((config.types or {})[conn_type()] or {}).output
  if not per then return base end
  return vim.tbl_deep_extend("force", vim.deepcopy(base), per)
end

local function merge_into(target, source)
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" and not vim.islist(v) then
      merge_into(target[k], v)
    else
      target[k] = v
    end
  end
end

-- Editor actions bindable from a SQL buffer. Order is stable so `:map` output
-- reads predictably. Each maps a `keymaps.editor` key → handler + description.
local EDITOR_ACTIONS = {
  { key = "run",          desc = "run buffer",              fn = function() M.execute() end },
  { key = "run_at",       desc = "run statement at cursor", fn = function() M.execute_at_cursor() end },
  { key = "run_script",   desc = "run buffer as script",    fn = function() M.execute_script() end },
  { key = "run_bulk",     desc = "bulk background export",  fn = function() M.run_async() end },
  { key = "watch",        desc = "watch statement at cursor",fn = function() M.watch() end },
  { key = "watch_file",   desc = "watch whole buffer",      fn = function() M.watch_file() end },
  { key = "toggle_dbout", desc = "toggle result window",    fn = function() M.toggle_dbout() end },
  { key = "toggle_panel", desc = "toggle connections panel",fn = function() M.toggle_panel() end },
  { key = "toggle_jobs",  desc = "toggle activity panel",   fn = function() M.toggle_jobs() end },
  { key = "inspect",      desc = "inspect current page",    fn = function() M.inspect() end },
  { key = "binds",        desc = "edit bind parameters",    fn = function() M.edit_binds() end },
  { key = "connections",  desc = "edit connections file",   fn = function() M.edit_connections_file() end },
  { key = "fullscreen",   desc = "toggle dbout fullscreen", fn = function() M.toggle_fullscreen() end },
  { key = "cycle_split",  desc = "flip dbout split",        fn = function() M.cycle_split() end },
  { key = "hover_bind",   desc = "hover bind value",        fn = function() M.hover_bind() end },
}

local GLOBAL_ACTIONS = {
  { key = "run",          desc = "run buffer",              fn = function() M.execute() end },
  { key = "run_at",       desc = "run statement at cursor", fn = function() M.execute_at_cursor() end },
  { key = "run_script",   desc = "run buffer as script",    fn = function() M.execute_script() end },
  { key = "run_bulk",     desc = "bulk background export",  fn = function() M.run_async() end },
  { key = "watch",        desc = "watch statement at cursor",fn = function() M.watch() end },
  { key = "watch_file",   desc = "watch whole buffer",      fn = function() M.watch_file() end },
  { key = "toggle_dbout", desc = "toggle result window",    fn = function() M.toggle_dbout() end },
  { key = "toggle_panel", desc = "toggle connections panel",fn = function() M.toggle_panel() end },
  { key = "toggle_jobs",  desc = "toggle activity panel",   fn = function() M.toggle_jobs() end },
  { key = "toggle_binds", desc = "toggle binds window",     fn = function() M.toggle_binds() end },
  { key = "inspect",      desc = "inspect current page",    fn = function() M.inspect() end },
  { key = "fullscreen",   desc = "toggle dbout fullscreen", fn = function() M.toggle_fullscreen() end },
  { key = "cycle_split",  desc = "flip dbout split",        fn = function() M.cycle_split() end },
  { key = "cycle_output", desc = "cycle dbout rendering",   fn = function() M.cycle_output() end },
  { key = "connections",  desc = "edit connections file",   fn = function() M.edit_connections_file() end },
}

local installed_global_keymaps = {}

local function apply_global_keymaps()
  for _, lhs in pairs(installed_global_keymaps) do
    pcall(vim.keymap.del, "n", lhs)
    pcall(vim.keymap.del, "x", lhs)  -- run_bulk also installs a visual mapping
  end
  installed_global_keymaps = {}

  local gk = (config.keymaps and config.keymaps.global) or {}
  for _, a in ipairs(GLOBAL_ACTIONS) do
    local lhs = gk[a.key]
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, a.fn, { silent = true, desc = "dblite: " .. a.desc })
      if a.key == "run_bulk" then
        vim.keymap.set("x", lhs, M.run_bulk_visual,
          { silent = true, desc = "dblite: bulk export selection" })
      elseif a.key == "watch" then
        vim.keymap.set("x", lhs, M.watch_visual,
          { silent = true, desc = "dblite: watch selection" })
      end
      installed_global_keymaps[a.key] = lhs
    end
  end
end

-- Apply dblite's buffer-local editor keymaps to `buf`, then run the user's
-- on_attach hook. Exposed so users who manage attachment themselves can call it.
function M.attach(buf)
  local ek = (config.keymaps and config.keymaps.editor) or {}
  for _, a in ipairs(EDITOR_ACTIONS) do
    local lhs = ek[a.key]
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, a.fn,
        { buffer = buf, silent = true, desc = "dblite: " .. a.desc })
      -- run_bulk and watch also work on a visual selection (the statements it touches)
      if a.key == "run_bulk" then
        vim.keymap.set("x", lhs, M.run_bulk_visual,
          { buffer = buf, silent = true, desc = "dblite: bulk export selection" })
      elseif a.key == "watch" then
        vim.keymap.set("x", lhs, M.watch_visual,
          { buffer = buf, silent = true, desc = "dblite: watch selection" })
      end
    end
  end
  if type(config.on_attach) == "function" then
    local ok, err = pcall(config.on_attach, buf)
    if not ok then
      vim.notify("dblite: on_attach error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

function M.setup(opts)
  if opts then merge_into(config, opts) end
  apply_global_keymaps()
  devicons.setup()

  -- Neovim has no `redis` filetype of its own, so `*.redis` would attach
  -- nothing. Claim it here (without overriding a detection the user set up
  -- themselves) so a Redis scratch file gets dblite's editor keymaps.
  if vim.tbl_contains(config.filetypes or {}, "redis")
      and vim.filetype.match({ filename = "dblite-probe.redis" }) == nil then
    pcall(vim.filetype.add, { extension = { redis = "redis" } })
  end

  -- SQL-only keymaps + on_attach: applied per-buffer via a FileType autocmd, so
  -- they are always buffer-local and never fire in unrelated buffers/windows.
  local fts = config.filetypes or { "sql", "plsql", "mysql", "sqlite" }
  vim.api.nvim_create_autocmd("FileType", {
    pattern  = fts,
    group    = vim.api.nvim_create_augroup("dblite_sql_keymaps", { clear = true }),
    callback = function(ev) M.attach(ev.buf) end,
  })

  -- Watches are session-local, so quitting silently throws them away. Say so
  -- rather than letting a poll you were waiting on disappear unannounced.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group    = vim.api.nvim_create_augroup("dblite_watch_guard", { clear = true }),
    callback = function()
      local n = #watch.active()
      if n > 0 then
        vim.notify(string.format("dblite: %d watch(es) still running — they stop with this session", n),
          vim.log.levels.WARN)
      end
    end,
  })
end

local function effective_max_col_width()
  if state.fullscreen_tab and vim.api.nvim_tabpage_is_valid(state.fullscreen_tab) then return 0 end
  return opt("max_col_width") or 0
end

local function cell(value, width)
  local s = value == vim.NIL and "" or tostring(value)
  s = s:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "\\r")
  local max = effective_max_col_width()
  if max > 0 and #s > max then
    s = s:sub(1, max - 1) .. "…"
  end
  if #s < width then
    s = s .. string.rep(" ", width - #s)
  end
  return s
end

local function compute_widths(rows, columns)
  local widths = {}
  local max = effective_max_col_width()
  for _, col in ipairs(columns) do
    widths[col] = #col
  end
  for _, row in ipairs(rows) do
    for _, col in ipairs(columns) do
      local v = row[col]
      local s = v == vim.NIL and "" or tostring(v)
      if max > 0 and #s > max then s = s:sub(1, max) end
      if #s > widths[col] then widths[col] = #s end
    end
  end
  return widths
end

-- Shared status-line builder used by render_page, set_cancelled_status, and the spinner.
-- `overrides` is a table of { item_name = value | nil } that replace the default logic.
-- Items not in overrides fall back to their normal value.  Returns (status_string, hl_marks).
local function render_status_line(overrides, cancelled_items)
  overrides = overrides or {}
  cancelled_items = cancelled_items or {}
  local dbout_style = (config.style and config.style.dbout) or {}
  local sections = dbout_style.sections or {
    { "history" },
    { "pagination", sep = "  " },
    { "query_time", sep = "  —  " },
    { "connection", sep = "  ·  " },
  }

  local status   = ""
  local hl_marks = {}
  local has_items = false
  for _, sec in ipairs(sections) do
    local item = sec[1]
    local value
    if overrides[item] ~= nil then
      value = overrides[item]  -- explicit override (false = skip)
      if value == false then value = nil end
    elseif item == "connection" then
      value = state.active_conn and state.active_conn.name or "no connection"
    elseif item == "binds_file" then
      if vim.fn.filereadable(binds_mod.file_path()) == 1 then value = "binds" end
    elseif item == "history" then
      if #state.history > 1 then
        value = string.format("◀ %d/%d ▶", state.history_idx, #state.history)
      end
    end
    if value then
      if has_items then
        local sep = sec.sep or "  ·  "
        local sep_col = #status
        status = status .. sep
        table.insert(hl_marks, { col = sep_col, end_col = #status, hl = "DbliteStatusPage" })
      end
      local col = #status
      status = status .. value
      local hl = cancelled_items[item] and "DbliteCancelled" or (sec.hl or "DbliteStatusPage")
      table.insert(hl_marks, { col = col, end_col = #status, hl = hl })
      has_items = true
    end
  end
  return status, hl_marks
end

-- Setting 'filetype' fires every FileType autocmd and re-runs the syntax
-- engine, so only touch it when the renderer actually changed dialects.
local function set_dbout_filetype(bufnr, ft)
  ft = ft or ""
  if state.dbout_filetype == ft then return end
  state.dbout_filetype = ft
  vim.bo[bufnr].filetype = ft
end

-- Writes `lines` into dbout and re-applies the status-line highlights, whose
-- columns are offset by whatever prefix the caller put in front of the status.
local function paint(bufnr, lines, hl_marks, offset)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, m in ipairs(hl_marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, m.col + (offset or 0),
      { end_col = m.end_col + (offset or 0), hl_group = m.hl })
  end
end

-- The json/text renderers: one value, drawn whole.
--
-- There is nothing to paginate — the result is a single cell — so the status
-- line reports the value's size instead of a page count. In json mode it is
-- written as a `//` comment so that the buffer as a whole stays valid jsonc
-- and highlights rather than showing one long error.
local function render_document()
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local cfg   = output_cfg()
  local col   = state.columns[1]
  local row   = state.rows[1]
  local value = (col and row) and row[col] or nil
  local raw   = (value == nil or value == vim.NIL) and "" or tostring(value)

  local body, ft
  if state.render_mode == "json" then
    body = json_fmt.format(raw, cfg.json_indent or 2) or raw
    ft   = cfg.json_filetype or "jsonc"
  else
    body = raw
    ft   = opt("filetype") or ""
  end

  local body_lines = vim.split(body, "\n", { plain = true })
  local status, hl_marks = render_status_line({
    pagination = string.format("(%s, %d line%s)",
      state.render_mode, #body_lines, #body_lines == 1 and "" or "s"),
    query_time = state.last_elapsed and string.format("%.3fs", state.last_elapsed) or nil,
  })

  local prefix = state.render_mode == "json" and "// " or ""
  local lines  = { prefix .. status, "" }
  vim.list_extend(lines, body_lines)

  set_dbout_filetype(bufnr, ft)
  paint(bufnr, lines, hl_marks, #prefix)
end

local function render_page()
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  if state.render_mode == "json" or state.render_mode == "text" then
    return render_document()
  end
  set_dbout_filetype(bufnr, opt("filetype") or "")

  local total = #state.rows
  local page_size = opt("page_size") or 100
  local total_pages = math.max(1, math.ceil(total / page_size))
  if state.page > total_pages then state.page = total_pages end
  if state.page < 1 then state.page = 1 end

  local start_row = (state.page - 1) * page_size + 1
  local end_row = math.min(start_row + page_size - 1, total)

  local lines = {}
  local status, hl_marks = render_status_line({
    pagination = total == 0 and "(no rows)" or string.format("(%d/%d)", state.page, total_pages),
    query_time = state.last_elapsed and string.format("%.3fs", state.last_elapsed) or nil,
  })
  table.insert(lines, status)
  table.insert(lines, "")

  if total == 0 then
    paint(bufnr, lines, hl_marks)
    return
  end

  local types_visible = state.show_types
  if types_visible == nil then types_visible = opt("show_column_types") end
  local type_hl = (config.style and config.style.dbout and config.style.dbout.column_type_hl)
    or "DbliteColumnType"

  -- Compute effective widths: if types are shown, widen columns to fit header + type
  local eff_widths = {}
  for i, col in ipairs(state.columns) do
    local w = state.widths[col]
    if types_visible and state.column_types[i] and state.column_types[i] ~= "" then
      local header_w = #col + 2 + #state.column_types[i] + 1  -- "COL [TYPE]"
      if header_w > w then w = header_w end
    end
    eff_widths[col] = w
  end

  local header_line = ""
  local type_marks = {}
  for i, col in ipairs(state.columns) do
    if i > 1 then header_line = header_line .. " | " end
    local col_start = #header_line
    if types_visible and state.column_types[i] and state.column_types[i] ~= "" then
      local type_str = " [" .. state.column_types[i] .. "]"
      header_line = header_line .. cell(col .. type_str, eff_widths[col])
      local mark_start = col_start + #col
      local mark_end = math.min(col_start + #col + #type_str, col_start + eff_widths[col])
      if mark_start < mark_end then
        table.insert(type_marks, { col = mark_start, end_col = mark_end })
      end
    else
      header_line = header_line .. cell(col, eff_widths[col])
    end
  end
  table.insert(lines, header_line)

  local sep_parts = {}
  for _, col in ipairs(state.columns) do
    table.insert(sep_parts, string.rep("-", eff_widths[col]))
  end
  table.insert(lines, table.concat(sep_parts, "-+-"))

  for i = start_row, end_row do
    local row = state.rows[i]
    local parts = {}
    for _, col in ipairs(state.columns) do
      table.insert(parts, cell(row[col], eff_widths[col]))
    end
    table.insert(lines, table.concat(parts, " | "))
  end

  paint(bufnr, lines, hl_marks)

  -- Highlight type annotations on the header line (line index 2 = third line)
  local header_row = 2
  for _, tm in ipairs(type_marks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, header_row, tm.col,
      { end_col = tm.end_col, hl_group = type_hl })
  end
end

local function set_status(text)
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- A lone status line is never a document, so drop any json dialect the last
  -- result left behind rather than highlighting "running..." as broken JSON.
  set_dbout_filetype(bufnr, opt("filetype") or "")
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
  vim.bo[bufnr].modifiable = false
end

local function restore_history(idx)
  if idx < 1 or idx > #state.history then return end
  local entry = state.history[idx]
  state.history_idx  = idx
  state.columns      = entry.columns
  state.column_types = entry.column_types or {}
  state.rows         = entry.rows
  state.widths       = entry.widths
  state.raw_json     = entry.raw_json
  state.last_elapsed = entry.last_elapsed
  state.render_mode  = entry.render_mode or "grid"
  state.page         = 1
  if entry.update_count then
    local msg = string.format("-- %d row(s) affected  (%.2fs)", entry.update_count, entry.last_elapsed)
    set_status(msg)
  else
    render_page()
  end
end

local function set_cancelled_status(elapsed)
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local status, hl_marks = render_status_line(
    { pagination = "cancelled", query_time = string.format("%.3fs", elapsed) },
    { pagination = true, query_time = true }
  )
  paint(bufnr, { status }, hl_marks)
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function stop_spinner()
  if state.spinner_timer then
    state.spinner_timer:stop()
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
end

local function start_spinner()
  stop_spinner()
  local idx = 1
  state.spinner_start = vim.uv.now()
  local timer = vim.uv.new_timer()
  timer:start(0, 80, vim.schedule_wrap(function()
    if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then
      stop_spinner()
      return
    end
    local elapsed = (vim.uv.now() - state.spinner_start) / 1000
    local bufnr = state.result_bufnr
    local status, hl_marks = render_status_line({
      pagination = string.format("%s  %.1fs", SPINNER[idx], elapsed),
      query_time = false,
    })
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { status })
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, m in ipairs(hl_marks) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, m.col, { end_col = m.end_col, hl_group = m.hl })
    end
    idx = (idx % #SPINNER) + 1
  end))
  state.spinner_timer = timer
end

local function clear_flash()
  if state.flash_bufnr and vim.api.nvim_buf_is_valid(state.flash_bufnr) then
    vim.api.nvim_buf_clear_namespace(state.flash_bufnr, flash_ns, 0, -1)
  end
  state.flash_bufnr = nil
end

local function set_flash(bufnr, sr, sc, er, ec)
  clear_flash()
  state.flash_bufnr = bufnr
  local end_row = (ec == 0 and er > sr) and er - 1 or er
  local lines = vim.api.nvim_buf_get_lines(bufnr, sr, end_row + 1, false)
  for i, line in ipairs(lines) do
    vim.api.nvim_buf_set_extmark(bufnr, flash_ns, sr + i - 1, 0, {
      end_col  = #line,
      hl_group = "DbliteFlash",
      hl_eol   = true,
    })
  end
  local timeout = config.flash_timeout or 2000
  if timeout > 0 then
    vim.defer_fn(clear_flash, timeout)
  end
end

local _saved_cancel_map = nil

local function set_global_cancel_keymap()
  local existing = vim.fn.maparg("<C-c>", "n", false, true)
  _saved_cancel_map = (existing and existing.lhs ~= nil) and existing or nil
  vim.keymap.set("n", "<C-c>", function()
    if state.current_job then
      pcall(function() state.current_job:kill(15) end)
      stop_spinner()
      clear_flash()
      if state.result_bufnr and vim.api.nvim_buf_is_valid(state.result_bufnr) then
        set_status("cancelling...")
      end
    end
  end, { desc = "dblite: cancel in-flight query" })
end

local function clear_global_cancel_keymap()
  pcall(vim.keymap.del, "n", "<C-c>")
  if _saved_cancel_map then
    vim.fn.mapset("n", false, _saved_cancel_map)
  end
  _saved_cancel_map = nil
end

local function configure_result_buffer(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  state.dbout_filetype = nil
  set_dbout_filetype(bufnr, opt("filetype") or "")

  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end

  local km = (config.keymaps and config.keymaps.dbout) or {}

  map(km.next, function()
    state.page = state.page + 1
    render_page()
  end, "dblite: next page")

  map(km.prev, function()
    state.page = state.page - 1
    render_page()
  end, "dblite: prev page")

  map(km.cancel, function()
    if state.current_job then
      pcall(function() state.current_job:kill(15) end)
      stop_spinner()
      clear_flash()
      set_status("cancelling...")
    end
  end, "dblite: cancel query")

  map(km.inspect or "gi", function()
    M.inspect()
  end, "dblite: inspect current page")

  map(km.history_prev or "[", function()
    if state.history_idx > 1 then
      restore_history(state.history_idx - 1)
    end
  end, "dblite: previous history entry")

  map(km.history_next or "]", function()
    if state.history_idx < #state.history then
      restore_history(state.history_idx + 1)
    end
  end, "dblite: next history entry")

  map(km.hover_query or "K", function()
    local entry = state.history[state.history_idx]
    if not entry or not entry.query_text then
      vim.notify("dblite: no query in history", vim.log.levels.INFO)
      return
    end
    local lines = vim.split(entry.query_text, "\n", { plain = true })
    vim.lsp.util.open_floating_preview(lines, "sql", {
      border = "rounded",
      focus_id = "dblite_query_hover",
    })
  end, "dblite: hover query")

  map(km.toggle_types or "d", function()
    local cur = state.show_types
    if cur == nil then cur = opt("show_column_types") end
    state.show_types = not cur
    render_page()
  end, "dblite: toggle column types")

  map(km.toggle_dbout, function()
    M.toggle_dbout()
  end, "dblite: toggle result window")

  map(km.cycle_split, function()
    M.cycle_split()
  end, "dblite: flip result window split")

  map(km.cycle_output or "go", function()
    M.cycle_output()
  end, "dblite: cycle result rendering")

  local ek = (config.keymaps and config.keymaps.editor) or {}
  map(ek.fullscreen or "<leader>l", function()
    M.toggle_fullscreen()
  end, "dblite: toggle fullscreen")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if state.current_job then
        pcall(function() state.current_job:kill(15) end)
      end
      state.result_bufnr = nil
    end,
  })
end

local function apply_dbout_win_style(winnr)
  local st = (config.style and config.style.dbout) or {}
  vim.wo[winnr].cursorline = st.cursorline == true
end

-- ── dbout placement ────────────────────────────────────────────────────────
-- The placement is live state, not just config: `:DbliteSplit right` moves the
-- result window mid-session, and toggling it away and back keeps both the
-- direction and the size it was last left at. Both persist across restarts.

local ui_state_path = vim.fn.stdpath("data") .. "/dblite/ui.json"

local function load_ui_state()
  local f = io.open(ui_state_path, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  if raw == "" then return end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return end
  -- Before 0.8 this was a single string for every connection. Keep reading
  -- that shape, as the generic default it effectively was.
  if type(data.split_dir) == "string" and split_cmds[data.split_dir] then
    state.split_dir = { _default = data.split_dir }
  elseif type(data.split_dir) == "table" then
    state.split_dir = {}
    for t, dir in pairs(data.split_dir) do
      if type(dir) == "string" and split_cmds[dir] then state.split_dir[t] = dir end
    end
  end
  if type(data.split_size) == "table" then
    state.split_size = data.split_size
  end
end

local function save_ui_state()
  local ok = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(ui_state_path, ":h"), "p")
    local f = assert(io.open(ui_state_path, "w"))
    f:write(vim.json.encode({
      split_dir  = state.split_dir,
      split_size = state.split_size,
    }))
    f:close()
  end)
  return ok
end

-- The placement in effect right now, most specific first: what `:DbliteSplit`
-- set for this connection type, then `config.types.<type>.split_dir`, then the
-- generic session override, then `config.split_dir`, then a right-hand split.
-- The per-type config outranks the generic session override on purpose: having
-- moved dbout once with no connection active should not silently defeat a
-- placement the user configured for Redis.
local function current_split_dir()
  local live = state.split_dir or {}
  local dir = live[conn_type()]
    or ((config.types or {})[conn_type()] or {}).split_dir
    or live._default
    or config.split_dir
    or "vertical"
  return split_cmds[dir] and dir or "vertical"
end

-- Size for a placement: what the user last dragged it to, else the configured
-- default. 0 or nil means "let nvim decide".
local function split_size_for(dir)
  local axis = split_axis[dir]
  if not axis then return nil end
  local remembered = state.split_size and state.split_size[axis]
  if remembered and remembered > 0 then return axis, remembered end
  local configured = (opt("split_size") or {})[axis]
  if configured and configured > 0 then return axis, configured end
  return axis, nil
end

-- Captures the size of a dbout window before it goes away, so bringing it back
-- restores the size rather than snapping to the default.
local function remember_dbout_size(winnr)
  if not winnr or not vim.api.nvim_win_is_valid(winnr) then return end
  local axis = split_axis[current_split_dir()]
  if not axis then return end
  state.split_size = state.split_size or {}
  state.split_size[axis] = axis == "width"
    and vim.api.nvim_win_get_width(winnr)
    or  vim.api.nvim_win_get_height(winnr)
end

-- Hides every window showing dbout, remembering the size on the way out.
local function hide_dbout_windows()
  local bufnr = state.result_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then remember_dbout_size(wins[1]) end
  for _, winnr in ipairs(wins) do
    pcall(vim.api.nvim_win_hide, winnr)
  end
end

-- Sizes the current window for `dir` and pins that axis. Without the pin,
-- 'winwidth'/'winheight' quietly claw columns back from dbout the moment the
-- cursor returns to a now-narrow editor window, so a restored size would drift.
local function size_dbout_win(dir)
  local axis, size = split_size_for(dir)
  if axis == "width" then
    if size then vim.api.nvim_win_set_width(0, size) end
    vim.wo.winfixwidth = true
  elseif axis == "height" then
    if size then vim.api.nvim_win_set_height(0, size) end
    vim.wo.winfixheight = true
  end
end

-- Opens dbout at the current placement and leaves the cursor where it was.
-- `bufnr` nil means the split's own fresh buffer becomes the result buffer.
local function open_dbout_win(bufnr)
  local dir = current_split_dir()
  vim.cmd(split_cmds[dir])
  if bufnr then vim.api.nvim_win_set_buf(0, bufnr) end

  size_dbout_win(dir)

  apply_dbout_win_style(0)
  local winnr = vim.api.nvim_get_current_win()
  vim.cmd("wincmd p")
  return winnr
end

load_ui_state()

local function ensure_result_buffer()
  if state.result_bufnr and vim.api.nvim_buf_is_valid(state.result_bufnr) then
    local bufnr = state.result_bufnr
    local wins = vim.fn.win_findbuf(bufnr)
    local current_tab = vim.api.nvim_get_current_tabpage()
    local tab_wins = vim.api.nvim_tabpage_list_wins(current_tab)
    local tab_win_set = {}
    for _, w in ipairs(tab_wins) do tab_win_set[w] = true end
    local visible_in_tab = false
    for _, w in ipairs(wins) do
      if tab_win_set[w] then visible_in_tab = true; break end
    end
    if not visible_in_tab then
      -- close dbout windows in other tabs before opening here
      hide_dbout_windows()
      open_dbout_win(bufnr)
    end
    return bufnr
  end

  local dir = current_split_dir()
  vim.cmd(split_cmds[dir])
  local bufnr = vim.api.nvim_get_current_buf()
  configure_result_buffer(bufnr)

  size_dbout_win(dir)

  apply_dbout_win_style(0)
  vim.cmd("wincmd p")
  state.result_bufnr = bufnr
  return bufnr
end

-- Render a script-mode run (per-statement OK/ERROR log) into the result buffer.
local function render_script_log(parsed, elapsed)
  if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end
  local results = parsed.results or {}
  local total   = parsed.total or #results
  local lines   = {}
  if (parsed.failed or 0) > 0 then
    table.insert(lines, string.format(
      "-- dblite script: FAILED at statement %d/%d  (%.2fs)",
      parsed.executed + 1, total, elapsed))
  else
    table.insert(lines, string.format(
      "-- dblite script: %d/%d statement(s) OK  (%.2fs)",
      parsed.executed or 0, total, elapsed))
  end
  table.insert(lines, "")
  for _, r in ipairs(results) do
    if r.ok then
      local detail = (r.update_count ~= nil and r.update_count >= 0)
        and string.format(" (%d row(s))", r.update_count) or ""
      table.insert(lines, string.format("[%d] OK    %s%s", r.index, r.preview or "", detail))
    else
      table.insert(lines, string.format("[%d] ERROR %s", r.index, r.preview or ""))
      for _, el in ipairs(vim.split(tostring(r.error or ""), "\n", { plain = true })) do
        table.insert(lines, "        " .. el)
      end
    end
  end
  local ran = #results
  if ran < total then
    table.insert(lines, "")
    table.insert(lines, string.format("-- stopped: %d statement(s) not run", total - ran))
  end
  vim.bo[state.result_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.result_bufnr, 0, -1, false, lines)
  vim.bo[state.result_bufnr].modifiable = false
end

-- True when the active source is one command per line rather than
-- terminator-delimited. Redis has no statement terminator, so the SQL
-- blank-line/semicolon heuristic would fold every following command into one.
local function line_oriented()
  return state.active_conn ~= nil and state.active_conn.type == "redis"
end

-- Counts the runnable lines in a line-oriented buffer (blanks and # comments
-- do not count), so a whole-buffer run knows whether it is one command or many.
local function runnable_line_count(bufnr)
  local n = 0
  for _, ln in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local t = vim.trim(ln)
    if t ~= "" and t:sub(1, 1) ~= "#" then n = n + 1 end
  end
  return n
end

local function execute_core(query, script)
  if vim.fn.executable(config.binary) ~= 1 then
    local hint = _plugin_root
      and "run :DbliteBuild to compile the native binary"
      or  "binary 'dblite' not found on PATH — run the build first"
    vim.notify("dblite: " .. hint, vim.log.levels.ERROR)
    return
  end

  if not state.active_conn then
    vim.notify("dblite: no active connection — use :DbliteUseConn <name>", vim.log.levels.ERROR)
    return
  end

  if state.current_job then
    pcall(function() state.current_job:kill(15) end)
    state.current_job = nil
  end

  local bind_names = binds_mod.names_for(state.active_conn, query)

  local function do_run(q)
    state.last_elapsed = nil
    state.raw_json     = nil
    ensure_result_buffer()
    start_spinner()

  local cmd = { config.binary }
  if script then
    table.insert(cmd, "--script")
  elseif config.max_rows and config.max_rows > 0 then
    table.insert(cmd, "--max-rows")
    table.insert(cmd, tostring(config.max_rows))
  end

  local c = state.active_conn
  local sys_env = connections.env(c)

  set_global_cancel_keymap()

  local job
  job = vim.system(cmd, { stdin = q, text = true, env = sys_env }, function(result)
    vim.schedule(function()
      if state.current_job ~= job then return end
      state.current_job = nil
      clear_global_cancel_keymap()
      local elapsed = (vim.uv.now() - state.spinner_start) / 1000
      stop_spinner()
      clear_flash()

      if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end

      if result.signal ~= 0 then
        set_cancelled_status(elapsed)
        return
      end

      if result.code ~= 0 then
        local err_lines = vim.split("-- dblite failed: " .. (result.stderr or ""), "\n", { plain = true })
        vim.bo[state.result_bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(state.result_bufnr, 0, -1, false, err_lines)
        vim.bo[state.result_bufnr].modifiable = false
        return
      end

      local ok, parsed = pcall(vim.json.decode, result.stdout)
      if not ok or type(parsed) ~= "table" then
        set_status("-- dblite: failed to parse JSON: " .. tostring(parsed))
        return
      end

      if parsed.script then
        render_script_log(parsed, elapsed)
        return
      end

      if parsed.update_count ~= nil then
        local uc = parsed.update_count
        local msg
        if uc < 0 then
          msg = string.format("-- statement executed  (%.2fs)", elapsed)
        else
          msg = string.format("-- %d row(s) affected  (%.2fs)", uc, elapsed)
        end
        set_status(msg)
        local max_hist = config.max_history or 20
        table.insert(state.history, {
          columns      = {},
          column_types = {},
          rows         = {},
          widths       = {},
          raw_json     = result.stdout,
          last_elapsed = elapsed,
          conn_name    = state.active_conn and state.active_conn.name or nil,
          query_text   = q,
          update_count = parsed.update_count,
        })
        if max_hist > 0 and #state.history > max_hist then
          table.remove(state.history, 1)
        end
        state.history_idx = #state.history
        return
      end

      state.columns      = parsed.columns      or {}
      state.column_types = parsed.column_types or {}
      state.rows         = parsed.rows         or {}
      state.widths       = compute_widths(state.rows, state.columns)
      state.page         = 1
      state.last_elapsed = elapsed
      state.raw_json     = result.stdout
      -- Pick the renderer for this result. show_result does the same for a
      -- watch's snapshot; without it here, a query typed in a buffer — the
      -- common path — would always draw as a grid.
      state.render_mode  = output.resolve(parsed, {
        query  = q,
        forced = state.forced_mode,
        cfg    = output_cfg(),
      })

      local max_hist = config.max_history or 20
      table.insert(state.history, {
        columns      = state.columns,
        column_types = state.column_types,
        rows         = state.rows,
        widths       = state.widths,
        render_mode  = state.render_mode,
        raw_json     = state.raw_json,
        last_elapsed = state.last_elapsed,
        conn_name    = state.active_conn and state.active_conn.name or nil,
        query_text   = q,
      })
      if max_hist > 0 and #state.history > max_hist then
        table.remove(state.history, 1)
      end
      state.history_idx = #state.history

      render_page()
      if state.result_bufnr and #vim.fn.win_findbuf(state.result_bufnr) == 0 then
        vim.notify("dblite: results ready — toggle dbout to view", vim.log.levels.INFO)
      end
    end)
  end)
  state.current_job = job
  end -- do_run

  if #bind_names > 0 then
    local file_binds = binds_mod.flatten(binds_mod.load_file())
    local missing = vim.tbl_filter(
      function(n) return file_binds[n] == nil end, bind_names)
    if #missing > 0 then
      vim.notify(
        "dblite: missing bind params: " .. table.concat(missing, ", ")
        .. "\nAdd them to dblite.binds.json and re-run.",
        vim.log.levels.WARN)
      M.open_binds()
      return
    end
    do_run(binds_mod.apply(query, file_binds))
  else
    do_run(query)
  end
end

-- Push a result produced outside the normal run path — currently a watch's
-- latest snapshot — into the result window as if it had just been run. It goes
-- through the same history ring as everything else, so paging, `gi` inspect,
-- export and `[`/`]` navigation work on it unchanged.
--
--   res   a `dblite.inline` result (columns, column_types, rows, json, elapsed)
--   opts  { query = <sql shown on hover>, conn = <connection name> }
function M.show_result(res, opts)
  if not res then return end
  opts = opts or {}
  ensure_result_buffer()

  state.columns      = res.columns      or {}
  state.column_types = res.column_types or {}
  state.rows         = res.rows         or {}
  state.widths       = compute_widths(state.rows, state.columns)
  state.page         = 1
  state.last_elapsed = res.elapsed
  state.raw_json     = res.json
  state.render_mode  = output.resolve(res, {
    query  = opts.query,
    forced = state.forced_mode,
    cfg    = output_cfg(),
  })

  local max_hist = config.max_history or 20
  table.insert(state.history, {
    columns      = state.columns,
    column_types = state.column_types,
    rows         = state.rows,
    widths       = state.widths,
    render_mode  = state.render_mode,
    raw_json     = state.raw_json,
    last_elapsed = state.last_elapsed,
    conn_name    = opts.conn,
    query_text   = opts.query,
    update_count = res.update_count,
  })
  if max_hist > 0 and #state.history > max_hist then
    table.remove(state.history, 1)
  end
  state.history_idx = #state.history

  if res.update_count ~= nil then
    set_status(string.format("-- %d row(s) affected  (%.2fs)",
      res.update_count, res.elapsed or 0))
  else
    render_page()
  end
end

-- --- Watches --------------------------------------------------------------

-- Shared tail of M.watch / M.watch_file: freeze the statement's binds against
-- the active connection, then either start straight away (a spec was given) or
-- open the popup first. Binds are resolved here, once, so editing
-- dblite.binds.json while a watch is polling never changes what it runs.
local function start_watch(query, label, spec_str)
  if vim.fn.executable(config.binary) ~= 1 then
    local hint = _plugin_root
      and "run :DbliteBuild to compile the native binary"
      or  "binary 'dblite' not found on PATH — run the build first"
    vim.notify("dblite: " .. hint, vim.log.levels.ERROR)
    return
  end
  if not state.active_conn then
    vim.notify("dblite: no active connection — use :DbliteUseConn <name>", vim.log.levels.ERROR)
    return
  end

  local final_q    = query
  local bind_names = binds_mod.names_for(state.active_conn, query)
  if #bind_names > 0 then
    local file_binds = binds_mod.flatten(binds_mod.load_file())
    local missing = vim.tbl_filter(function(n) return file_binds[n] == nil end, bind_names)
    if #missing > 0 then
      vim.notify(
        "dblite: missing bind params: " .. table.concat(missing, ", ")
        .. "\nAdd them to dblite.binds.json and re-run.",
        vim.log.levels.WARN)
      M.open_binds()
      return
    end
    final_q = binds_mod.apply(query, file_binds)
  end

  local conn_name = state.active_conn.name

  local function launch(spec)
    local id, err = watch.start({
      sql               = final_q,
      conn              = conn_name,
      label             = label,
      every             = spec.every,
      max               = spec.max,
      cond              = spec.cond,
      stop_after_errors = spec.stop_after_errors,
    })
    if not id then
      vim.notify(tostring(err), vim.log.levels.ERROR)
      return
    end
    local w = watch.get(id)
    vim.notify(string.format("dblite: watching %s every %s until %s",
      label, watch.fmt_duration(w.every), w.cond.describe), vim.log.levels.INFO)
    if not (config.jobs and config.jobs.open_on_start == false) then
      jobs.open({ focus = false })
    end
  end

  if spec_str and spec_str:match("%S") then
    local spec, err = watch.parse_spec(spec_str)
    if not spec then
      vim.notify("dblite: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    launch(spec)
    return
  end

  if (config.watch or {}).prompt == false then
    launch({})
    return
  end

  watch.prompt({ label = label, sql = final_q }, function(spec)
    if spec then launch(spec) end
  end)
end

-- Watch the statement under the cursor (or the statements a range touches).
function M.watch(spec_str, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local sr, sc, er, ec, query
  local lines_only = line_oriented()
  if range then
    sr, sc, er, ec, query = query_module.at_range(bufnr, range.line1, range.line2, lines_only)
  else
    sr, sc, er, ec, query = query_module.at_cursor(bufnr, lines_only)
  end
  if not query or query:match("^%s*$") then
    vim.notify("dblite: no query at cursor", vim.log.levels.WARN)
    return
  end
  if sr then set_flash(bufnr, sr, sc, er, ec) end

  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  local label = name ~= "" and (name .. ":" .. (sr + 1)) or query:gsub("%s+", " "):sub(1, 32)
  start_watch(query, label, spec_str)
end

-- Watch the whole buffer as one statement.
function M.watch_file(spec_str)
  local bufnr = vim.api.nvim_get_current_buf()
  local query = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if query:match("^%s*$") then
    vim.notify("dblite: buffer is empty", vim.log.levels.WARN)
    return
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  start_watch(query, name ~= "" and name or "buffer", spec_str)
end

-- Watch the current visual selection.
function M.watch_visual()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd("normal! \27")  -- <Esc>: leave visual mode before any popup
  M.watch(nil, { line1 = math.min(a, b), line2 = math.max(a, b) })
end

function M.execute()
  local bufnr = vim.api.nvim_get_current_buf()
  local query = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  -- For a line-oriented source a multi-command buffer *is* a script: running it
  -- as one statement would concatenate the commands into nonsense.
  local script = line_oriented() and runnable_line_count(bufnr) > 1
  execute_core(query, script or nil)
end

function M.execute_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local sr, sc, er, ec, query = query_module.at_cursor(bufnr, line_oriented())
  if not sr or not query or query:match("^%s*$") then
    vim.notify("dblite: no query at cursor", vim.log.levels.WARN)
    return
  end
  set_flash(bufnr, sr, sc, er, ec)
  execute_core(query)
end

-- Run a whole SQL*Plus-style script: many statements (PL/SQL blocks terminated
-- by a lone "/", plain statements by ";") executed in order on one connection.
function M.execute_script(opts)
  local first, last
  if opts and opts.range and opts.range > 0 then
    first, last = opts.line1, opts.line2
  else
    first, last = 1, vim.api.nvim_buf_line_count(0)
  end
  local query = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
  if query:match("^%s*$") then
    vim.notify("dblite: nothing to run", vim.log.levels.WARN)
    return
  end
  execute_core(query, true)
end

-- Run the query at the cursor (or, failing that, the whole buffer) as a
-- background bulk export: the native binary streams the full result set
-- straight to `path` (no --max-rows cap, no in-editor buffering) while the
-- user keeps working. Progress shows in the jobs panel (:DbliteJobs).
function M.run_async(format, path, range)
  format = (format or (config.jobs and config.jobs.default_format) or "csv"):lower()
  if format ~= "csv" and format ~= "json" then
    vim.notify("dblite: bulk format must be 'csv' or 'json'", vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable(config.binary) ~= 1 then
    local hint = _plugin_root
      and "run :DbliteBuild to compile the native binary"
      or  "binary 'dblite' not found on PATH — run the build first"
    vim.notify("dblite: " .. hint, vim.log.levels.ERROR)
    return
  end

  if not state.active_conn then
    vim.notify("dblite: no active connection — use :DbliteUseConn <name>", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local sr, sc, er, ec, query
  local lines_only = line_oriented()
  if range then
    -- Visual/range invocation: dump exactly the statement(s) the selection touches.
    sr, sc, er, ec, query = query_module.at_range(bufnr, range.line1, range.line2, lines_only)
    if not query or query:match("^%s*$") then
      vim.notify("dblite: nothing to run in selection", vim.log.levels.WARN)
      return
    end
  else
    sr, sc, er, ec, query = query_module.at_cursor(bufnr, lines_only)
    if not query or query:match("^%s*$") then
      query = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      sr = nil
    end
    if query:match("^%s*$") then
      vim.notify("dblite: nothing to run", vim.log.levels.WARN)
      return
    end
  end

  -- Resolve binds before we prompt for a path, so missing binds fail fast.
  local final_q = query
  local bind_names = binds_mod.names_for(state.active_conn, query)
  if #bind_names > 0 then
    local file_binds = binds_mod.flatten(binds_mod.load_file())
    local missing = vim.tbl_filter(function(n) return file_binds[n] == nil end, bind_names)
    if #missing > 0 then
      vim.notify(
        "dblite: missing bind params: " .. table.concat(missing, ", ")
        .. "\nAdd them to dblite.binds.json and re-run.",
        vim.log.levels.WARN)
      M.open_binds()
      return
    end
    final_q = binds_mod.apply(query, file_binds)
  end

  if not path or path == "" then
    local default = "dblite_bulk." .. format
    path = vim.fn.input({ prompt = "Bulk export to: ", default = default, completion = "file" })
    if path == "" then
      vim.notify("dblite: bulk export cancelled", vim.log.levels.INFO)
      return
    end
  end
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local existing = vim.uv.fs_stat(path)
  if existing and existing.type == "directory" then
    vim.notify("dblite: bulk export target is a directory: " .. path, vim.log.levels.ERROR)
    return
  end
  if existing then
    local choice = vim.fn.confirm("Overwrite existing file?\n\n" .. path, "&Yes\n&No", 2)
    if choice ~= 1 then
      vim.notify("dblite: bulk export cancelled", vim.log.levels.INFO)
      return
    end
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  if sr then set_flash(bufnr, sr, sc, er, ec) end

  local c = state.active_conn
  local sys_env = connections.env(c)

  local cmd = { config.binary, "--to-file", path, "--format", format }

  local id = jobs.register({
    label     = vim.fn.fnamemodify(path, ":t"),
    path      = path,
    format    = format,
    conn_name = c.name,
    query     = query,
  })

  local job
  job = vim.system(cmd, { stdin = final_q, text = true, env = sys_env }, function(result)
    vim.schedule(function()
      if result.signal ~= 0 then
        jobs.finish(id, { status = "cancelled" })
        return
      end
      if result.code ~= 0 then
        jobs.finish(id, { status = "error", error = (result.stderr or ""):gsub("%s+$", "") })
        vim.notify("dblite: bulk export failed — " .. (result.stderr or ""), vim.log.levels.ERROR)
        return
      end
      local ok, parsed = pcall(vim.json.decode, result.stdout)
      local rows
      if ok and type(parsed) == "table" then
        rows = parsed.rows or parsed.update_count
      end
      jobs.finish(id, { status = "done", rows = rows })
      vim.notify(string.format("dblite: bulk export finished — %s row(s) → %s",
        rows ~= nil and tostring(rows) or "?", path), vim.log.levels.INFO)
    end)
  end)
  jobs.set_handle(id, job)

  if not (config.jobs and config.jobs.open_on_start == false) then
    jobs.open({ focus = false })
  end
  vim.notify("dblite: bulk export started → " .. path, vim.log.levels.INFO)
end

-- Bulk-export the current visual selection (bound to the `run_bulk` key in
-- visual mode). Reads the selected line range, leaves visual mode, then dumps
-- the statement(s) it touches at the configured default format.
function M.run_bulk_visual()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd("normal! \27")  -- <Esc>: exit visual mode before any prompt/split
  M.run_async(nil, nil, { line1 = math.min(a, b), line2 = math.max(a, b) })
end

-- Jobs panel public API
M.toggle_jobs = jobs.toggle
M.open_jobs   = jobs.open
M.close_jobs  = jobs.close
M.is_jobs_open = jobs.is_open

vim.api.nvim_create_user_command("DbliteRun",   M.execute,           {})
vim.api.nvim_create_user_command("DbliteRunAt", M.execute_at_cursor, {})
vim.api.nvim_create_user_command("DbliteRunScript", M.execute_script, { range = true })

-- :DbliteRunBulk <csv|json> [path] — run the current query as a background dump.
-- With a range (e.g. :'<,'>DbliteRunBulk csv) it dumps the selected statement(s).
vim.api.nvim_create_user_command("DbliteRunBulk", function(opts)
  local fmt  = opts.fargs[1]
  local path = opts.fargs[2] and table.concat(vim.list_slice(opts.fargs, 2), " ") or nil
  local range = (opts.range and opts.range > 0) and { line1 = opts.line1, line2 = opts.line2 } or nil
  M.run_async(fmt, path, range)
end, {
  nargs = "*",
  range = true,
  complete = function(arg_lead, cmd_line)
    local n = #vim.split(cmd_line, "%s+")
    if n <= 2 then
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end, { "csv", "json" })
    end
    return vim.fn.getcompletion(arg_lead, "file")
  end,
})

vim.api.nvim_create_user_command("DbliteJobs", function() jobs.toggle() end, {})

-- :DbliteWatch [spec]  — watch the statement at the cursor (or a :'<,'> range).
-- With no spec the settings popup opens; with one it starts immediately:
--   :DbliteWatch 30s x50
--   :DbliteWatch every=2m until=rows>5
--   :DbliteWatch 1m for=1h until=STATUS=DONE
vim.api.nvim_create_user_command("DbliteWatch", function(opts)
  local range = (opts.range and opts.range > 0) and { line1 = opts.line1, line2 = opts.line2 } or nil
  M.watch(opts.args, range)
end, { nargs = "*", range = true })

vim.api.nvim_create_user_command("DbliteWatchFile", function(opts)
  M.watch_file(opts.args)
end, { nargs = "*" })

vim.api.nvim_create_user_command("DbliteWatchStop", function()
  local n = #watch.active()
  if n == 0 then
    vim.notify("dblite: no watches running", vim.log.levels.INFO)
    return
  end
  watch.stop_all()
  vim.notify("dblite: stopped " .. n .. " watch(es)", vim.log.levels.INFO)
end, {})

-- :DbliteBuild  — download a pre-built binary from GitHub Releases, or build
--                 from source if none matches the platform.
-- :DbliteBuild! — skip the download and always build from source (use when the
--                 local source is ahead of the latest release).
vim.api.nvim_create_user_command("DbliteBuild", function(opts)
  require("dblite.download").download_or_build({ force_build = opts.bang })
  -- Re-resolve binary path in case it was just created
  if _plugin_root then
    local bin = _plugin_root .. "/bin/dblite"
    if vim.fn.filereadable(bin) == 1 then
      config.binary = bin
    end
  end
end, { bang = true })

-- Returns sorted list of saved connection names (used for tab-completion).
local function conn_names()
  local names = {}
  for _, c in ipairs(connections.list()) do table.insert(names, c.name) end
  table.sort(names)
  return names
end

local function complete_name(arg_lead)
  local out = {}
  for _, n in ipairs(conn_names()) do
    if n:sub(1, #arg_lead) == arg_lead then table.insert(out, n) end
  end
  return out
end

-- Warms the completion cache a source actually has: a SQL catalog, or for
-- Redis the keyspace and command list.
local function prefetch_completion(conn)
  if not conn then return end
  if conn.type == "redis" then
    require("dblite.keyspace").prefetch(conn)
  else
    require("dblite.schema").prefetch(conn)
  end
end

local function invalidate_completion(conn_id)
  require("dblite.schema").invalidate(conn_id)
  require("dblite.keyspace").invalidate(conn_id)
end

local function edit_conn_by_name(name)
  local conn = connections.get_by_name(name)
  if not conn then
    vim.notify("dblite: connection '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  local function prompt(label, current)
    local v = vim.fn.input(label .. " [" .. tostring(current) .. "]: ")
    return v ~= "" and v or current
  end

  if conn.type == "sqlite" then
    local updates = {
      name = prompt("Name", conn.name),
      path = prompt("Path", conn.path),
    }
    local ok, result = pcall(connections.update, conn.id, updates)
    if not ok then
      vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    invalidate_completion(conn.id)
    if state.active_conn and state.active_conn.id == conn.id then
      state.active_conn = result
      prefetch_completion(result)
    end
    vim.notify("\ndblite: updated '" .. updates.name .. "'", vim.log.levels.INFO)
    panel.refresh()
    return
  end

  if conn.type == "redis" then
    -- Asked in the order they are shown in the panel; a value that will not
    -- parse keeps the current one rather than silently becoming a default.
    local updates = {
      name = prompt("Name", conn.name),
      host = prompt("Host", conn.host),
      port = tonumber(prompt("Port", conn.port or 6379)) or conn.port or 6379,
      db   = tonumber(prompt("Database index", conn.db or 0)) or conn.db or 0,
      user = prompt("User", conn.user or ""),
    }
    if updates.user == "" then updates.user = nil end
    local tls_s = prompt("TLS (y/n)", conn.tls and "y" or "n")
    updates.tls = (tostring(tls_s):lower():sub(1, 1) == "y") or nil
    local pw = vim.fn.inputsecret("Password (blank to keep, '-' to clear): ")
    if pw == "-" then
      updates.password = nil
    elseif pw ~= "" then
      updates.password = pw
    end
    local ok, result = pcall(connections.update, conn.id, updates)
    if not ok then
      vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    -- Host or database index may have changed, so the cached keyspace is stale.
    invalidate_completion(conn.id)
    if state.active_conn and state.active_conn.id == conn.id then
      state.active_conn = result
      prefetch_completion(result)
    end
    vim.notify("\ndblite: updated '" .. updates.name .. "'", vim.log.levels.INFO)
    panel.refresh()
    return
  end

  local default_port = conn.type == "sqlserver" and 1433 or 1521
  local db_label     = conn.type == "sqlserver" and "Database" or "Service"
  local db_current   = conn.type == "sqlserver" and conn.database or conn.service
  local db_val       = prompt(db_label, db_current or "")

  local updates = {
    name = prompt("Name", conn.name),
    host = prompt("Host", conn.host),
    port = tonumber(prompt("Port", conn.port or default_port)),
    user = prompt("User", conn.user),
  }
  if conn.type == "sqlserver" then
    updates.database = db_val
  else
    updates.service = db_val
  end
  local pw = vim.fn.inputsecret("Password (leave blank to keep): ")
  if pw ~= "" then updates.password = pw end

  local ok, result = pcall(connections.update, conn.id, updates)
  if not ok then
    vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  if state.active_conn and state.active_conn.id == conn.id then
    invalidate_completion(conn.id)
    state.active_conn = connections.get(conn.id)
    prefetch_completion(state.active_conn)
  end
  vim.notify("\ndblite: updated '" .. (updates.name or conn.name) .. "'", vim.log.levels.INFO)
  panel.refresh()
end

-- Sets the active connection, warms the completion cache, and refreshes the panel.
local function activate_conn(conn)
  state.active_conn = conn
  prefetch_completion(conn)
  vim.notify("dblite: using '" .. conn.name .. "'", vim.log.levels.INFO)
  panel.refresh()
end

panel.setup({
  get_state = function() return state end,
  on_edit   = function(name) edit_conn_by_name(name) end,
})

telescope.setup({
  get_state = function() return state end,
  on_select = function(conn) activate_conn(conn) end,
})

-- Opens the configured connection picker (telescope when enabled).
function M.pick_connection()
  telescope.pick()
end

vim.api.nvim_create_user_command("DbliteConnPicker", function()
  telescope.pick()
end, {})

-- :DbliteAddConn — interactive; optionally accepts a URI as first argument
-- URI formats include oracle://..., sqlserver://..., and sqlite:///absolute/path.
vim.api.nvim_create_user_command("DbliteAddConn", function(opts)
  local fields

  if opts.args ~= "" then
    local parsed, err = connections.parse_uri(opts.args)
    if not parsed then
      vim.notify("dblite: " .. err, vim.log.levels.ERROR)
      return
    end
    fields = parsed
  else
    -- Ask for URI first; blank means fall through to field-by-field
    local uri_input = vim.fn.input("URI (oracle://, sqlserver://, sqlite://, redis://) or blank for manual: ")
    if uri_input ~= "" then
      local parsed, err = connections.parse_uri(uri_input)
      if not parsed then
        vim.notify("\ndblite: " .. err, vim.log.levels.ERROR)
        return
      end
      fields = parsed
    end
  end

  local name = vim.fn.input("Connection name: ")
  if name == "" then return end

  if not fields then
    local type_s = vim.fn.input("Type [oracle/sqlserver/sqlite/redis]: ")
    type_s = type_s ~= "" and type_s or "oracle"
    if type_s ~= "oracle" and type_s ~= "sqlserver" and type_s ~= "sqlite" and type_s ~= "redis" then
      vim.notify("\ndblite: type must be 'oracle', 'sqlserver', 'sqlite', or 'redis'", vim.log.levels.ERROR)
      return
    end
    if type_s == "sqlite" then
      local path = vim.fn.input("Database path: ", "", "file")
      if path == "" then return end
      fields = { type = type_s, path = path }
    elseif type_s == "redis" then
      -- Everything but the host is optional: Redis is commonly unauthenticated.
      local host = vim.fn.input("Host [127.0.0.1]: ")
      host = host ~= "" and host or "127.0.0.1"
      local port_s = vim.fn.input("Port [6379]: ")
      local db_s   = vim.fn.input("Database index [0]: ")
      local user   = vim.fn.input("User (blank for none): ")
      local password = vim.fn.inputsecret("Password (blank for none, or $ENV_VAR): ")
      local tls_s  = vim.fn.input("TLS (rediss) [y/N]: ")
      fields = {
        type     = "redis",
        host     = host,
        port     = tonumber(port_s ~= "" and port_s or "6379"),
        db       = tonumber(db_s ~= "" and db_s or "0"),
        user     = user ~= "" and user or nil,
        password = password ~= "" and password or nil,
        tls      = (tls_s:lower():sub(1, 1) == "y") or nil,
      }
    else
      local default_port = type_s == "sqlserver" and "1433" or "1521"
      local host = vim.fn.input("Host: ")
      if host == "" then return end
      local port_s   = vim.fn.input("Port [" .. default_port .. "]: ")
      local db_label = type_s == "sqlserver" and "Database" or "Service"
      local db_val   = vim.fn.input(db_label .. ": ")
      if db_val == "" then return end
      local user     = vim.fn.input("User: ")
      if user == "" then return end
      local password = vim.fn.inputsecret("Password (or $ENV_VAR): ")
      fields = {
        type     = type_s,
        host     = host,
        port     = tonumber(port_s ~= "" and port_s or default_port),
        user     = user,
        password = password,
      }
      if type_s == "sqlserver" then
        fields.database = db_val
      else
        fields.service = db_val
      end
    end
  else
    -- URI path: password may be missing — give the user a chance to set it
    if fields.type ~= "sqlite" and fields.type ~= "redis" and (fields.password or "") == "" then
      fields.password = vim.fn.inputsecret("Password (or $ENV_VAR, leave blank to set later): ")
    end
  end

  fields.name = name
  local ok, result = pcall(connections.add, fields)
  if ok then
    vim.notify("\ndblite: saved connection '" .. name .. "'", vim.log.levels.INFO)
    panel.refresh()
  else
    vim.notify("\ndblite: " .. tostring(result), vim.log.levels.ERROR)
  end
end, { nargs = "?" })

-- :DbliteListConns — show all connections; active one is marked with *
vim.api.nvim_create_user_command("DbliteListConns", function()
  local conns = connections.list()
  if #conns == 0 then
    vim.notify("dblite: no connections saved. Use :DbliteAddConn", vim.log.levels.INFO)
    return
  end
  local lines = { "dblite connections:" }
  for _, c in ipairs(conns) do
    local active  = (state.active_conn and state.active_conn.id == c.id) and " *" or ""
    if c.type == "sqlite" then
      table.insert(lines, string.format("  %-20s  [%-10s]  %s%s",
        c.name, c.type, c.path or "?", active))
    elseif c.type == "redis" then
      table.insert(lines, string.format("  %-20s  [%-10s]  %s%s:%d/%d%s",
        c.name, c.type,
        (c.user and c.user ~= "") and (c.user .. "@") or "",
        c.host or "?", c.port or 6379, c.db or 0, active))
    else
      local db_val  = (c.type == "sqlserver") and c.database or c.service
      local default_port = (c.type == "sqlserver") and 1433 or 1521
      table.insert(lines, string.format(
        "  %-20s  [%-10s]  %s@%s:%d/%s%s",
        c.name, c.type or "oracle", c.user, c.host, c.port or default_port, db_val or "?", active
      ))
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, {})

-- :DbliteUseConn <name> — set the active connection for queries
vim.api.nvim_create_user_command("DbliteUseConn", function(opts)
  if opts.args == "" then
    local msg = state.active_conn
      and ("dblite: active connection: " .. state.active_conn.name)
      or  "dblite: no active connection"
    vim.notify(msg, vim.log.levels.INFO)
    return
  end
  local conn = connections.get_by_name(opts.args)
  if not conn then
    vim.notify("dblite: connection '" .. opts.args .. "' not found", vim.log.levels.ERROR)
    return
  end
  activate_conn(conn)
end, { nargs = "?", complete = complete_name })

-- :DbliteEditConn <name> — re-prompt each field (leave blank to keep current value)
vim.api.nvim_create_user_command("DbliteEditConn", function(opts)
  edit_conn_by_name(opts.args)
end, { nargs = 1, complete = complete_name })

-- :DbliteDeleteConn <name> — permanently remove a saved connection
vim.api.nvim_create_user_command("DbliteDeleteConn", function(opts)
  local conn = connections.get_by_name(opts.args)
  if not conn then
    vim.notify("dblite: connection '" .. opts.args .. "' not found", vim.log.levels.ERROR)
    return
  end
  if state.active_conn and state.active_conn.id == conn.id then
    state.active_conn = nil
  end
  connections.delete(conn.id)
  vim.notify("dblite: deleted '" .. conn.name .. "'", vim.log.levels.INFO)
  panel.refresh()
end, { nargs = 1, complete = complete_name })

function M.toggle_dbout()
  if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end
  if #vim.fn.win_findbuf(state.result_bufnr) > 0 then
    hide_dbout_windows()
    save_ui_state()   -- keep a size the user dragged to across restarts
  else
    open_dbout_win(state.result_bufnr)
  end
end

-- :DbliteSplit <right|left|below|above|tab> — move the result window now, and
-- remember the placement for the next toggle and the next session.
function M.set_split_dir(dir)
  dir = vim.trim(dir or "")
  if dir == "" then
    vim.notify("dblite: current split is '" .. current_split_dir() .. "'", vim.log.levels.INFO)
    return
  end
  if not split_cmds[dir] then
    vim.notify("dblite: split must be one of right, left, below, above, tab", vim.log.levels.ERROR)
    return
  end

  local was_open = state.result_bufnr
    and vim.api.nvim_buf_is_valid(state.result_bufnr)
    and #vim.fn.win_findbuf(state.result_bufnr) > 0

  if was_open then hide_dbout_windows() end
  state.split_dir = state.split_dir or {}
  state.split_dir[conn_type()] = dir
  save_ui_state()
  if was_open then
    open_dbout_win(state.result_bufnr)
    -- Column truncation depends on the window width, which just changed.
    state.widths = compute_widths(state.rows, state.columns)
    render_page()
  end
  vim.notify("dblite: split → " .. dir, vim.log.levels.INFO)
end

-- Flip between a right-hand and a below split. Long JSON values read better in
-- a tall narrow pane and wide result grids in a short wide one, so this is the
-- switch worth having on a key.
function M.cycle_split()
  local horizontal = split_axis[current_split_dir()] == "height"
  M.set_split_dir(horizontal and "right" or "below")
end

-- :DbliteOutput <auto|grid|json|text> — redraw the current result with a
-- different renderer, and keep using it for the results that follow.
--
-- The pin persists rather than lasting one query: having asked for JSON, a
-- second `JSON.GET` should not silently revert to a grid. `auto` hands the
-- decision back to detection.
function M.set_output_mode(mode)
  mode = vim.trim(mode or "")
  if mode == "" then
    vim.notify(string.format("dblite: output is %s (showing %s)",
      state.forced_mode or "auto", state.render_mode), vim.log.levels.INFO)
    return
  end
  if not output.is_mode(mode) then
    vim.notify("dblite: output must be one of " .. table.concat(output.MODES, ", "),
      vim.log.levels.ERROR)
    return
  end

  state.forced_mode = mode ~= "auto" and mode or nil

  local entry = state.history[state.history_idx]
  state.render_mode = output.resolve({
    columns      = state.columns,
    column_types = state.column_types,
    rows         = state.rows,
  }, {
    query  = entry and entry.query_text,
    forced = state.forced_mode,
    cfg    = output_cfg(),
  })

  if state.result_bufnr and vim.api.nvim_buf_is_valid(state.result_bufnr) then
    render_page()
  end
  vim.notify(string.format("dblite: output → %s%s", mode,
    mode == "auto" and (" (" .. state.render_mode .. ")") or ""), vim.log.levels.INFO)
end

-- Cycle through every renderer including `auto`, so one key both explores the
-- alternatives and gets back to letting dblite choose.
function M.cycle_output()
  local current = state.forced_mode or "auto"
  local idx = 1
  for i, mode in ipairs(output.MODES) do
    if mode == current then idx = i; break end
  end
  M.set_output_mode(output.MODES[(idx % #output.MODES) + 1])
end

function M.toggle_fullscreen()
  if not state.result_bufnr or not vim.api.nvim_buf_is_valid(state.result_bufnr) then return end

  if state.fullscreen_tab and vim.api.nvim_tabpage_is_valid(state.fullscreen_tab) then
    -- Leave fullscreen: close the tab, return to previous tab
    vim.api.nvim_set_current_tabpage(state.fullscreen_tab)
    vim.cmd("tabclose")
    state.fullscreen_tab = nil
  else
    -- Enter fullscreen: open dbout in a new tab
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, state.result_bufnr)
    apply_dbout_win_style(0)
    state.fullscreen_tab = vim.api.nvim_get_current_tabpage()
  end
  -- Recompute widths (fullscreen disables truncation) and re-render
  state.widths = compute_widths(state.rows, state.columns)
  render_page()
end

vim.api.nvim_create_user_command("DbliteToggleOut", M.toggle_dbout, {})

vim.api.nvim_create_user_command("DbliteSplit", function(opts)
  M.set_split_dir(opts.args)
end, {
  nargs    = "?",
  complete = function(arg_lead)
    return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end,
      { "right", "left", "below", "above", "tab" })
  end,
})

vim.api.nvim_create_user_command("DbliteOutput", function(opts)
  M.set_output_mode(opts.args)
end, {
  nargs    = "?",
  complete = function(arg_lead)
    return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end, output.MODES)
  end,
})

-- :DbliteExport <csv|json> [path] — write the full result set to a file
vim.api.nvim_create_user_command("DbliteExport", function(opts)
  local fmt  = opts.fargs[1]
  local path = opts.fargs[2] and table.concat(vim.list_slice(opts.fargs, 2), " ") or nil
  M.export(fmt, path)
end, {
  nargs = "+",
  complete = function(arg_lead, cmd_line)
    local n = #vim.split(cmd_line, "%s+")
    if n <= 2 then
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end, { "csv", "json" })
    end
    return vim.fn.getcompletion(arg_lead, "file")
  end,
})

-- Panel public API
function M.toggle_panel()
  if config.connection_picker == "telescope" then
    telescope.pick()
  else
    panel.toggle()
  end
end
M.open_panel      = panel.open
M.close_panel     = panel.close
M.is_panel_open   = panel.is_open

vim.api.nvim_create_user_command("DblitePanel", function()
  M.toggle_panel()
end, {})

-- Recursively decode string values that are themselves serialized JSON
-- objects/arrays, so the inspector nests them cleanly instead of showing a
-- single escaped blob. Leaves scalars and non-JSON strings untouched.
local function expand_json_strings(value, depth)
  depth = depth or 0
  if depth > 8 then return value end

  if type(value) == "string" then
    local trimmed = value:match("^%s*(.-)%s*$")
    local first = trimmed:sub(1, 1)
    if first == "{" or first == "[" then
      local ok, decoded = pcall(vim.json.decode, trimmed)
      if ok and type(decoded) == "table" then
        return expand_json_strings(decoded, depth + 1)
      end
    end
    return value
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = expand_json_strings(v, depth + 1)
    end
    return out
  end

  return value
end

function M.inspect(format)
  format = format or config.inspect_format or "json"

  local page_size = config.page_size or 100
  local start_row = (state.page - 1) * page_size + 1
  local end_row   = math.min(start_row + page_size - 1, #state.rows)
  local page_rows = {}
  for i = start_row, end_row do
    table.insert(page_rows, state.rows[i])
  end

  local lines = {}

  if format == "json" then
    if not state.raw_json then
      vim.notify("dblite: no query result to inspect", vim.log.levels.WARN)
      return
    end
    local ok, decoded = pcall(vim.json.decode, state.raw_json)
    if not ok then
      vim.notify("dblite: could not parse stored JSON", vim.log.levels.ERROR)
      return
    end
    local inspect_rows = page_rows
    if config.inspect_expand_json ~= false then
      inspect_rows = expand_json_strings(page_rows)
    end
    local page_data = { columns = decoded.columns, rows = inspect_rows }
    local encoded   = vim.json.encode(page_data) or ""
    local pretty_ok = false
    pcall(function()
      local r = vim.system({ "jq", "." }, { stdin = encoded }):wait()
      if r.code == 0 and r.stdout and #r.stdout > 0 then
        lines     = vim.split(r.stdout, "\n", { plain = true })
        pretty_ok = true
      end
    end)
    if not pretty_ok then
      lines = vim.split(encoded, "\n", { plain = true })
    end

  elseif format == "table" then
    if #state.columns == 0 then
      vim.notify("dblite: no query result to inspect", vim.log.levels.WARN)
      return
    end
    local widths = {}
    for _, col in ipairs(state.columns) do widths[col] = #tostring(col) end
    for _, row in ipairs(page_rows) do
      for _, col in ipairs(state.columns) do
        local s = (row[col] == nil or row[col] == vim.NIL) and "" or tostring(row[col])
        if #s > widths[col] then widths[col] = #s end
      end
    end
    local function pad(val, w)
      local s = (val == nil or val == vim.NIL) and "" or tostring(val)
      return s .. string.rep(" ", w - #s)
    end
    local headers, seps = {}, {}
    for _, col in ipairs(state.columns) do
      table.insert(headers, pad(col, widths[col]))
      table.insert(seps,    string.rep("-", widths[col]))
    end
    table.insert(lines, table.concat(headers, " | "))
    table.insert(lines, table.concat(seps,    "-+-"))
    for _, row in ipairs(page_rows) do
      local parts = {}
      for _, col in ipairs(state.columns) do
        table.insert(parts, pad(row[col], widths[col]))
      end
      table.insert(lines, table.concat(parts, " | "))
    end

  elseif format == "csv" then
    if #state.columns == 0 then
      vim.notify("dblite: no query result to inspect", vim.log.levels.WARN)
      return
    end
    local function csv_escape(val)
      local s = (val == nil or val == vim.NIL) and "" or tostring(val)
      s = s:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "\\n")
      if s:find('[,"]') then s = '"' .. s:gsub('"', '""') .. '"' end
      return s
    end
    table.insert(lines, table.concat(vim.tbl_map(csv_escape, state.columns), ","))
    for _, row in ipairs(page_rows) do
      local parts = {}
      for _, col in ipairs(state.columns) do table.insert(parts, csv_escape(row[col])) end
      table.insert(lines, table.concat(parts, ","))
    end

  else
    vim.notify("dblite: unknown inspect format '" .. format .. "' (json|table|csv)", vim.log.levels.ERROR)
    return
  end

  local view     = config.json_view or "tab"
  local filetype = format == "json" and "json" or format == "csv" and "csv" or ""
  local bufnr, winnr

  if view == "float" then
    local width  = math.floor(vim.o.columns * 0.85)
    local height = math.floor(vim.o.lines   * 0.80)
    local frow   = math.floor((vim.o.lines   - height) / 2)
    local fcol   = math.floor((vim.o.columns - width)  / 2)
    bufnr = vim.api.nvim_create_buf(false, true)
    winnr = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor", style = "minimal", border = "rounded",
      width = width, height = height, row = frow, col = fcol,
    })
    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(winnr, true) end,
      { buffer = bufnr, silent = true })
  else
    local cmds = { tab = "tabnew", vertical = "botright vnew", horizontal = "botright new" }
    vim.cmd(cmds[view] or "tabnew")
    bufnr = vim.api.nvim_get_current_buf()
    winnr = vim.api.nvim_get_current_win()
    vim.keymap.set("n", "q", "<cmd>bd<cr>", { buffer = bufnr, silent = true })
  end

  vim.bo[bufnr].buftype   = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile  = false
  vim.bo[bufnr].filetype  = filetype
  vim.wo[winnr].wrap          = false
  vim.wo[winnr].linebreak     = false
  vim.wo[winnr].number        = false
  vim.wo[winnr].sidescrolloff = 3
  vim.bo[bufnr].synmaxcol     = 500

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

-- Serializes the full result set (all rows, not just the current page) to a
-- list of lines for the given format ("csv" | "json"). Returns lines or nil + err.
local function serialize_result(format)
  if #state.columns == 0 then
    return nil, "no query result to export"
  end

  if format == "csv" then
    local function csv_escape(val)
      local s = (val == nil or val == vim.NIL) and "" or tostring(val)
      s = s:gsub("\r\n", "\\n"):gsub("\n", "\\n"):gsub("\r", "\\n")
      if s:find('[,"]') then s = '"' .. s:gsub('"', '""') .. '"' end
      return s
    end
    local lines = { table.concat(vim.tbl_map(csv_escape, state.columns), ",") }
    for _, row in ipairs(state.rows) do
      local parts = {}
      for _, col in ipairs(state.columns) do table.insert(parts, csv_escape(row[col])) end
      table.insert(lines, table.concat(parts, ","))
    end
    return lines

  elseif format == "json" then
    -- Prefer the original server JSON (most faithful); fall back to re-encoding.
    local encoded = state.raw_json
    if not encoded or encoded == "" then
      encoded = vim.json.encode({ columns = state.columns, rows = state.rows }) or ""
    end
    local pretty
    pcall(function()
      local r = vim.system({ "jq", "." }, { stdin = encoded }):wait()
      if r.code == 0 and r.stdout and #r.stdout > 0 then
        pretty = vim.split(r.stdout:gsub("\n$", ""), "\n", { plain = true })
      end
    end)
    return pretty or vim.split(encoded, "\n", { plain = true })
  end

  return nil, "unknown export format '" .. tostring(format) .. "' (csv|json)"
end

-- :Dblite export <csv|json> [path]
-- Writes the entire result set to a file. Prompts for a path when omitted.
function M.export(format, path)
  format = (format or ""):lower()
  if format ~= "csv" and format ~= "json" then
    vim.notify("dblite: export format must be 'csv' or 'json'", vim.log.levels.ERROR)
    return
  end

  local lines, err = serialize_result(format)
  if not lines then
    vim.notify("dblite: " .. err, vim.log.levels.WARN)
    return
  end

  if not path or path == "" then
    local default = "dblite_export." .. format
    path = vim.fn.input({ prompt = "Export to: ", default = default, completion = "file" })
    if path == "" then
      vim.notify("dblite: export cancelled", vim.log.levels.INFO)
      return
    end
  end

  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  -- Write with Lua I/O rather than vim.fn.writefile: cell values may contain
  -- NUL bytes (e.g. CLOB/RAW columns), which Neovim coerces to a Blob when
  -- crossing into Vimscript, making writefile fail with E974.
  local f, oerr = io.open(path, "wb")
  if not f then
    vim.notify("dblite: could not write " .. path .. ": " .. tostring(oerr), vim.log.levels.ERROR)
    return
  end
  local ok, werr = pcall(function()
    f:write(table.concat(lines, "\n"))
    f:write("\n")
  end)
  f:close()
  if not ok then
    vim.notify("dblite: could not write " .. path .. ": " .. tostring(werr), vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("dblite: exported %d row%s to %s",
    #state.rows, #state.rows == 1 and "" or "s", path), vim.log.levels.INFO)
end

-- Open a scratch buffer previewing the INSERTs a CSV load will run. The buffer
-- is editable SQL: on commit we run whatever it currently holds (minus the
-- comment header) through script mode, so the user can tweak before committing.
local function open_load_preview(control, built, path)
  local km = (config.keymaps and config.keymaps.load) or {}
  local commit_key = km.commit or "<CR>"
  local cancel_key = km.cancel or "q"

  local lines = {}
  local function h(s) lines[#lines + 1] = "-- " .. s end
  h(string.format("dblite load — %s to commit, %s to cancel", commit_key, cancel_key))
  h("source : " .. path)
  h(string.format("target : %s   (mode=%s)", control.table, control.mode))
  h("columns: " .. table.concat(control.columns, ", "))
  local extra = built.skipped > 0 and string.format("  (skipped %d header row(s))", built.skipped) or ""
  h(string.format("rows   : %d insert(s)%s", built.count, extra))
  if #built.errors > 0 then
    h(string.format("errors : %d row(s) not inserted —", #built.errors))
    for _, e in ipairs(built.errors) do h("  " .. e) end
  end
  lines[#lines + 1] = ""
  vim.list_extend(lines, built.statements)

  local view = config.load_view or "tab"
  local bufnr, winnr
  if view == "float" then
    local width  = math.floor(vim.o.columns * 0.85)
    local height = math.floor(vim.o.lines * 0.80)
    bufnr = vim.api.nvim_create_buf(false, true)
    winnr = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor", style = "minimal", border = "rounded",
      width = width, height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
    })
  else
    local cmds = { tab = "tabnew", vertical = "botright vnew", horizontal = "botright new" }
    vim.cmd(cmds[view] or "tabnew")
    bufnr = vim.api.nvim_get_current_buf()
    winnr = vim.api.nvim_get_current_win()
  end

  vim.bo[bufnr].buftype   = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile  = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype  = "sql"

  local function close()
    if winnr and vim.api.nvim_win_is_valid(winnr) then
      pcall(vim.api.nvim_win_close, winnr, true)
    end
  end

  vim.keymap.set("n", cancel_key, close, { buffer = bufnr, silent = true, desc = "dblite: cancel load" })
  vim.keymap.set("n", commit_key, function()
    -- Run the buffer as it stands, dropping pure-comment lines from the header.
    local kept = {}
    for _, ln in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if not ln:match("^%s*%-%-") then kept[#kept + 1] = ln end
    end
    local sql = table.concat(kept, "\n")
    close()
    if sql:match("%S") then execute_core(sql, true) end
  end, { buffer = bufnr, silent = true, desc = "dblite: commit load" })
end

-- :Dblite load — parse a SQL*Loader control block in the buffer, read its CSV,
-- and preview the generated INSERTs before committing them (script mode).
function M.load(opts)
  -- LOAD DATA generates INSERT statements, which have no Redis equivalent.
  if state.active_conn and state.active_conn.type == "redis" then
    vim.notify("dblite: :Dblite load is SQL-only; use a Redis script with SET/HSET instead",
      vim.log.levels.ERROR)
    return
  end

  local first, last
  if opts and opts.range and opts.range > 0 then
    first, last = opts.line1, opts.line2
  else
    first, last = 1, vim.api.nvim_buf_line_count(0)
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")

  local control, perr = load_mod.parse(text)
  if not control then
    vim.notify("dblite: " .. perr, vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable(config.binary) ~= 1 then
    vim.notify("dblite: binary not found — run :DbliteBuild", vim.log.levels.ERROR)
    return
  end
  if not state.active_conn then
    vim.notify("dblite: no active connection — use :DbliteUseConn <name>", vim.log.levels.ERROR)
    return
  end

  -- Resolve INFILE relative to cwd, expanding ~ and $ENV_VAR (as export does).
  local path = vim.fn.fnamemodify(vim.fn.expand(connections.expand_env(control.infile)), ":p")
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("dblite: INFILE not readable: " .. path, vim.log.levels.ERROR)
    return
  end

  local records, rerr = load_mod.read_csv(path, control.sep, control.enclosed)
  if not records then
    vim.notify("dblite: " .. rerr, vim.log.levels.ERROR)
    return
  end

  local built = load_mod.build(control, records, state.active_conn.type or "oracle")
  if built.count == 0 then
    local msg = "dblite: nothing to load from " .. path
    if #built.errors > 0 then msg = msg .. " — " .. built.errors[1] end
    vim.notify(msg, vim.log.levels.WARN)
    return
  end

  open_load_preview(control, built, path)
end

vim.api.nvim_create_user_command("DbliteLoad", M.load, { range = true })

local _binds_win = nil

local function ensure_binds_file()
  local path = binds_mod.file_path()
  if vim.fn.filereadable(path) == 0 then
    vim.fn.writefile({ "{", "}" }, path)
    vim.notify("dblite: created " .. path, vim.log.levels.INFO)
  end
  return path
end

local function setup_binds_keymaps(bufnr)
  local km = config.keymaps and config.keymaps.binds or {}
  if km.toggle and km.toggle ~= "" then
    vim.keymap.set("n", km.toggle, function()
      M.toggle_binds()
    end, { buffer = bufnr, silent = true, desc = "dblite: toggle binds window" })
  end
end

local function open_binds_split()
  local path = ensure_binds_file()
  local split_cfg = config.binds_split or {}

  if split_cfg.style == "float" then
    local w = split_cfg.float_width  or 0
    local h = split_cfg.float_height or 0
    if w == 0 then w = math.floor(vim.o.columns * 0.7) end
    if h == 0 then h = math.floor(vim.o.lines   * 0.6) end
    local row = math.floor((vim.o.lines   - h) / 2)
    local col = math.floor((vim.o.columns - w) / 2)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    local winnr = vim.api.nvim_open_win(bufnr, true, {
      relative  = "editor",
      border    = "rounded",
      title     = " dblite.binds.json ",
      title_pos = "center",
      width     = w,
      height    = h,
      row       = row,
      col       = col,
    })
    vim.bo[bufnr].filetype = "json"
    setup_binds_keymaps(bufnr)
    _binds_win = winnr
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern  = tostring(winnr),
      once     = true,
      callback = function() _binds_win = nil end,
    })
    return
  end

  local dir  = split_cfg.split_dir or "vertical"
  local size = ""
  if dir == "vertical" then
    local w = split_cfg.width or 40
    if w > 0 then size = tostring(w) end
    vim.cmd(size .. "vsplit " .. vim.fn.fnameescape(path))
  else
    local h = split_cfg.height or 20
    if h > 0 then size = tostring(h) end
    vim.cmd(size .. "split " .. vim.fn.fnameescape(path))
  end
  _binds_win = vim.api.nvim_get_current_win()
  setup_binds_keymaps(vim.api.nvim_get_current_buf())
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(_binds_win),
    once     = true,
    callback = function() _binds_win = nil end,
  })
end

function M.open_binds()
  if _binds_win and vim.api.nvim_win_is_valid(_binds_win) then
    vim.api.nvim_set_current_win(_binds_win)
  else
    open_binds_split()
  end
end

function M.toggle_binds()
  if _binds_win and vim.api.nvim_win_is_valid(_binds_win) then
    vim.api.nvim_win_close(_binds_win, false)
    _binds_win = nil
  else
    open_binds_split()
  end
end

M.open_binds_file = M.toggle_binds
M.edit_binds      = M.toggle_binds

function M.edit_connections_file()
  local path = vim.fn.stdpath("data") .. "/dblite/connections.json"
  if vim.fn.filereadable(path) ~= 1 then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = io.open(path, "w")
    if f then f:write("[]") f:close() end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer   = vim.api.nvim_get_current_buf(),
    once     = true,
    callback = function()
      panel.refresh()
      if state.active_conn then
        local updated = connections.get(state.active_conn.id)
        if updated then
          state.active_conn = updated
          invalidate_completion(updated.id)
          prefetch_completion(updated)
        end
      end
    end,
  })
end

-- Unified :Dblite <subcommand> entry point
do
  local dispatch = {
    run           = function(a, range)
      if     a[2] == "at"     then M.execute_at_cursor()
      elseif a[2] == "script" then M.execute_script()
      elseif a[2] == "bulk"   then
        local path = #a >= 4 and table.concat(vim.list_slice(a, 4), " ") or nil
        M.run_async(a[3], path, range)
      else M.execute() end
    end,
    jobs          = function() jobs.toggle() end,
    watch         = function(a, range)
      if a[2] == "stop" then
        vim.cmd("DbliteWatchStop")
      elseif a[2] == "file" then
        M.watch_file(table.concat(vim.list_slice(a, 3), " "))
      else
        M.watch(table.concat(vim.list_slice(a, 2), " "), range)
      end
    end,
    toggle        = function(a)
      if     a[2] == "panel" then M.toggle_panel()
      elseif a[2] == "dbout" then M.toggle_dbout()
      elseif a[2] == "jobs"  then jobs.toggle()
      else vim.notify("dblite: toggle what? (panel | dbout | jobs)", vim.log.levels.ERROR) end
    end,
    conn          = function(a)
      local sub = a[2]
      if     sub == "add"  then vim.cmd("DbliteAddConn " .. table.concat(vim.list_slice(a, 3), " "))
      elseif sub == "list" then vim.cmd("DbliteListConns")
      elseif sub == "use"  then vim.cmd("DbliteUseConn "  .. (a[3] or ""))
      elseif sub == "edit" then vim.cmd("DbliteEditConn " .. (a[3] or ""))
      elseif sub == "del"  then vim.cmd("DbliteDeleteConn " .. (a[3] or ""))
      elseif sub == "file" then M.edit_connections_file()
      elseif sub == "pick" then telescope.pick()
      else vim.notify("dblite: conn what? (add | list | use | edit | del | file | pick)", vim.log.levels.ERROR) end
    end,
    build         = function(a) vim.cmd(a[2] == "force" and "DbliteBuild!" or "DbliteBuild") end,
    inspect       = function(a) M.inspect(a[2]) end,
    export        = function(a)
      local path = #a >= 3 and table.concat(vim.list_slice(a, 3), " ") or nil
      M.export(a[2], path)
    end,
    binds         = function() M.edit_binds() end,
    load          = function() M.load() end,
    split         = function(a) M.set_split_dir(a[2]) end,
    output        = function(a) M.set_output_mode(a[2]) end,
  }

  local function complete(arg_lead, cmd_line)
    local tokens = vim.split(cmd_line, "%s+")
    local n = #tokens
    if n == 2 then
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end,
        { "run", "watch", "jobs", "toggle", "conn", "build", "inspect", "export", "binds", "load", "split", "output" })
    elseif n == 3 then
      local sub = tokens[2]
      local opts = {
        run     = { "at", "script", "bulk" },
        watch   = { "file", "stop", "every=", "until=", "max=", "for=" },
        jobs    = {},
        build   = { "force" },
        toggle  = { "panel", "dbout", "jobs" },
        conn    = { "add", "list", "use", "edit", "del", "file", "pick" },
        inspect = { "json", "table", "csv" },
        export  = { "csv", "json" },
        split   = { "right", "left", "below", "above", "tab" },
        output  = output.MODES,
      }
      local choices = opts[sub] or {}
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end, choices)
    elseif n == 4 and tokens[2] == "run" and tokens[3] == "bulk" then
      return vim.tbl_filter(function(k) return k:sub(1, #arg_lead) == arg_lead end, { "csv", "json" })
    elseif n >= 4 and tokens[2] == "conn" and (tokens[3] == "use" or tokens[3] == "edit" or tokens[3] == "del") then
      return complete_name(arg_lead)
    elseif n >= 4 and tokens[2] == "export" then
      return vim.fn.getcompletion(arg_lead, "file")
    elseif n >= 5 and tokens[2] == "run" and tokens[3] == "bulk" then
      return vim.fn.getcompletion(arg_lead, "file")
    end
    return {}
  end

  vim.api.nvim_create_user_command("Dblite", function(opts)
    local add_uri = opts.args:match("^conn%s+add%s+(.+)$")
    if add_uri then
      vim.cmd("DbliteAddConn " .. add_uri)
      return
    end
    local args = vim.split(opts.args, "%s+")
    local range = (opts.range and opts.range > 0) and { line1 = opts.line1, line2 = opts.line2 } or nil
    local fn = dispatch[args[1]]
    if fn then
      fn(args, range)
    else
      vim.notify("dblite: unknown subcommand '" .. (args[1] or "") .. "'", vim.log.levels.ERROR)
    end
  end, {
    nargs    = "+",
    range    = true,
    complete = complete,
  })
end

-- Run a statement headlessly on a named saved connection and hand the result
-- to Lua. No result window, no history, no jobs panel, and the active
-- connection is left alone — see lua/dblite/inline.lua for the full options.
--
--   require("dblite").inline({ conn = "prod", sql = "select ..." },
--     function(err, res)
--       if err then return end
--       vim.notify(res.rows[1].EXPIRES_AT)
--     end)
M.inline = inline.run

function M.get_active_conn()
  return state.active_conn
end

function M.get_flat_binds()
  return binds_mod.flatten(binds_mod.load_file())
end

function M.hover_bind()
  local line = vim.api.nvim_get_current_line()
  local col  = vim.api.nvim_win_get_cursor(0)[2] + 1  -- 1-based

  -- find the :bind token surrounding the cursor
  local s, e, name
  local pos = 1
  while true do
    s, e, name = line:find(":([a-zA-Z_][a-zA-Z0-9_.]*)", pos)
    if not s then break end
    if col >= s and col <= e then break end
    pos = e + 1
    name = nil
  end
  if not name then return end
  name = name:gsub("%.+$", "")

  local binds = binds_mod.flatten(binds_mod.load_file())
  local val   = binds[name]
  if val == nil then
    vim.lsp.util.open_floating_preview(
      { ":" .. name, "", "(not set)" }, "",
      { border = "rounded", focus_id = "dblite_bind_hover" })
    return
  end

  local display = binds_mod.format_value(val)
  vim.lsp.util.open_floating_preview(
    { ":" .. name, "", display }, "sql",
    { border = "rounded", focus_id = "dblite_bind_hover" })
end

return M
