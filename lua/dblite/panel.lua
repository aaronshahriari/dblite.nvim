local config      = require("dblite.config")
local connections = require("dblite.connections")

local M = {}

local _get_state
local _on_edit

local ns = vim.api.nvim_create_namespace("dblite_panel")

vim.api.nvim_set_hl(0, "DblitePanelTitle",   { link = "Title",   default = true })
vim.api.nvim_set_hl(0, "DblitePanelActive",  { link = "String",  default = true })
vim.api.nvim_set_hl(0, "DblitePanelSep",     { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "DblitePanelSection", { link = "Type",    default = true })

local state = {
  bufnr      = nil,
  winnr      = nil,
  line_map   = {},  -- line number (1-based) → conn name
  prev_winnr = nil,
}

function M.setup(opts)
  _get_state = opts.get_state
  _on_edit   = opts.on_edit
end

local type_labels = {
  oracle    = "Oracle",
  sqlserver = "SQL Server",
  sqlite    = "SQLite",
  redis     = "Redis",
}

local function build_lines()
  local st        = _get_state and _get_state() or {}
  local active    = st.active_conn
  local conns     = connections.list()
  local sep_width = ((config.panel and config.panel.width) or 30) - 2

  local lines    = { "Connections", string.rep("─", sep_width) }
  local line_map = {}
  local hls      = {
    { row = 0, col = 0, len = #lines[1], group = "DblitePanelTitle" },
    { row = 1, col = 0, len = #lines[2], group = "DblitePanelSep"   },
  }

  if #conns == 0 then
    table.insert(lines, "  (no connections)")
  else
    -- group connections by type
    local groups = {}
    local order  = {}
    for _, c in ipairs(conns) do
      local t = c.type or "other"
      if not groups[t] then
        groups[t] = {}
        table.insert(order, t)
      end
      table.insert(groups[t], c)
    end

    for i, t in ipairs(order) do
      if i > 1 then
        table.insert(lines, "")  -- blank line between sections
      end
      local label = type_labels[t] or t:sub(1, 1):upper() .. t:sub(2)
      table.insert(lines, "  " .. label)
      table.insert(hls, {
        row   = #lines - 1,
        col   = 0,
        len   = #lines[#lines],
        group = "DblitePanelSection",
      })

      for _, c in ipairs(groups[t]) do
        local is_active = active ~= nil and active.id == c.id
        local prefix    = is_active and "    \xe2\x9c\x93 " or "      "  -- ✓ in UTF-8
        table.insert(lines, prefix .. c.name)
        local row_1based = #lines
        line_map[row_1based] = c.name
        if is_active then
          table.insert(hls, {
            row   = row_1based - 1,
            col   = 0,
            len   = #lines[row_1based],
            group = "DblitePanelActive",
          })
        end
      end
    end
  end

  return lines, line_map, hls
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
    vim.api.nvim_buf_set_extmark(bufnr, ns, h.row, h.col, {
      end_col  = h.len,
      hl_group = h.group,
    })
  end
end

local function conn_at_cursor()
  if not state.winnr or not vim.api.nvim_win_is_valid(state.winnr) then return nil end
  local row  = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local name = state.line_map[row]
  return name and connections.get_by_name(name)
end

local function setup_keymaps(bufnr)
  local km = (config.keymaps and config.keymaps.panel) or {}

  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end

  map(km.select or "<CR>", function()
    local conn = conn_at_cursor()
    if not conn then return end
    local st = _get_state and _get_state()
    if st then st.active_conn = conn end
    render()
    vim.notify("dblite: using '" .. conn.name .. "'", vim.log.levels.INFO)
  end, "dblite: use connection")

  map(km.edit or "cw", function()
    local conn = conn_at_cursor()
    if not conn then return end
    if _on_edit then _on_edit(conn.name) end
  end, "dblite: edit connection")

  map(km.close or "q", function()
    M.close()
  end, "dblite: close panel")

  map(km.toggle, function()
    M.toggle()
  end, "dblite: toggle panel")
end

function M.open()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_set_current_win(state.winnr)
    return
  end

  state.prev_winnr = vim.api.nvim_get_current_win()

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype   = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile  = false
    state.bufnr = bufnr
    setup_keymaps(bufnr)
  end

  local width = (config.panel and config.panel.width) or 30
  vim.cmd("topleft " .. width .. "vsplit")
  local winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winnr, state.bufnr)
  state.winnr = winnr

  vim.wo[winnr].number         = false
  vim.wo[winnr].relativenumber = false
  vim.wo[winnr].signcolumn     = "no"
  vim.wo[winnr].wrap           = false
  vim.wo[winnr].cursorline     = true
  vim.wo[winnr].winfixwidth    = true

  render()

  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  if line_count >= 3 then
    vim.api.nvim_win_set_cursor(winnr, { 3, 0 })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(winnr),
    once     = true,
    callback = function() state.winnr = nil end,
  })
end

function M.close()
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

function M.refresh()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    render()
  end
end

function M.is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

return M
