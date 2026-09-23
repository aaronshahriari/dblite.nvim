-- Choosing how a result is rendered.
--
-- The grid is right for anything genuinely tabular, and wrong for everything
-- else. A Redis reply is only sometimes a table: `HGETALL` is field/value and
-- `ZRANGE ... WITHSCORES` is member/score, but `JSON.GET` hands back one
-- document, and squeezing that into a single cell truncated at
-- `max_col_width` throws the entire value away. This module decides, per
-- result, which of the renderers in init.lua gets to draw it.

local M = {}

M.MODES = { "auto", "grid", "json", "text" }

local VALID = { auto = true, grid = true, json = true, text = true }

--- Whether `mode` is one the renderer understands.
function M.is_mode(mode)
  return type(mode) == "string" and VALID[mode] == true
end

--- The command a statement invokes, upper-cased: the first word of the first
--- line that is not blank or a comment. `JSON.GET user:1 $` yields `JSON.GET`.
--- Returns nil when there is nothing to name.
---@param query string|nil
---@return string|nil
function M.command(query)
  if type(query) ~= "string" then return nil end
  for line in query:gmatch("[^\r\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
      local word = trimmed:match("^([%a][%w_%.]*)")
      return word and word:upper() or nil
    end
  end
  return nil
end

--- The single cell of a one-row, one-column result, with its column type.
--- Returns nil for anything with a second row or column — that is a table.
local function lone_cell(res)
  local columns = res.columns or {}
  local rows    = res.rows or {}
  if #columns ~= 1 or #rows ~= 1 then return nil end
  local value = rows[1][columns[1]]
  if value == nil or value == vim.NIL then return nil end
  return tostring(value), (res.column_types or {})[1]
end

--- What `auto` settles on for a result the backend has already typed.
--- The shaper tags a column `json` only when every value in it is a JSON
--- document, so that tag is trustworthy enough to switch renderers on.
local function detect(res)
  local value, ctype = lone_cell(res)
  if not value then return "grid" end
  if ctype == "json" then return "json" end
  -- A grid cell cannot show a newline at all — it escapes them to `\n` and
  -- then truncates. Anything multi-line is better off as text.
  if value:find("\n", 1, true) then return "text" end
  return "grid"
end

--- Resolve the renderer for one result.
---
--- Precedence, highest first:
---   1. `forced` — what `:DbliteOutput` set for this window
---   2. `cfg.commands[<command>]` — a per-command pin from the user's config
---   3. `cfg.mode` — the configured default, when it is not "auto"
---   4. detection from the result's own shape and column types
---
---@param res table            result as passed to `show_result`
---@param opts table|nil       { query = string, forced = string, cfg = table }
---@return string              one of "grid" | "json" | "text"
function M.resolve(res, opts)
  opts = opts or {}
  local cfg = opts.cfg or {}

  local forced = opts.forced
  if M.is_mode(forced) and forced ~= "auto" then return forced end

  local commands = cfg.commands or {}
  local cmd = M.command(opts.query)
  if cmd then
    -- Config keys are matched case-insensitively so `json.get` and `JSON.GET`
    -- both pin the same command.
    for name, mode in pairs(commands) do
      if type(name) == "string" and name:upper() == cmd and M.is_mode(mode) then
        if mode ~= "auto" then return mode end
        return detect(res)
      end
    end
  end

  local default = cfg.mode
  if M.is_mode(default) and default ~= "auto" then return default end

  return detect(res)
end

return M
