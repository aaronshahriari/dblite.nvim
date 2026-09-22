-- Bind-parameter handling for dblite: reading dblite.binds.json, finding
-- `:name` references in SQL, and substituting values into a statement.
-- Pure text/IO — no UI state — so both the interactive run paths and the
-- headless `dblite.inline` API share it.

local M = {}

function M.file_path()
  return vim.fn.getcwd() .. "/dblite.binds.json"
end

function M.load_file()
  local f = io.open(M.file_path(), "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  return (ok and type(data) == "table") and data or {}
end

function M.flatten(tbl, prefix, out)
  out = out or {}
  for k, v in pairs(tbl) do
    local key = prefix and (prefix .. "." .. k) or k
    if type(v) == "table" then
      M.flatten(v, key, out)
    else
      out[key] = v
    end
  end
  return out
end

-- JSON number → verbatim; "~expr" → raw SQL; string → auto-quoted + escaped
function M.format_value(v)
  if type(v) == "number" then return tostring(v) end
  local s = tostring(v)
  if s:sub(1, 1) == "~" then return s:sub(2) end
  return "'" .. s:gsub("'", "''") .. "'"
end

-- Find :bind references, ignoring anything that only *looks* like one: text
-- inside string literals, quoted identifiers or comments, and — crucially — the
-- identifier after a `::` cast / scope-resolution operator (e.g. `col::type`,
-- `SCHEMA::obj`). Without the last rule a token like `x::refs` was wrongly
-- reported as a missing bind `refs`. We blank those spans (preserving length)
-- before scanning so column/byte offsets stay intact.
-- Whether `conn` uses bind parameters at all.
--
-- Redis keys are colon-namespaced (`user:1042`, `queue:jobs`, `session:a83f`),
-- which is character-for-character the SQL bind syntax `:name`. Binds are a SQL
-- feature, so for Redis the answer is no — otherwise half of every key name
-- would be read as a missing parameter.
function M.supported(conn)
  return not (conn and conn.type == "redis")
end

-- parse_names, but scoped to a connection: no binds for a source that has none.
function M.names_for(conn, sql)
  if not M.supported(conn) then return {} end
  return M.parse_names(sql)
end

function M.parse_names(sql)
  local seen, names = {}, {}
  local blank = function(s) return string.rep(" ", #s) end
  local stripped = sql
    :gsub("/%*.-%*/", blank)      -- /* block comments */
    :gsub("%-%-[^\n]*", blank)    -- -- line comments
    :gsub("'[^']*'", blank)       -- 'string literals'
    :gsub('"[^"]*"', blank)       -- "quoted identifiers"
    :gsub("::", "  ")             -- cast / scope operator, not a bind
  for raw in stripped:gmatch(":[a-zA-Z_][a-zA-Z0-9_.]*") do
    local key = raw:sub(2):gsub("%.+$", "")
    if not seen[key] then seen[key] = true; table.insert(names, key) end
  end
  return names
end

function M.apply(sql, binds)
  local sorted = vim.tbl_keys(binds)
  table.sort(sorted, function(a, b) return #a > #b end)
  for _, name in ipairs(sorted) do
    local val  = M.format_value(binds[name])
    local pat  = name:gsub("%.", "%%.")           -- escape dots for Lua pattern
    local repl = val:gsub("%%", "%%%%")           -- escape % in replacement string
    sql = sql:gsub(":" .. pat .. "([^a-zA-Z0-9_.])", repl .. "%1")
    if sql:sub(-(#name + 1)) == ":" .. name then
      sql = sql:sub(1, -(#name + 2)) .. val
    end
  end
  return sql
end

-- Names referenced by `sql` that `binds` has no value for.
function M.missing(sql, binds)
  return vim.tbl_filter(function(n) return binds[n] == nil end, M.parse_names(sql))
end

return M
