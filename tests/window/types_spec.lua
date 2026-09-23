-- Each connection type must get its own configured width. A size remembered
-- from one connection used to leak into the next, so switching connections
-- never picked up the per-type value — the exact shape of a config that sets
-- `types.redis.split_size`.

local H = dofile("tests/window/_harness.lua")
local d, cfg = require("dblite"), require("dblite.config")
local conns  = require("dblite.connections")

cfg.split_dir  = "right"
cfg.split_size = { width = 0.4, height = 17 }
cfg.types = { redis = { split_dir = "right", split_size = { width = 0.75 } } }

local dbp = vim.fn.tempname() .. ".sqlite"
assert(io.open(dbp, "w")):close()
local names = { "spec_win_sql", "spec_win_redis" }
for _, n in ipairs(names) do
  local c = conns.get_by_name(n); if c then conns.delete(c.id) end
end
conns.add({ name = names[1], type = "sqlite", path = dbp })
conns.add({ name = names[2], type = "redis",  host = "127.0.0.1", port = 6399 })

local function use(name)
  vim.cmd("DbliteUseConn " .. name)
  H.show()
  d.toggle_dbout(); d.toggle_dbout()
end

use(names[1]); H.check(H.frac(0.4),  H.width(), "sqlite gets the top-level width")
use(names[2]); H.check(H.frac(0.75), H.width(), "redis gets its per-type width")
use(names[1]); H.check(H.frac(0.4),  H.width(), "switching back restores sqlite's width")

for _, n in ipairs(names) do
  local c = conns.get_by_name(n); if c then conns.delete(c.id) end
end
H.finish()
