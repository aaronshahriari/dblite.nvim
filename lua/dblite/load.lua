-- dblite.load — inline SQL*Loader-style CSV loading.
--
-- The dblite binary is pure JDBC with no Oracle client, so this does NOT shell
-- out to real sqlldr. It parses a practical subset of the control-file syntax,
-- reads the referenced CSV, and turns each row into an INSERT statement. The
-- caller (init.lua) previews the generated SQL and runs it through the existing
-- script-mode runner once the user commits.
--
-- This module is pure (no vim UI) so it can be unit-tested headlessly.

local M = {}

-- Build a case-insensitive Lua pattern from a literal keyword.
local function ci(word)
  return (word:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

-- Whole-word (case-insensitive) presence test.
local function has_word(text, w)
  return text:match("%f[%a]" .. ci(w) .. "%f[%A]") ~= nil
end

-- Strip `-- ...` line comments, respecting single/double quoted values so a
-- separator like `TERMINATED BY '--'` is left intact.
local function strip_comments(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local res, i, n, q = {}, 1, #line, nil
    while i <= n do
      local c = line:sub(i, i)
      if q then
        res[#res + 1] = c
        if c == q then q = nil end
        i = i + 1
      elseif c == "'" or c == '"' then
        q = c; res[#res + 1] = c; i = i + 1
      elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
        break -- rest of the line is a comment
      else
        res[#res + 1] = c; i = i + 1
      end
    end
    out[#out + 1] = table.concat(res)
  end
  return table.concat(out, "\n")
end

-- Split a comma-separated string at top level (commas inside parens are kept),
-- so a column spec like `amount DECIMAL EXTERNAL(9,2)` isn't split mid-type.
local function split_top(s)
  local parts, cur, depth = {}, {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "(" then depth = depth + 1; cur[#cur + 1] = c
    elseif c == ")" then depth = depth - 1; cur[#cur + 1] = c
    elseif c == "," and depth == 0 then
      parts[#parts + 1] = table.concat(cur); cur = {}
    else
      cur[#cur + 1] = c
    end
  end
  parts[#parts + 1] = table.concat(cur)
  return parts
end

-- Parse a SQL*Loader control block into a control table, or nil + error.
-- Returns: { infile, table, mode, skip, sep, enclosed, trailing, columns = {...} }
function M.parse(text)
  text = strip_comments(text or "")

  if not text:match("^%s*" .. ci("LOAD") .. "%s+" .. ci("DATA")) then
    return nil, "not a LOAD DATA control block (must start with 'LOAD DATA')"
  end

  -- INFILE: quoted path, or a bareword (e.g. INFILE *)
  local infile = text:match(ci("INFILE") .. "%s*'([^']*)'")
    or text:match(ci("INFILE") .. '%s*"([^"]*)"')
    or text:match(ci("INFILE") .. "%s+(%S+)")
  if not infile then return nil, "INFILE clause is required" end
  if infile == "*" then
    return nil, "INFILE * (inline BEGINDATA) is not supported — point INFILE at a file"
  end

  local table_name = text:match(ci("INTO") .. "%s+" .. ci("TABLE") .. "%s+([%w_%.\"$#]+)")
  if not table_name then return nil, "INTO TABLE <name> clause is required" end

  local mode = "append"
  if has_word(text, "TRUNCATE") then mode = "truncate"
  elseif has_word(text, "REPLACE") then mode = "replace"
  elseif has_word(text, "INSERT") then mode = "insert"
  end

  local skip = tonumber(text:match(ci("SKIP") .. "%s+(%d+)")) or 0

  -- FIELDS TERMINATED BY — literal quoted char, or X'hh' hex (e.g. tab = X'09')
  local sep = text:match(ci("TERMINATED") .. "%s+" .. ci("BY") .. "%s*'([^']*)'")
    or text:match(ci("TERMINATED") .. "%s+" .. ci("BY") .. '%s*"([^"]*)"')
  local hexsep = text:match(ci("TERMINATED") .. "%s+" .. ci("BY") .. "%s*[Xx]'(%x%x)'")
  if hexsep then sep = string.char(tonumber(hexsep, 16)) end
  if not sep or sep == "" then sep = "," end

  -- (OPTIONALLY) ENCLOSED BY — defaults to " since this is CSV-focused
  local enclosed = text:match(ci("ENCLOSED") .. "%s+" .. ci("BY") .. "%s*'([^']*)'")
    or text:match(ci("ENCLOSED") .. "%s+" .. ci("BY") .. '%s*"([^"]*)"')
    or '"'

  local trailing = text:match(ci("TRAILING") .. "%s+" .. ci("NULLCOLS")) ~= nil

  -- Column list: first balanced (...) group. Take the leading identifier of
  -- each entry; any trailing per-column datatype/transform is ignored.
  local paren = text:match("%b()")
  if not paren then return nil, "column list ( col1, col2, ... ) is required" end
  local columns = {}
  for _, entry in ipairs(split_top(paren:sub(2, -2))) do
    local name = entry:match("^%s*([%w_%.\"$#]+)")
    if name then columns[#columns + 1] = name end
  end
  if #columns == 0 then return nil, "no columns found in the column list" end

  return {
    infile   = infile,
    table    = table_name,
    mode     = mode,
    skip     = skip,
    sep      = sep,
    enclosed = enclosed,
    trailing = trailing,
    columns  = columns,
  }
end

-- Read a delimited file into a list of records (each a list of field strings).
-- RFC-4180-ish: doubled enclosure = literal, quoted fields may contain the
-- separator and newlines, \r\n and \n both terminate records. Blank lines are
-- skipped. Assumes a single-character separator/enclosure.
function M.read_csv(path, sep, enclosed)
  local f, oerr = io.open(path, "rb")
  if not f then return nil, "cannot read " .. path .. ": " .. tostring(oerr) end
  local data = f:read("*a") or ""
  f:close()

  local sepc = (sep and sep ~= "") and sep:sub(1, 1) or ","
  local enc = (enclosed and enclosed ~= "") and enclosed:sub(1, 1) or nil

  local records, row, field = {}, {}, {}
  local inq, i, n = false, 1, #data

  local function push_field() row[#row + 1] = table.concat(field); field = {} end
  local function push_row()
    push_field()
    if not (#row == 1 and row[1] == "") then records[#records + 1] = row end
    row = {}
  end

  while i <= n do
    local c = data:sub(i, i)
    if inq then
      if enc and c == enc then
        if data:sub(i + 1, i + 1) == enc then
          field[#field + 1] = enc; i = i + 2
        else
          inq = false; i = i + 1
        end
      else
        field[#field + 1] = c; i = i + 1
      end
    elseif enc and c == enc and #field == 0 then
      inq = true; i = i + 1 -- opening quote only at field start
    elseif c == sepc then
      push_field(); i = i + 1
    elseif c == "\r" then
      i = i + 1
    elseif c == "\n" then
      push_row(); i = i + 1
    else
      field[#field + 1] = c; i = i + 1
    end
  end
  if #field > 0 or #row > 0 then push_row() end

  return records
end

-- Is `s` a plain numeric literal safe to emit unquoted? Leading-zero integers
-- (e.g. "007") stay quoted so zip-code-like strings keep their zeros.
local function is_number(s)
  s = s:match("^%s*(.-)%s*$")
  if s == "" or s:match("^[-+]?0%d") then return false end
  return s:match("^[-+]?%d+$") ~= nil
    or s:match("^[-+]?%d*%.%d+$") ~= nil
    or s:match("^[-+]?%d+%.%d*$") ~= nil
end

-- Format one CSV field as a SQL value: empty/nil → NULL, numeric → literal,
-- else single-quoted with '' escaping.
local function format_value(v)
  if v == nil or v == "" then return "NULL" end
  if is_number(v) then return (v:gsub("%s", "")) end
  return "'" .. v:gsub("'", "''") .. "'"
end

-- Build INSERT statements from parsed control + CSV records.
-- Returns { sql, statements = {...}, count, skipped, errors = {...} }.
function M.build(control, records, db_type)
  local cols    = control.columns
  local ncols   = #cols
  local collist = table.concat(cols, ", ")
  local stmts, errors = {}, {}

  if control.mode == "truncate" then
    local verb = db_type == "sqlite" and "DELETE FROM " or "TRUNCATE TABLE "
    stmts[#stmts + 1] = verb .. control.table .. ";"
  elseif control.mode == "replace" then
    stmts[#stmts + 1] = "DELETE FROM " .. control.table .. ";"
  end

  local skip    = control.skip or 0
  local skipped = math.min(skip, #records)
  local count   = 0

  for ri = skip + 1, #records do
    local rec = records[ri]
    if #rec < ncols and not control.trailing then
      errors[#errors + 1] = string.format(
        "row %d: %d field(s) for %d column(s) — add TRAILING NULLCOLS to pad",
        ri, #rec, ncols)
    else
      local vals = {}
      for ci_ = 1, ncols do vals[ci_] = format_value(rec[ci_]) end
      stmts[#stmts + 1] = string.format("INSERT INTO %s (%s) VALUES (%s);",
        control.table, collist, table.concat(vals, ", "))
      count = count + 1
    end
  end

  return {
    sql        = table.concat(stmts, "\n"),
    statements = stmts,
    count      = count,
    skipped    = skipped,
    errors     = errors,
  }
end

return M
