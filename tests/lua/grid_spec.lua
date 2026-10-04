-- Every `|` in the grid has to sit in the same screen column on every line.
-- Values are not ASCII: a curly quote is three bytes and one column, a CJK
-- glyph is three bytes and two columns, and padding any of them to a byte
-- count puts that row's separators somewhere of their own.

vim.o.columns = 200
vim.o.lines   = 50

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local dblite = require("dblite")
local config = require("dblite.config")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

config.binary = "/bin/false"   -- nothing here runs a query
config.max_col_width = 24


-- The screen columns at which a line's ` | ` separators sit.
local function bar_columns(line)
  local cols, w = {}, 0
  for i = 0, vim.fn.strchars(line) - 1 do
    local ch = vim.fn.strcharpart(line, i, 1)
    if ch == "|" then table.insert(cols, w) end
    w = w + vim.fn.strdisplaywidth(ch)
  end
  return table.concat(cols, ",")
end

local function render(rows)
  dblite.show_result({
    columns      = { "source", "title", "issue_date" },
    column_types = { "string", "string", "string" },
    rows         = rows,
    elapsed      = 0.01,
  }, { query = "select 1", conn = "spec_grid" })
  local wins = vim.api.nvim_list_wins()
  assert(#wins == 2, "dbout should be open beside the editor")
  local cur = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(wins[1] == cur and wins[2] or wins[1])
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Line 1 is the status line, 2 blank, 3 the header, 4 the rule, then rows.
  local body = {}
  for i = 3, #lines do
    if lines[i] ~= "" then table.insert(body, lines[i]) end
  end
  return body
end

-- ── alignment ───────────────────────────────────────────────────────────────

local rows = {
  { source = "Dan Luu",        title = "There's no point at which turning your brain off", issue_date = "2026-10-04" },
  { source = "Florida Phoenix", title = "Attorney: Botched Tennessee execution should ‘shock’ us", issue_date = "2026-10-04" },
  { source = "Financial Times", title = "Australian authorities probe Flydubai attacker’s past", issue_date = "2026-10-04" },
  { source = "DHH",            title = "I'm sorry, Dave", issue_date = "2026-10-04" },
  { source = "日経",            title = "半導体の需要", issue_date = "2026-10-04" },
  { source = "Wrapped",        title = "two\nlines", issue_date = "2026-10-04" },
}

local body = render(rows)
local want = bar_columns(body[1])
assert(want:find(","), "the header should have two separators, got " .. want)
for i, line in ipairs(body) do
  if i ~= 2 then -- the rule uses -+- rather than ' | '
    eq(bar_columns(line), want, "separators on body line " .. i)
  end
end

-- The rule's `+` lands on the same columns as the header's `|`.
eq((bar_columns(body[2]:gsub("%+", "|"))), want, "the rule lines up with the separators")

-- ── truncation is by screen column, and keeps whole characters ──────────────

for i, line in ipairs(body) do
  local first_bar = line:find("|")
  if i > 2 and first_bar then
    local title = vim.trim(line:sub(first_bar + 1, (line:find("|", first_bar + 1) or 0) - 1))
    assert(vim.fn.strdisplaywidth(title) <= config.max_col_width,
      "title cell is wider than max_col_width: " .. title)
    assert(not title:find("\239\191\189"), "truncation split a character: " .. title)
  end
end

-- A truncated value ends in a single ellipsis, with the text before it intact.
local trunc = body[4] -- the Botched Tennessee row
assert(trunc:find("…", 1, true), "a long title is truncated: " .. trunc)

-- An embedded newline is escaped, so the row stays one line.
assert(body[#body]:find("two\\nlines", 1, true), "newlines are escaped: " .. body[#body])

print("grid_spec: ok")
