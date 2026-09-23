-- A realistic terminal. At nvim's headless default of 80 columns a 61-column
-- dbout leaves the editor below 'winwidth', so vim claws columns back and the
-- placement logic under test is masked by that policy.
vim.o.columns = 200
vim.o.lines   = 50

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local dblite = require("dblite")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

-- Give dbout something to show; this also creates the result buffer.
dblite.show_result({
  columns      = { "key", "value" },
  column_types = { "string", "string" },
  rows         = { { key = "a", value = "1" }, { key = "b", value = "2" } },
  json         = '{"columns":["key","value"],"rows":[]}',
  elapsed      = 0.01,
}, { query = "KEYS *", conn = "spec" })

-- dbout is the window the cursor is not in: every placement returns the cursor
-- to the editor with `wincmd p`.
local function dbout_win()
  local wins = vim.api.nvim_list_wins()
  if #wins ~= 2 then return nil end
  local cur = vim.api.nvim_get_current_win()
  return wins[1] == cur and wins[2] or wins[1]
end

-- A left/right split sits at a non-zero column; an above/below split at a
-- non-zero row. Exactly one holds for two windows.
local function placement(win)
  local row, col = unpack(vim.api.nvim_win_get_position(win))
  if col > 0 then return "right" end
  if row > 0 then return "below" end
  return "topleft"   -- left/above: the editor is the one pushed aside
end

-- ── explicit placement ──────────────────────────────────────────────────────

dblite.set_split_dir("right")
local win = assert(dbout_win(), "dbout should be open after set_split_dir")
eq(placement(win), "right", "right split places dbout beside the editor")
eq(vim.wo[win].winfixwidth, true, "a side split pins its width")

dblite.set_split_dir("below")
win = assert(dbout_win(), "dbout should still be open")
eq(placement(win), "below", "below split places dbout under the editor")
eq(vim.wo[win].winfixheight, true, "a stacked split pins its height")

-- ── cycle ───────────────────────────────────────────────────────────────────

dblite.cycle_split()
eq(placement(assert(dbout_win())), "right", "cycling from below lands on right")

dblite.cycle_split()
eq(placement(assert(dbout_win())), "below", "cycling from right lands on below")

-- ── the placement and size survive a toggle ─────────────────────────────────

dblite.set_split_dir("right")
win = assert(dbout_win(), "dbout open before toggle")
vim.api.nvim_win_set_width(win, 61)     -- a width the user "dragged" to
eq(vim.api.nvim_win_get_width(win), 61, "width set before toggling away")

dblite.toggle_dbout()                    -- hide
eq(dbout_win(), nil, "dbout hidden after the first toggle")

dblite.toggle_dbout()                    -- show again
win = assert(dbout_win(), "dbout should come back after toggling twice")
eq(placement(win), "right", "toggling back keeps the right-hand placement")
eq(vim.api.nvim_win_get_width(win), 61, "toggling back restores the dragged width")

-- ── an unknown direction is refused, leaving the placement alone ────────────

dblite.set_split_dir("sideways")
win = assert(dbout_win(), "dbout still open after a bad direction")
eq(placement(win), "right", "a rejected direction does not move the window")
eq(vim.api.nvim_win_get_width(win), 61, "a rejected direction does not resize")

-- ── the placement is persisted ──────────────────────────────────────────────

local ui_path = vim.fn.stdpath("data") .. "/dblite/ui.json"
local f = assert(io.open(ui_path, "r"), "ui.json should have been written")
local saved = vim.json.decode(f:read("*a"))
f:close()
-- The placement is remembered per connection type; with no connection active
-- it lands under the generic `_default` key.
eq(saved.split_dir._default, "right", "split_dir persisted")
-- The size is deliberately NOT persisted. A size on disk outranked the user's
-- own `split_size`, and because it was written on every toggle rather than only
-- on a real resize, one toggle was enough to freeze the configured value for
-- good. Size memory is session-scoped instead; the placement still persists.
eq(saved.split_size, nil, "the size must not be written to disk")

print("split_spec: ok")
