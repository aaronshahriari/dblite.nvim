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
  assert(t == "oracle" or t == "sqlserver" or t == "sqlite",
    "dblite: type must be 'oracle', 'sqlserver', or 'sqlite'")
  assert(type(conn.name) == "string" and conn.name ~= "", "dblite: name is required")
  if t == "sqlite" then
    conn.path = normalize_sqlite_path(conn.path)
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

  local default_port = t == "sqlserver" and 1433 or 1521

  local conns = load()
  for _, c in ipairs(conns) do
    if c.name == conn.name then
      error("dblite: connection '" .. conn.name .. "' already exists")
    end
  end

  local entry = { id = gen_id(), name = conn.name, type = t }
  if t == "sqlite" then
    entry.path = conn.path
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
        local default_port = (c.type == "sqlserver") and 1433 or 1521
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

-- Parses a URI into connection fields.
-- Oracle:    oracle://user[:password]@host[:port]/service
-- SQL Server: sqlserver://user[:password]@host[:port]/database
-- SQLite:    sqlite:///absolute/path/to/database.db
-- Returns fields table on success, or nil + error string on failure.
function M.parse_uri(uri)
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
    return nil, "URI must start with oracle://, sqlserver://, or sqlite://"
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
  if t ~= "sqlite" and conn.auth ~= "kerberos" then
    env.DB_USER     = M.expand_env(conn.user)
    env.DB_PASSWORD = M.expand_env(conn.password or "")
  end
  return env
end

return M
