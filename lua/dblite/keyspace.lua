local M = {}
local connections = require("dblite.connections")
local config      = require("dblite.config")

-- Redis has no catalog to introspect and no language server, so completion is
-- built from the live instance: the key namespaces, the server's own command
-- list, and a hash's fields on demand.
--
-- The cache mirrors dblite.schema — per connection, with in-flight
-- deduplication — but the shape is Redis-specific:
--
--   keys     = { "user:1042", ... }              in arrival order
--   types    = { ["user:1042"] = "hash", ... }
--   commands = { { name, arity, flags }, ... }
--
-- Namespace levels are not precomputed: the completion source derives the next
-- separator from `keys` against whatever has been typed, which handles a
-- keyspace of any depth without a second index to keep in sync.
local _cache  = {}   -- conn.id -> { data = ..., fetching = true, cbs = {} }
local _fields = {}   -- conn.id -> { [key] = { ... } | "fetching" }

local function opts()
  local redis = config.redis or {}
  return redis.completion or {}
end

function M.enabled()
  return opts().enabled ~= false
end

local function max_keys()
  local n = opts().max_keys
  if n == nil then return 5000 end
  return n
end

local function run(conn, command, max_rows, callback)
  local cmd = { config.binary }
  if max_rows and max_rows > 0 then
    table.insert(cmd, "--max-rows")
    table.insert(cmd, tostring(max_rows))
  end
  vim.system(cmd, {
    stdin = command,
    text  = true,
    env   = connections.env(conn),
  }, function(result)
    local rows = nil
    if result.code == 0 then
      local ok, data = pcall(vim.json.decode, result.stdout)
      if ok and type(data) == "table" then rows = data.rows or {} end
    end
    callback(rows)
  end)
end

-- Calls callback(data), or callback(nil) on failure. Cached per connection with
-- in-flight deduplication, so a burst of keystrokes causes one fetch.
function M.get(conn, callback)
  if conn.type ~= "redis" or not M.enabled() then callback(nil); return end

  local id = conn.id
  local e  = _cache[id]
  if e and e.data     then callback(e.data); return end
  if e and e.fetching then table.insert(e.cbs, callback); return end

  _cache[id] = { fetching = true, cbs = { callback } }

  local pending  = 2
  local keys_res = nil
  local cmds_res = nil

  local function finish()
    pending = pending - 1
    if pending > 0 then return end
    vim.schedule(function()
      local entry = _cache[id]
      if not entry then return end
      local cbs = entry.cbs

      -- The command list alone is still worth caching: it makes completion
      -- useful on an empty or unreadable keyspace.
      if keys_res == nil and cmds_res == nil then
        _cache[id] = nil
        for _, cb in ipairs(cbs) do cb(nil) end
        return
      end

      local keys, types = {}, {}
      for _, row in ipairs(keys_res or {}) do
        local key = row.key
        if type(key) == "string" and key ~= "" then
          table.insert(keys, key)
          types[key] = row.type or ""
        end
      end

      local commands = {}
      for _, row in ipairs(cmds_res or {}) do
        if type(row.name) == "string" and row.name ~= "" then
          table.insert(commands, {
            name  = row.name:upper(),
            arity = row.arity,
            flags = row.flags or "",
          })
        end
      end
      table.sort(commands, function(a, b) return a.name < b.name end)

      local data = { keys = keys, types = types, commands = commands }
      _cache[id] = { data = data }
      for _, cb in ipairs(cbs) do cb(data) end
    end)
  end

  run(conn, "KEYS *", max_keys(), function(rows) keys_res = rows; finish() end)
  run(conn, "COMMAND", 0,         function(rows) cmds_res = rows; finish() end)
end

-- Non-blocking peek; never starts a fetch.
function M.peek(conn)
  local e = _cache[conn.id]
  return e and e.data or nil
end

function M.prefetch(conn) M.get(conn, function() end) end

function M.invalidate(conn_id)
  _cache[conn_id]  = nil
  _fields[conn_id] = nil
end

-- A hash's field names, fetched on demand and cached. Returns the list if
-- already warm, otherwise nil and starts a fetch.
function M.peek_fields(conn, key)
  if conn.type ~= "redis" or not M.enabled() then return nil end
  local per_conn = _fields[conn.id]
  local hit = per_conn and per_conn[key]
  if type(hit) == "table" then return hit end
  if hit == "fetching" then return nil end

  _fields[conn.id] = per_conn or {}
  _fields[conn.id][key] = "fetching"

  run(conn, "HKEYS " .. key, max_keys(), function(rows)
    vim.schedule(function()
      local store = _fields[conn.id]
      if not store then return end
      if rows == nil then
        store[key] = nil          -- allow a retry rather than caching failure
        return
      end
      local fields = {}
      for _, row in ipairs(rows) do
        if type(row.value) == "string" then table.insert(fields, row.value) end
      end
      store[key] = fields
    end)
  end)
  return nil
end

return M
