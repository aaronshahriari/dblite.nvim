-- A size the user drags to must survive toggling dbout away and back, which is
-- the whole reason session size memory exists. Its own process: a resize here
-- would outrank config in any case that followed.

local H = dofile("tests/window/_harness.lua")
local d, cfg = require("dblite"), require("dblite.config")

cfg.split_dir  = "right"
cfg.split_size = { width = 0.4, height = 17 }

H.show()
H.check(H.frac(0.4), H.width(), "opens at the configured fraction")

local dragged = math.floor(H.COLS * 0.7)
vim.api.nvim_win_set_width(H.dbout(), dragged)
H.check(dragged, H.width(), "resized by hand")

d.toggle_dbout(); d.toggle_dbout()
H.check(dragged, H.width(), "the resize survives toggling away and back")

-- An explicit resize outranks a later config change, within the session.
cfg.split_size = { width = 0.2, height = 17 }
d.toggle_dbout(); d.toggle_dbout()
H.check(dragged, H.width(), "a deliberate resize beats a later config change")

H.finish()
