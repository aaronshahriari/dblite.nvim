-- Resolving a window size to cells.
--
-- Two problems this exists to solve. A size is configured in absolute cells,
-- which does not survive the terminal changing width — remember 60 columns on
-- a 200-column screen and dbout is still 60 on an 80-column one, or 60 out of
-- 60 and the editor is gone. And a size larger than the screen does not fail
-- visibly: Vim honours it by squeezing the other window down to 'winwidth',
-- which reads as a layout bug rather than as a configuration mistake.
--
-- So a size may be given as a fraction of the screen, a remembered size is
-- stored as one, and every value is clamped to leave the other window usable.

local M = {}

--- Cells available along `axis`, excluding the command line and status line.
---@param axis "width"|"height"
---@return integer
function M.total(axis)
  if axis == "width" then return vim.o.columns end
  -- One row for the command line, one for the status line.
  return math.max(1, vim.o.lines - (vim.o.cmdheight or 1) - 1)
end

--- Cells the *other* window must keep. Vim will take them back regardless via
--- 'winwidth'/'winheight', so respecting them up front is the difference
--- between a size that holds and one that silently drifts.
---@param axis "width"|"height"
---@return integer
function M.reserve(axis)
  if axis == "width" then return math.max(vim.o.winwidth or 20, 10) end
  return math.max(vim.o.winheight or 5, 3)
end

--- Resolve a configured or remembered size to absolute cells.
---
---   nil, 0, negative  → nil, meaning "let Vim decide"
---   0 < value < 1     → that fraction of the screen
---   value >= 1        → that many cells
---
--- The result is clamped to leave `reserve` cells plus a separator for the
--- other window, and nil when the screen is too small to split at all.
---@param axis "width"|"height"
---@param value number|nil
---@param total integer|nil  screen cells; defaults to the live value
---@return integer|nil
function M.resolve(axis, value, total)
  if axis ~= "width" and axis ~= "height" then return nil end
  if type(value) ~= "number" or value ~= value then return nil end  -- nil or NaN
  if value <= 0 then return nil end

  total = total or M.total(axis)
  if type(total) ~= "number" or total < 1 then return nil end

  local cells = value < 1
    and math.floor(total * value + 0.5)
    or  math.floor(value)

  -- One cell for the separator between the two windows.
  local largest = total - M.reserve(axis) - 1
  if largest < 1 then return nil end

  return math.max(1, math.min(cells, largest))
end

--- The fraction of the screen `cells` occupies, for storing a size the user
--- dragged to in a form that survives a resize.
---@param axis "width"|"height"
---@param cells integer
---@param total integer|nil
---@return number|nil
function M.as_fraction(axis, cells, total)
  total = total or M.total(axis)
  if type(cells) ~= "number" or cells < 1 then return nil end
  if type(total) ~= "number" or total < 1 then return nil end
  -- Three decimals is finer than any terminal can show and keeps the
  -- persisted file readable.
  return math.floor((cells / total) * 1000 + 0.5) / 1000
end

return M
