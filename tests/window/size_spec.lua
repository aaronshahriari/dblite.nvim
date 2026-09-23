-- Configured sizes against a real terminal.
--
-- Needs a pty: under `nvim -l` the layout never reflows, so measuring a window
-- measures an 80-column grid whatever the spec set. See tests/run_in_pty.py.

local H = dofile("tests/window/_harness.lua")
local d, cfg = require("dblite"), require("dblite.config")

H.check(H.COLS, vim.o.columns, "the pty gave nvim a real terminal width")

cfg.split_dir  = "right"
cfg.split_size = { width = 0.4, height = 17 }

H.show()
H.check(H.frac(0.4), H.width(), "a fraction opens at that fraction of the screen")

-- The size used to be snapshotted on every hide, which then outranked the
-- config it came from — so editing `split_size` appeared to do nothing.
d.toggle_dbout(); d.toggle_dbout()
H.check(H.frac(0.4), H.width(), "config still applies after a toggle")

cfg.split_size = { width = 0.6, height = 17 }
d.toggle_dbout(); d.toggle_dbout()
H.check(H.frac(0.6), H.width(), "a changed config takes effect")

cfg.split_size = { width = 80, height = 17 }
d.toggle_dbout(); d.toggle_dbout()
H.check(80, H.width(), "an absolute cell count still works")

-- A width past the screen is not rejected by Vim: it squeezes the other window
-- down to 'winwidth' instead, which reads as a layout bug.
cfg.split_size = { width = H.COLS * 4, height = 17 }
d.toggle_dbout(); d.toggle_dbout()
local expected = require("dblite.size").resolve("width", H.COLS * 4, H.COLS)
H.check(expected, H.width(), "an oversized width clamps")
H.check(true, H.editor_width() >= 10,
  "the editor keeps a usable window (" .. H.editor_width() .. " cols)")

H.finish()
