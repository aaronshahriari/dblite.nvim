-- Re-indenting JSON text.
--
-- The obvious implementation — `vim.json.decode` then re-encode — is wrong
-- here: Lua tables are unordered, so object keys come back shuffled, `1.0`
-- becomes `1`, and an empty object is indistinguishable from an empty array.
-- What lands in the result window has to be the value the server returned, so
-- this walks the raw text and changes nothing but the whitespace between
-- tokens.

local M = {}

local WS = { [" "] = true, ["\t"] = true, ["\r"] = true, ["\n"] = true }

-- End index of the string literal that starts at `i` (the opening quote), or
-- `#text` when the literal is unterminated.
local function string_end(text, i)
  local j = i + 1
  local n = #text
  while j <= n do
    local c = text:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == '"' then
      return j
    else
      j = j + 1
    end
  end
  return n
end

-- Position of the next non-whitespace character at or after `p`.
local function next_solid(text, p)
  local j = text:find("[^ \t\r\n]", p)
  if not j then return nil, nil end
  return text:sub(j, j), j
end

--- Pretty-print JSON text. Returns nil when `text` is not a string.
--- Malformed input is re-indented as best it can be rather than rejected: a
--- value that failed to parse is still more readable spread over lines.
---@param text string
---@param indent integer|nil  spaces per level (default 2)
---@return string|nil
function M.format(text, indent)
  if type(text) ~= "string" then return nil end
  local pad = string.rep(" ", indent or 2)
  local out, depth = {}, 0
  local i, n = 1, #text

  local function newline()
    out[#out + 1] = "\n" .. pad:rep(depth)
  end

  while i <= n do
    local c = text:sub(i, i)
    if c == '"' then
      local j = string_end(text, i)
      out[#out + 1] = text:sub(i, j)
      i = j + 1
    elseif c == "{" or c == "[" then
      local close = c == "{" and "}" or "]"
      local nxt, nj = next_solid(text, i + 1)
      if nxt == close then
        -- An empty container reads worse split across two lines.
        out[#out + 1] = c .. close
        i = nj + 1
      else
        out[#out + 1] = c
        depth = depth + 1
        newline()
        i = i + 1
      end
    elseif c == "}" or c == "]" then
      depth = math.max(0, depth - 1)
      newline()
      out[#out + 1] = c
      i = i + 1
    elseif c == "," then
      out[#out + 1] = ","
      newline()
      i = i + 1
    elseif c == ":" then
      out[#out + 1] = ": "
      i = i + 1
    elseif WS[c] then
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  return table.concat(out)
end

--- Pretty-printed `text` split into buffer lines.
---@return string[]
function M.lines(text, indent)
  local formatted = M.format(text, indent)
  if not formatted then return {} end
  return vim.split(formatted, "\n", { plain = true })
end

--- Whether `text` parses as a JSON object or array. Scalars are excluded: a
--- bare number or quoted string is a value, not a document worth its own view.
---@param text any
---@return boolean
function M.is_document(text)
  if type(text) ~= "string" then return false end
  local first = text:match("^%s*(.)")
  if first ~= "{" and first ~= "[" then return false end
  return (pcall(vim.json.decode, text))
end

return M
