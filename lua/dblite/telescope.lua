-- Optional telescope.nvim-based connection picker.
-- Enabled with `connection_picker = "telescope"`; requires nvim-telescope/telescope.nvim.
local config      = require("dblite.config")
local connections = require("dblite.connections")

local M = {}

local _get_state
local _on_select

vim.api.nvim_set_hl(0, "DbliteTelescopeActive", { link = "String", default = true })

local type_labels = {
  oracle    = "Oracle",
  sqlserver = "SQL Server",
  sqlite    = "SQLite",
  redis     = "Redis",
}

function M.setup(opts)
  _get_state = opts.get_state
  _on_select = opts.on_select
end

-- Returns true if telescope.nvim is available on the runtimepath.
function M.available()
  return pcall(require, "telescope")
end

local function target_str(c)
  if c.type == "sqlite" then return c.path or "?" end
  if c.type == "redis" then
    return string.format("%s%s:%d/%d",
      (c.user and c.user ~= "") and (c.user .. "@") or "",
      c.host or "", c.port or 6379, c.db or 0)
  end
  local db_val       = (c.type == "sqlserver") and c.database or c.service
  local default_port = (c.type == "sqlserver") and 1433 or 1521
  return string.format("%s@%s:%d/%s",
    c.user or "", c.host or "", c.port or default_port, db_val or "?")
end

-- Builds the detail lines shown in the preview pane. The password is masked
-- so the picker never reveals a stored secret on screen.
local function detail_lines(c)
  if c.type == "sqlite" then
    return {
      "Name      " .. (c.name or ""),
      "Type      SQLite",
      "Path      " .. (c.path or ""),
    }
  end
  if c.type == "redis" then
    return {
      "Name      " .. (c.name or ""),
      "Type      Redis",
      "Host      " .. (c.host or ""),
      "Port      " .. tostring(c.port or 6379),
      "Database  " .. tostring(c.db or 0),
      "User      " .. (c.user or "(none)"),
      "Password  " .. ((c.password ~= nil and c.password ~= "") and "********" or "(none)"),
      "TLS       " .. (c.tls and "yes" or "no"),
    }
  end
  local default_port = (c.type == "sqlserver") and 1433 or 1521
  local db_label     = (c.type == "sqlserver") and "Database" or "Service"
  local db_val       = (c.type == "sqlserver") and c.database or c.service
  local pw           = (c.password ~= nil and c.password ~= "") and "********" or "(none)"
  local lines = {
    "Name      " .. (c.name or ""),
    "Type      " .. (type_labels[c.type] or c.type or "?"),
    "Host      " .. (c.host or ""),
    "Port      " .. tostring(c.port or default_port),
    "User      " .. (c.user or ""),
    "Password  " .. pw,
    db_label .. string.rep(" ", math.max(1, 10 - #db_label)) .. (db_val or ""),
  }
  if c.auth then table.insert(lines, "Auth      " .. c.auth) end
  return lines
end

-- Opens the telescope picker for saved connections. Marks the active
-- connection so a connected user re-opening the picker sees they're still on it.
function M.pick()
  if not M.available() then
    vim.notify(
      "dblite: telescope.nvim is not installed (connection_picker = 'telescope')",
      vim.log.levels.ERROR)
    return
  end

  local pickers       = require("telescope.pickers")
  local finders       = require("telescope.finders")
  local conf          = require("telescope.config").values
  local actions       = require("telescope.actions")
  local action_state  = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local previewers    = require("telescope.previewers")

  local conns = connections.list()
  if #conns == 0 then
    vim.notify("dblite: no connections saved. Use :DbliteAddConn", vim.log.levels.INFO)
    return
  end

  local st     = _get_state and _get_state() or {}
  local active = st.active_conn

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 1 },         -- active marker
      { remaining = true },  -- name
    },
  })

  -- Connection type and target are shown in the preview pane, so the list
  -- itself stays clean: just the active marker and the connection name.
  local function entry_maker(c)
    local is_active = active ~= nil and active.id == c.id
    local name_hl   = is_active and "DbliteTelescopeActive" or "TelescopeResultsNormal"
    return {
      value   = c,
      ordinal = (c.name or "") .. " " .. (c.type or "") .. " " .. target_str(c),
      display = function()
        return displayer({
          { is_active and "\xe2\x97\x8f" or " ", "DbliteTelescopeActive" },  -- ● in UTF-8
          { c.name or "",                         name_hl },
        })
      end,
    }
  end

  local pcfg       = config.telescope_picker or {}
  local preview_on = pcfg.preview ~= false

  local layout_config = {
    width  = pcfg.width  or 0.4,
    height = pcfg.height or 0.4,
  }
  if preview_on then
    layout_config.preview_width = pcfg.preview_width or 0.5
  end

  local previewer = preview_on and previewers.new_buffer_previewer({
    title = "Connection",
    define_preview = function(self, entry)
      if not entry or not entry.value then return end
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, detail_lines(entry.value))
    end,
  }) or false

  pickers.new({}, {
    prompt_title    = "Connections",
    finder          = finders.new_table({ results = conns, entry_maker = entry_maker }),
    sorter          = conf.generic_sorter({}),
    previewer       = previewer,
    layout_strategy = "horizontal",
    layout_config   = layout_config,
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        local conn = entry.value
        if active and active.id == conn.id then
          vim.notify("dblite: already using '" .. conn.name .. "'", vim.log.levels.INFO)
          return
        end
        if _on_select then _on_select(conn) end
      end)
      return true
    end,
  }):find()
end

return M
