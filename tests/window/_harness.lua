-- Shared scaffolding for the pty-based window specs. Each spec runs in its own
-- nvim so that session state — a deliberate resize in particular — cannot leak
-- from one case into the next and quietly invalidate it.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local H = {}

H.out    = {}
H.failed = false
H.COLS   = tonumber(vim.env.DBLITE_SPEC_COLS) or 200

function H.check(want, got, what)
  if want == got then
    H.out[#H.out + 1] = string.format("ok   %-52s %s", what, tostring(got))
  else
    H.failed = true
    H.out[#H.out + 1] = string.format("FAIL %-52s want %s, got %s",
      what, tostring(want), tostring(got))
  end
end

--- The dbout window: every placement returns the cursor to the editor.
function H.dbout()
  local wins = vim.api.nvim_list_wins()
  if #wins ~= 2 then return nil end
  local cur = vim.api.nvim_get_current_win()
  return wins[1] == cur and wins[2] or wins[1]
end

function H.width()
  local w = H.dbout()
  return w and vim.api.nvim_win_get_width(w) or -1
end

function H.editor_width()
  return vim.api.nvim_win_get_width(vim.api.nvim_get_current_win())
end

function H.show()
  require("dblite").show_result({
    columns = { "k" }, column_types = { "s" },
    rows = { { k = "a" } }, json = "{}", elapsed = 0,
  }, {})
end

--- Cells a fraction of the terminal comes to, matching dblite.size's rounding.
function H.frac(f)
  return math.floor(H.COLS * f + 0.5)
end

function H.finish()
  local f = assert(io.open(vim.env.DBLITE_SPEC_OUT, "w"))
  f:write(table.concat(H.out, "\n") .. "\n")
  f:close()
end

return H
