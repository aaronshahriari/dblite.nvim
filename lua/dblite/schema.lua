local M = {}
local connections = require("dblite.connections")
local config      = require("dblite.config")

local _cache = {}

-- Returns owner, table, column, type per row.
-- Oracle: all_tab_columns filtered to non-system schemas.
-- SQL Server: INFORMATION_SCHEMA.COLUMNS with schema as owner.
-- SQLite: main schema tables/views joined to pragma_table_xinfo.
local ORACLE_SQL = [[
SELECT c.owner, c.table_name, c.column_name, c.data_type
FROM all_tab_columns c
JOIN all_users u ON u.username = c.owner
WHERE u.oracle_maintained = 'N'
AND c.table_name NOT LIKE 'BIN%'
ORDER BY c.owner, c.table_name, c.column_id]]

local MSSQL_SQL = [[
SELECT c.TABLE_SCHEMA AS owner, c.TABLE_NAME AS table_name,
       c.COLUMN_NAME AS column_name, c.DATA_TYPE AS data_type
FROM INFORMATION_SCHEMA.COLUMNS c
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION]]

local SQLITE_SQL = [[
SELECT 'main' AS owner, m.name AS table_name,
       p.name AS column_name, p.type AS data_type
FROM sqlite_schema m
JOIN pragma_table_xinfo(m.name) p
WHERE m.type IN ('table', 'view')
AND m.name NOT LIKE 'sqlite_%'
ORDER BY m.name, p.cid]]

-- Builds:
--   owners       = ["OWNER1", ...]          unique, in appearance order
--   owner_tables = { OWNER1 = ["T1", ...] } tables per owner (no duplicates)
--   columns      = { ["OWNER.TABLE"] = [{name, type}] }
local function parse(rows)
  local owners_seen = {}
  local owners       = {}
  local owner_tables = {}
  local columns      = {}

  for _, row in ipairs(rows) do
    local o = row.owner      or row.OWNER
    local t = row.table_name or row.TABLE_NAME
    local c = row.column_name or row.COLUMN_NAME
    local d = row.data_type  or row.DATA_TYPE

    if o and t then
      if not owners_seen[o] then
        owners_seen[o] = true
        table.insert(owners, o)
        owner_tables[o] = {}
      end

      local fqn = o .. "." .. t
      if not columns[fqn] then
        columns[fqn] = {}
        table.insert(owner_tables[o], t)
      end

      if c then
        table.insert(columns[fqn], { name = c, type = d or "" })
      end
    end
  end

  return { owners = owners, owner_tables = owner_tables, columns = columns }
end

-- Calls callback(schema) — cached per connection, in-flight deduplication.
-- callback receives nil on failure.
function M.get(conn, callback)
  -- Redis has no SQL catalog to introspect; firing one of the queries below at
  -- it would only produce an error reply.
  if conn.type == "redis" then callback(nil); return end

  local id = conn.id
  local e  = _cache[id]
  if e and e.schema   then callback(e.schema); return end
  if e and e.fetching then table.insert(e.cbs, callback); return end

  _cache[id] = { fetching = true, cbs = { callback } }

  local sql = conn.type == "sqlserver" and MSSQL_SQL
    or conn.type == "sqlite" and SQLITE_SQL
    or ORACLE_SQL
  local env = connections.env(conn)
  vim.system(
    { config.binary },
    {
      stdin = sql,
      text  = true,
      env   = env,
    },
    function(result)
      vim.schedule(function()
        local entry = _cache[id]
        if not entry then return end
        local cbs = entry.cbs
        if result.code ~= 0 then
          _cache[id] = nil
          for _, cb in ipairs(cbs) do cb(nil) end
          return
        end
        local ok, data = pcall(vim.json.decode, result.stdout)
        if not ok or type(data) ~= "table" then
          _cache[id] = nil
          for _, cb in ipairs(cbs) do cb(nil) end
          return
        end
        local schema = parse(data.rows or {})
        _cache[id] = { schema = schema }
        for _, cb in ipairs(cbs) do cb(schema) end
      end)
    end)
end

function M.invalidate(conn_id) _cache[conn_id] = nil end
function M.prefetch(conn) M.get(conn, function() end) end

-- Synchronous, non-blocking peek at the cache. Returns the schema if it's
-- already warm, otherwise nil — never kicks off a fetch.
function M.peek(conn)
  local e = _cache[conn.id]
  return e and e.schema or nil
end

return M
