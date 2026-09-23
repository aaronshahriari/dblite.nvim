-- Size resolution: fractions, absolute cells, and the clamping that keeps the
-- editor usable when a configured size is larger than the screen.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local size = require("dblite.size")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

-- A known reserve makes the clamp arithmetic checkable.
vim.o.winwidth  = 20
vim.o.winheight = 5

-- ── absolute cells ──────────────────────────────────────────────────────────

eq(size.resolve("width", 80, 200), 80, "an absolute width passes through")
eq(size.resolve("height", 17, 50), 17, "an absolute height passes through")
eq(size.resolve("width", 80.7, 200), 80, "a fractional cell count truncates")

-- ── fractions of the screen ─────────────────────────────────────────────────

eq(size.resolve("width", 0.5, 200), 100, "0.5 is half the screen")
eq(size.resolve("width", 0.25, 200), 50, "0.25 is a quarter")
eq(size.resolve("width", 0.333, 300), 100, "a fraction rounds to the nearest cell")
eq(size.resolve("height", 0.5, 40), 20, "fractions work on the height axis too")

-- 1 is a cell count, not "the whole screen" — the boundary has to land somewhere
-- and an absolute 1 is the more useful reading.
eq(size.resolve("width", 1, 200), 1, "1 means one cell, not the whole screen")
eq(size.resolve("width", 0.999, 200), 179, "just under 1 is a fraction, and clamps")

-- ── clamping: the editor keeps a usable window ──────────────────────────────

-- winwidth 20 + 1 separator leaves 179 of 200 as the largest dbout can be.
eq(size.resolve("width", 500, 200), 179, "a width past the screen clamps")
eq(size.resolve("width", 200, 200), 179, "a width equal to the screen clamps")
eq(size.resolve("width", 0.95, 200), 179, "a fraction near 1 clamps the same way")
eq(size.resolve("height", 100, 40), 34, "height clamps against winheight")

-- Too small to split at all: better to let Vim decide than to force 1 cell.
eq(size.resolve("width", 0.5, 15), nil, "no room to split returns nil")

-- ── nothing to resolve ──────────────────────────────────────────────────────

eq(size.resolve("width", nil, 200), nil, "nil means let Vim decide")
eq(size.resolve("width", 0, 200), nil, "0 means let Vim decide")
eq(size.resolve("width", -5, 200), nil, "a negative size is not a size")
eq(size.resolve("width", 0/0, 200), nil, "NaN is not a size")
eq(size.resolve("sideways", 80, 200), nil, "an unknown axis resolves to nothing")
eq(size.resolve("width", 80, 0), nil, "a zero-cell screen resolves to nothing")

-- ── fractions for storage ───────────────────────────────────────────────────

eq(size.as_fraction("width", 100, 200), 0.5, "half the screen is 0.5")
eq(size.as_fraction("width", 61, 200), 0.305, "an odd width keeps three decimals")
eq(size.as_fraction("height", 20, 40), 0.5, "height fractions work")
eq(size.as_fraction("width", 0, 200), nil, "a zero-cell window has no fraction")
eq(size.as_fraction("width", 100, 0), nil, "a zero-cell screen has no fraction")

-- The round trip is what makes a remembered size survive a resize.
for _, cells in ipairs({ 20, 61, 100, 150 }) do
  local f = size.as_fraction("width", cells, 200)
  eq(size.resolve("width", f, 200), cells,
    "round trip at " .. cells .. " columns of 200")
end

-- Same fraction, different screen: proportional rather than pinned.
local half = size.as_fraction("width", 100, 200)
eq(size.resolve("width", half, 100), 50, "half of 200 is half of 100 after a resize")
eq(size.resolve("width", half, 400), 200, "and half of 400 when the terminal grows")

print("size_spec: ok")

-- ── precedence: config must win unless the user resized ─────────────────────
--
-- Regression guard. `split_size` on disk used to outrank `split_size` in the
-- user's config, and it was written on every toggle rather than only on a real
-- resize — so a single toggle froze the configured value permanently and
-- editing the config appeared to do nothing. The size is no longer persisted;
-- these pin the two halves of that fix that are testable without a real UI.

local root2 = vim.fn.getcwd()
local ui_path = vim.fn.stdpath("data") .. "/dblite/ui.json"
vim.fn.mkdir(vim.fn.fnamemodify(ui_path, ":h"), "p")

-- A pre-0.8.1 file carrying a size must not have that size honoured.
local f = assert(io.open(ui_path, "w"))
f:write('{"split_dir":{"_default":"right"},"split_size":{"width":0.15}}')
f:close()

package.loaded["dblite"] = nil
package.loaded["dblite.config"] = nil
local d = require("dblite")
eq(d.get_active_conn(), nil, "no connection active in this spec")

-- Placement is still read back; the size beside it is ignored.
d.show_result({ columns = { "k" }, column_types = { "s" },
                rows = { { k = "a" } }, json = "{}", elapsed = 0 }, {})
d.toggle_dbout()

local g = assert(io.open(ui_path, "r"))
local saved = vim.json.decode(g:read("*a"))
g:close()
eq(saved.split_size, nil, "a rewritten ui.json carries no size")
eq(saved.split_dir._default, "right", "the placement from disk is kept")

print("size_spec precedence: ok")
