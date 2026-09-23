local M = {}

-- Try to detect the statement under the cursor via treesitter.
-- Uses get_node() at cursor and walks up to find the top-level statement
-- (direct child of root), which corresponds to one SQL statement.
local function try_treesitter(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos   = { cursor[1] - 1, cursor[2] },
  })
  if not node then return nil end

  -- Walk up until stmt is a direct child of root.
  -- Root has no parent; its children are the top-level statements.
  local stmt = node
  while stmt:parent() and stmt:parent():parent() do
    stmt = stmt:parent()
  end

  -- If stmt has no parent it IS the root — cursor on empty/whitespace-only file
  if not stmt:parent() then return nil end

  local sr, sc, er, ec = stmt:range()
  local ok, text = pcall(vim.treesitter.get_node_text, stmt, bufnr)
  if not ok or not text or text:match("^%s*$") then return nil end
  return sr, sc, er, ec, text
end

-- Fallback: find statement bounds via blank-line / semicolon separators.
local function fallback(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n      = #lines

  local function blank(row)    return (lines[row + 1] or ""):match("^%s*$") ~= nil end
  local function has_semi(row) return (lines[row + 1] or ""):match(";%s*$") ~= nil end

  local start_row = cursor
  while start_row > 0 and not blank(start_row - 1) and not has_semi(start_row - 1) do
    start_row = start_row - 1
  end

  local end_row = cursor
  while end_row < n - 1 and not has_semi(end_row) and not blank(end_row + 1) do
    end_row = end_row + 1
  end

  local text_lines = {}
  for i = start_row + 1, end_row + 1 do
    table.insert(text_lines, lines[i] or "")
  end
  local end_col = #(lines[end_row + 1] or "")
  return start_row, 0, end_row, end_col, table.concat(text_lines, "\n")
end

-- ── line-oriented statements ───────────────────────────────────────────────
-- Redis has no statement terminator, so one line is one command. A single
-- command still has to be breakable across lines, though: a `JSON.SET` with a
-- document argument is otherwise one unreadable line.
--
-- A command continues onto the next line when either
--   * a quote opened on the line is still open at its end — the newline is
--     part of the value, which is how a JSON argument gets to span lines; or
--   * the line ends with a backslash outside quotes, which is dropped.
--
-- Outside quotes `#` starts a comment; inside one it is ordinary data.

--- Scans one line, carrying quote state in from the previous.
---@param line string
---@param quote string|nil  the quote character still open, or nil
---@return string|nil quote      quote state at end of line
---@return boolean continues     whether the command continues onto the next line
---@return string code           the line with any comment and continuation
---                              backslash removed, ready to be joined
local function scan_line(line, quote)
  local i, n = 1, #line
  local code_end = n            -- where the code stops (before any comment)

  while i <= n do
    local c = line:sub(i, i)
    if quote == '"' then
      -- A backslash escapes the next character, including a quote.
      if c == "\\" then i = i + 2
      elseif c == '"' then quote = nil; i = i + 1
      else i = i + 1 end
    elseif quote == "'" then
      -- Single quotes are literal apart from \', as in redis-cli.
      if c == "\\" and line:sub(i + 1, i + 1) == "'" then i = i + 2
      elseif c == "'" then quote = nil; i = i + 1
      else i = i + 1 end
    else
      if c == "#" then code_end = i - 1; break end
      if c == '"' or c == "'" then quote = c end
      i = i + 1
    end
  end

  -- Inside a quote the newline is part of the value, so the line is kept whole.
  if quote then return quote, true, line end

  local code = line:sub(1, code_end)

  -- A lone trailing backslash outside quotes continues explicitly, and is not
  -- part of the command. Checked against the code, so a backslash inside a
  -- comment does not count.
  local before, trailing = code:match("^(.-)\\(%s*)$")
  if before then
    return nil, true, before .. trailing
  end
  return nil, false, code
end

--- Whether `line` holds no command at all: blank, or only a comment.
---@param line string
---@return boolean
local function blank_or_comment(line)
  local t = vim.trim(line)
  return t == "" or t:sub(1, 1) == "#"
end

--- The logical command containing `lnum` (1-indexed), as a first/last pair.
--- Walks back to the first line that is not a continuation of an earlier one,
--- then forward while lines keep continuing.
---@param lines string[]
---@param lnum integer
---@return integer first
---@return integer last
function M.logical_range(lines, lnum)
  local n = #lines
  if n == 0 then return lnum, lnum end
  lnum = math.max(1, math.min(n, lnum))

  -- Find the start: scan from the top, tracking which line begins a command.
  local quote, continues = nil, false
  local first = 1
  for i = 1, lnum do
    if not continues then first = i end
    quote, continues = scan_line(lines[i], quote)
  end

  -- Then forward while the command is still open.
  local last = lnum
  while continues and last < n do
    last = last + 1
    quote, continues = scan_line(lines[last], quote)
  end

  return first, last
end

--- The text of the logical command spanning `first`..`last`, as the command
--- the user means: comments removed and continuation backslashes dropped.
---
--- Sending the raw lines instead would hand the tokenizer a literal `\\` as an
--- argument, so `HSET k \\` + `f v` would store a field named `\\`.
---@param lines string[]
---@param first integer
---@param last integer
---@return string
function M.logical_text(lines, first, last)
  local quote = nil
  local pieces = {}
  -- Quote state has to be rebuilt from the command's first line, or a line
  -- inside a quoted value would have its `#` read as a comment.
  for i = first, last do
    local code
    quote, _, code = scan_line(lines[i] or "", quote)
    pieces[#pieces + 1] = code
  end
  return table.concat(pieces, "\n")
end

--- Counts logical commands in `lines`, ignoring blanks and comments. A
--- whole-buffer run uses this to tell one command from many.
---@param lines string[]
---@return integer
function M.logical_count(lines)
  local count, quote, continues = 0, nil, false
  for _, line in ipairs(lines) do
    if not continues and not blank_or_comment(line) then count = count + 1 end
    quote, continues = scan_line(line, quote)
  end
  return count
end

-- Returns the given line range, grown to whole logical commands. Redis has no
-- statement terminator, so growing to the next blank line or semicolon the way
-- the SQL path does would swallow every following command.
local function lines_verbatim(bufnr, line1, line2)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n     = #lines
  if n == 0 then return nil end

  -- Grow each edge to the whole command it touches, so selecting the middle of
  -- a continued command still runs all of it.
  local lo = math.max(1, math.min(line1, line2))
  local hi = math.min(n, math.max(line1, line2))
  local first = select(1, M.logical_range(lines, lo))
  local last  = select(2, M.logical_range(lines, hi))

  local start_row = first - 1
  local end_row   = last - 1

  local text = M.logical_text(lines, first, last)
  if text:match("^%s*$") then return nil end
  return start_row, 0, end_row, #(lines[end_row + 1] or ""), text
end

-- Expand a line range (1-indexed, inclusive) to cover the whole statement(s)
-- it touches, using the same blank-line / semicolon separators as the
-- at-cursor fallback: the top edge grows up to the start of the first statement
-- and the bottom edge grows down to the end of the last one. Returns sr, sc, er,
-- ec (0-indexed) and the concatenated text, or nil if the span is blank.
--
-- `line_mode` takes the range exactly as given instead — see lines_verbatim.
function M.at_range(bufnr, line1, line2, line_mode)
  if line_mode then return lines_verbatim(bufnr, line1, line2) end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n     = #lines
  if n == 0 then return nil end

  local function blank(row)    return (lines[row + 1] or ""):match("^%s*$") ~= nil end
  local function has_semi(row) return (lines[row + 1] or ""):match(";%s*$") ~= nil end

  local start_row = math.max(0,     math.min(line1, line2) - 1)  -- 0-indexed
  local end_row   = math.min(n - 1, math.max(line1, line2) - 1)

  while start_row > 0 and not blank(start_row - 1) and not has_semi(start_row - 1) do
    start_row = start_row - 1
  end
  while end_row < n - 1 and not has_semi(end_row) and not blank(end_row + 1) do
    end_row = end_row + 1
  end

  local text_lines = {}
  for i = start_row + 1, end_row + 1 do
    table.insert(text_lines, lines[i] or "")
  end
  local text = table.concat(text_lines, "\n")
  if text:match("^%s*$") then return nil end
  local end_col = #(lines[end_row + 1] or "")
  return start_row, 0, end_row, end_col, text
end

-- Returns sr, sc, er, ec (0-indexed), query_text for the statement at cursor.
-- Returns nil if the cursor is on a blank line.
--
-- `line_mode` treats the cursor's line as the whole statement, for sources
-- that are one command per line rather than terminator-delimited.
function M.at_cursor(bufnr, line_mode)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cur = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1] or ""
  if cur:match("^%s*$") then return nil end

  if line_mode then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local first, last = M.logical_range(lines, cursor_line + 1)
    local text = M.logical_text(lines, first, last)
    if text:match("^%s*$") then return nil end
    return first - 1, 0, last - 1, #(lines[last] or ""), text
  end

  local ts_ok, sr, sc, er, ec, text = pcall(try_treesitter, bufnr)
  if ts_ok and sr then return sr, sc, er, ec, text end
  return fallback(bufnr)
end

return M
