local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local connections = require("dblite.connections")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

-- ── parse_uri ───────────────────────────────────────────────────────────────

local u = assert(connections.parse_uri("redis://localhost"))
eq(u.type, "redis", "bare uri type")
eq(u.host, "localhost", "bare uri host")
eq(u.port, 6379, "bare uri default port")
eq(u.db, 0, "bare uri default db")
eq(u.tls, nil, "bare uri is not tls")
eq(u.user, nil, "bare uri has no user")
eq(u.password, nil, "bare uri has no password")

u = assert(connections.parse_uri("redis://cache-01:6380/3"))
eq(u.host, "cache-01", "host")
eq(u.port, 6380, "port")
eq(u.db, 3, "db index")

u = assert(connections.parse_uri("rediss://cache-01:6380/1"))
eq(u.tls, true, "rediss is tls")

u = assert(connections.parse_uri("redis://:secret@host"))
eq(u.user, nil, "password-only userinfo has no user")
eq(u.password, "secret", "password-only userinfo")

u = assert(connections.parse_uri("redis://alice:s3cr3t@host/2"))
eq(u.user, "alice", "acl user")
eq(u.password, "s3cr3t", "acl password")
eq(u.db, 2, "db after userinfo")

-- Passwords routinely need escaping to survive a URL; the stored value must be
-- the real password, since it reaches the binary through the environment.
u = assert(connections.parse_uri("redis://:p%40ss%3Aword%2F1@host"))
eq(u.password, "p@ss:word/1", "percent-decoded password")

-- A '@' inside the password must not fool the authority split.
u = assert(connections.parse_uri("redis://user:a@b@realhost:6390"))
eq(u.host, "realhost", "last @ separates userinfo")
eq(u.port, 6390, "port after embedded @")
eq(u.password, "a@b", "password containing @")

u = assert(connections.parse_uri("redis://[::1]:6380/2"))
eq(u.host, "::1", "bracketed ipv6 host")
eq(u.port, 6380, "ipv6 port")
eq(u.db, 2, "ipv6 db")

u = assert(connections.parse_uri("redis://[2001:db8::1]"))
eq(u.host, "2001:db8::1", "ipv6 without port")
eq(u.port, 6379, "ipv6 default port")

local bad, err = connections.parse_uri("redis://host/notanumber")
eq(bad, nil, "non-numeric db rejected")
assert(err:match("integer"), "db error mentions integer, got: " .. tostring(err))

bad, err = connections.parse_uri("redis://host:99999")
eq(bad, nil, "out-of-range port rejected")
assert(err:match("[Pp]ort"), "port error mentions port, got: " .. tostring(err))

-- The non-Redis error message should now advertise redis:// too.
bad, err = connections.parse_uri("mysql://host/db")
eq(bad, nil, "unknown scheme rejected")
assert(err:match("redis://"), "scheme error lists redis://, got: " .. tostring(err))

-- ── jdbc_url ────────────────────────────────────────────────────────────────

eq(connections.jdbc_url({ type = "redis", host = "h", port = 6380, db = 2 }),
  "redis://h:6380/2", "redis url")
eq(connections.jdbc_url({ type = "redis", host = "h" }),
  "redis://h:6379/0", "redis url defaults")
eq(connections.jdbc_url({ type = "redis", host = "h", tls = true }),
  "rediss://h:6379/0", "rediss url")
eq(connections.jdbc_url({ type = "redis", host = "::1", db = 1 }),
  "redis://[::1]:6379/1", "ipv6 url is bracketed")

-- ── env ─────────────────────────────────────────────────────────────────────

local env = connections.env({ type = "redis", host = "h", db = 1 })
eq(env.DB_URL, "redis://h:6379/1", "env url")
eq(env.DB_USER, nil, "no user means no DB_USER")
eq(env.DB_PASSWORD, nil, "no password means no DB_PASSWORD")

env = connections.env({ type = "redis", host = "h", user = "alice", password = "pw" })
eq(env.DB_USER, "alice", "env user")
eq(env.DB_PASSWORD, "pw", "env password")

-- $VAR references expand against the real environment, as for the SQL sources.
vim.fn.setenv("DBLITE_SPEC_REDIS_PW", "from-env")
env = connections.env({ type = "redis", host = "h", password = "$DBLITE_SPEC_REDIS_PW" })
eq(env.DB_PASSWORD, "from-env", "env password expands $VAR")

-- ── validate / add / update ─────────────────────────────────────────────────

local stale = connections.get_by_name("spec_redis")
if stale then connections.delete(stale.id) end

local entry = connections.add({
  name = "spec_redis", type = "redis", host = "127.0.0.1", db = 2,
})
eq(entry.type, "redis", "saved type")
eq(entry.port, 6379, "port defaulted on save")
eq(entry.db, 2, "db saved")

local updated = connections.update(entry.id, { db = 5, tls = true })
eq(updated.db, 5, "db updated")
eq(updated.tls, true, "tls updated")
eq(connections.jdbc_url(updated), "rediss://127.0.0.1:6379/5", "url after update")

-- A negative or fractional database index is not a database index.
local ok = pcall(connections.update, entry.id, { db = -1 })
assert(not ok, "negative db index must be rejected")
ok = pcall(connections.update, entry.id, { db = 1.5 })
assert(not ok, "fractional db index must be rejected")

-- Host is the one thing Redis actually requires.
ok = pcall(connections.add, { name = "spec_redis_nohost", type = "redis" })
assert(not ok, "missing host must be rejected")

connections.delete(entry.id)
assert(connections.get_by_name("spec_redis") == nil, "spec connection cleaned up")

print("redis_spec: ok")
