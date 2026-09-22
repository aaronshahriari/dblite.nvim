local M = {}

local function storage_path()
  return vim.fn.stdpath("data") .. "/dblite/connections.json"
end

local function load()
  local p = storage_path()
  local f = io.open(p, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  return (ok and type(data) == "table") and data or {}
end

local function save(conns)
  local p = storage_path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = assert(io.open(p, "w"), "dblite: cannot write to " .. p)
  f:write(vim.json.encode(conns))
  f:close()
  vim.fn.system({ "chmod", "600", p })
end

local function gen_id()
  return string.format("%d_%04d", os.time(), math.random(1000, 9999))
end

local function normalize_sqlite_path(path)
  assert(type(path) == "string" and path ~= "", "dblite: path is required")
  assert(path ~= ":memory:", "dblite: :memory: databases are not supported")
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local stat = vim.uv.fs_stat(path)
  assert(stat and stat.type == "file", "dblite: SQLite database must be an existing file: " .. path)
  return path
end

local function validate(conn)
  local t = conn.type or "oracle"
  local auth = conn.auth or "sql"
  assert(t == "oracle" or t == "sqlserver" or t == "sqlite" or t == "redis",
    "dblite: type must be 'oracle', 'sqlserver', 'sqlite', or 'redis'")
  assert(type(conn.name) == "string" and conn.name ~= "", "dblite: name is required")
  if t == "sqlite" then
    conn.path = normalize_sqlite_path(conn.path)
    return
  end
  if t == "redis" then
    -- Redis needs only a host: auth is optional, and the database is an index
    -- rather than a name.
    assert(type(conn.host) == "string" and conn.host ~= "", "dblite: host is required")
    local db = tonumber(conn.db or 0)
    assert(db and db >= 0 and db == math.floor(db),
      "dblite: db must be a non-negative integer")
    conn.db = db
    return
  end
  assert(type(conn.host) == "string" and conn.host ~= "", "dblite: host is required")
  if auth ~= "kerberos" then
    assert(type(conn.user) == "string" and conn.user ~= "", "dblite: user is required")
  end
  if t == "sqlserver" then
    assert(type(conn.database) == "string" and conn.database ~= "", "dblite: database is required")
  else
    assert(type(conn.service) == "string" and conn.service ~= "", "dblite: service is required")
  end
end

-- Returns all saved connections as a list.
function M.list()
  return load()
end

-- Returns the connection with the given id, or nil.
function M.get(id)
  for _, c in ipairs(load()) do
    if c.id == id then return c end
  end
end

-- Returns the connection with the given name, or nil.
function M.get_by_name(name)
  for _, c in ipairs(load()) do
    if c.name == name then return c end
  end
end

-- Saves a new connection.
-- Oracle required fields: name, host, user, service. Port defaults to 1521.
-- SQL Server required fields: name, host, user, database. Port defaults to 1433.
-- SQLite required fields: name, path. The path must name an existing file.
-- SQL Server with auth="kerberos": user/password are optional.
-- type defaults to "oracle" when omitted (backward compat).
function M.add(conn)
  local t    = conn.type or "oracle"
  local auth = conn.auth or "sql"
  validate(conn)

  local default_port = t == "sqlserver" and 1433
    or t == "redis" and 6379
    or 1521

  local conns = load()
  for _, c in ipairs(conns) do
    if c.name == conn.name then
      error("dblite: connection '" .. conn.name .. "' already exists")
    end
  end

  local entry = { id = gen_id(), name = conn.name, type = t }
  if t == "sqlite" then
    entry.path = conn.path
  elseif t == "redis" then
    entry.host     = conn.host
    entry.port     = tonumber(conn.port) or default_port
    entry.db       = conn.db or 0
    entry.tls      = conn.tls and true or nil
    entry.user     = conn.user
    entry.password = conn.password
  else
    entry.auth = auth ~= "sql" and auth or nil
    entry.host = conn.host
    entry.port = tonumber(conn.port) or default_port
    entry.user = conn.user or ""
    entry.password = conn.password or ""
  end
  if t == "sqlserver" then
    entry.database = conn.database
  elseif t == "oracle" then
    entry.service = conn.service
  end
  table.insert(conns, entry)
  save(conns)
  return entry
end

-- Updates fields on the connection identified by id.
-- Returns the updated connection.
function M.update(id, fields)
  local conns = load()
  for i, c in ipairs(conns) do
    if c.id == id then
      for k, v in pairs(fields) do c[k] = v end
      validate(c)
      if c.type ~= "sqlite" then
        local default_port = (c.type == "sqlserver") and 1433
          or (c.type == "redis") and 6379
          or 1521
        if c.port then c.port = tonumber(c.port) or default_port end
      end
      conns[i] = c
      save(conns)
      return c
    end
  end
  error("dblite: connection not found: " .. id)
end

-- Deletes the connection with the given id.
function M.delete(id)
  local conns = load()
  for i, c in ipairs(conns) do
    if c.id == id then
      table.remove(conns, i)
      save(conns)
      return
    end
  end
  error("dblite: connection not found: " .. id)
end

-- Parses a Redis URI into connection fields.
--   redis://[[user][:password]@]host[:port][/db]
--   rediss://...                               (TLS)
-- Every part but the host is optional: Redis is commonly unauthenticated, and
-- the database is an index defaulting to 0.
-- Percent-decodes userinfo. The password reaches the binary through the
-- environment rather than the URL, so it has to be decoded here.
local function percent_decode(s)
  if not s or not s:find("%%") then return s end
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function parse_redis_uri(uri)
  local tls, rest = false, nil
  rest = uri:match("^rediss://(.*)$")
  if rest then
    tls = true
  else
    rest = uri:match("^redis://(.*)$")
  end
  if not rest then return nil end

  local user, password
  -- Split on the LAST @ so a password containing @ survives.
  local at = nil
  for i = #rest, 1, -1 do
    if rest:sub(i, i) == "@" then at = i break end
  end
  if at then
    local userinfo = rest:sub(1, at - 1)
    rest = rest:sub(at + 1)
    local colon = userinfo:find(":", 1, true)
    if colon then
      user     = percent_decode(userinfo:sub(1, colon - 1))
      password = percent_decode(userinfo:sub(colon + 1))
    else
      user = percent_decode(userinfo)
    end
    if user     == "" then user = nil end
    if password == "" then password = nil end
  end

  local db = 0
  local slash = rest:find("/", 1, true)
  if slash then
    local db_part = vim.trim(rest:sub(slash + 1))
    rest = rest:sub(1, slash - 1)
    if db_part ~= "" then
      db = tonumber(db_part)
      if not db or db < 0 or db ~= math.floor(db) then
        return nil, "Redis database must be a non-negative integer"
      end
    end
  end

  local host, port = rest, 6379
  local bracketed = host:match("^%[(.+)%]$")
  if bracketed then
    host = bracketed                              -- [::1] with no port
  else
    local ipv6, ipv6_port = host:match("^%[(.+)%]:(%d+)$")
    if ipv6 then
      host, port = ipv6, tonumber(ipv6_port)
    else
      local h, p = host:match("^(.*):(%d+)$")
      if h then host, port = h, tonumber(p) end
    end
  end

  if host == "" then return nil, "URI is missing host" end
  if not port or port < 1 or port > 65535 then return nil, "Invalid Redis port" end

  return {
    type = "redis", host = host, port = port, db = db,
    user = user, password = password, tls = tls or nil,
  }
end

-- Parses a URI into connection fields.
-- Oracle:    oracle://user[:password]@host[:port]/service
-- SQL Server: sqlserver://user[:password]@host[:port]/database
-- SQLite:    sqlite:///absolute/path/to/database.db
-- Redis:     redis://[[user][:password]@]host[:port][/db]  (rediss:// for TLS)
-- Returns fields table on success, or nil + error string on failure.
function M.parse_uri(uri)
  if uri:match("^rediss?://") then
    local fields, err = parse_redis_uri(uri)
    if fields then return fields end
    return nil, err or "Invalid Redis URI"
  end

  local sqlite_path = uri:match("^sqlite://(.+)$")
  if sqlite_path then
    local ok, path = pcall(normalize_sqlite_path, sqlite_path)
    if not ok then return nil, tostring(path):gsub("^.-dblite: ", "") end
    return { type = "sqlite", path = path }
  end

  local db_type, rest
  rest = uri:match("^oracle://(.+)$")
  if rest then
    db_type = "oracle"
  else
    rest = uri:match("^sqlserver://(.+)$")
    if rest then db_type = "sqlserver" end
  end

  if not rest then
    return nil, "URI must start with oracle://, sqlserver://, sqlite://, or redis://"
  end

  local at = rest:find("@")
  if not at then
    return nil, "URI must contain @ separator"
  end
  local userinfo = rest:sub(1, at - 1)
  local hostinfo  = rest:sub(at + 1)

  local user, password
  local uc = userinfo:find(":")
  if uc then
    user     = userinfo:sub(1, uc - 1)
    password = userinfo:sub(uc + 1)
  else
    user     = userinfo
    password = ""
  end

  local slash = hostinfo:find("/")
  if not slash then
    local label = db_type == "sqlserver" and "database" or "service"
    return nil, "URI must contain /" .. label .. " after the host"
  end
  local hostport = hostinfo:sub(1, slash - 1)
  local db_val   = hostinfo:sub(slash + 1)

  local default_port = db_type == "sqlserver" and 1433 or 1521
  local host, port
  local hc = hostport:find(":")
  if hc then
    host = hostport:sub(1, hc - 1)
    port = tonumber(hostport:sub(hc + 1)) or default_port
  else
    host = hostport
    port = default_port
  end

  if user   == "" then return nil, "URI is missing user" end
  if host   == "" then return nil, "URI is missing host" end
  if db_val == "" then return nil, "URI is missing " .. (db_type == "sqlserver" and "database" or "service") end

  local fields = { type = db_type, host = host, port = port, user = user, password = password }
  if db_type == "sqlserver" then
    fields.database = db_val
  else
    fields.service = db_val
  end
  return fields
end

-- Returns the JDBC URL for a connection table.
function M.jdbc_url(conn)
  local t = conn.type or "oracle"
  if t == "redis" then
    -- Credentials travel in the environment rather than the URL, so the URL
    -- stays readable and needs no percent-encoding.
    local host = conn.host
    if host:find(":", 1, true) then host = "[" .. host .. "]" end   -- IPv6 literal
    return string.format("%s://%s:%d/%d",
      conn.tls and "rediss" or "redis",
      host, tonumber(conn.port) or 6379, tonumber(conn.db) or 0)
  end
  if t == "sqlite" then
    local path = vim.fn.fnamemodify(vim.fn.expand(conn.path), ":p")
    return "jdbc:sqlite:" .. path
  end
  if t == "sqlserver" then
    local url = string.format(
      "jdbc:sqlserver://%s:%d;databaseName=%s;encrypt=true;trustServerCertificate=true",
      conn.host, tonumber(conn.port) or 1433, conn.database)
    if conn.auth == "kerberos" then
      url = url .. ";integratedSecurity=true;authenticationScheme=JavaKerberos"
    end
    return url
  end
  return string.format(
    "jdbc:oracle:thin:@%s:%d/%s",
    conn.host, tonumber(conn.port) or 1521, conn.service)
end

-- Expands $VAR references in a stored string against the real environment.
-- Used for credentials, and for the LOAD DATA infile path.
function M.expand_env(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("%$([%w_]+)", function(var) return os.getenv(var) or ("$" .. var) end))
end

-- Environment the `dblite` binary needs to reach `conn`. SQLite has no
-- credentials, and Kerberos gets them from the ticket cache rather than us.
function M.env(conn)
  local env = { DB_URL = M.jdbc_url(conn) }
  local t = conn.type or "oracle"
  if t == "redis" then
    -- Redis is frequently unauthenticated; only pass what was actually set.
    if conn.user     and conn.user     ~= "" then env.DB_USER     = M.expand_env(conn.user)     end
    if conn.password and conn.password ~= "" then env.DB_PASSWORD = M.expand_env(conn.password) end
  elseif t ~= "sqlite" and conn.auth ~= "kerberos" then
    env.DB_USER     = M.expand_env(conn.user)
    env.DB_PASSWORD = M.expand_env(conn.password or "")
  end
  return env
end

return M
