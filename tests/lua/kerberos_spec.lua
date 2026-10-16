-- SQL Server can authenticate with the caller's Kerberos ticket instead of a
-- username and password. That changes three things at once — the URI carries no
-- userinfo, the JDBC URL gains two properties, and the binary is handed no
-- credentials at all — so each is pinned here.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local connections = require("dblite.connections")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

-- ── parse_uri ───────────────────────────────────────────────────────────────

local u = assert(connections.parse_uri("sqlserver://db.corp.com:36362/KnowledgeBase?auth=kerberos"))
eq(u.type, "sqlserver", "kerberos uri type")
eq(u.auth, "kerberos", "kerberos uri auth")
eq(u.host, "db.corp.com", "kerberos uri host")
eq(u.port, 36362, "kerberos uri port")
eq(u.database, "KnowledgeBase", "kerberos uri database")
eq(u.user, "", "kerberos uri has no user")

-- The port is still optional.
u = assert(connections.parse_uri("sqlserver://db.corp.com/KnowledgeBase?auth=kerberos"))
eq(u.port, 1433, "kerberos uri default port")

-- A username may still be given — Kerberos ignores it, but a URI copied from a
-- SQL-login connection should not be rejected outright.
u = assert(connections.parse_uri("sqlserver://me@db.corp.com/KB?auth=kerberos"))
eq(u.auth, "kerberos", "kerberos uri with userinfo")
eq(u.user, "me", "kerberos uri keeps a given user")

-- ?auth=sql is the default and leaves nothing behind to store.
u = assert(connections.parse_uri("sqlserver://me:pw@db.corp.com/KB?auth=sql"))
eq(u.auth, nil, "explicit sql auth is not recorded")
eq(u.password, "pw", "explicit sql auth keeps the password")

-- Without the query, the userinfo is still required.
local bad, err = connections.parse_uri("sqlserver://db.corp.com/KB")
eq(bad, nil, "sql-auth uri still needs userinfo")
assert(err:match("@"), "missing-userinfo error mentions the separator, got: " .. tostring(err))

bad, err = connections.parse_uri("oracle://db.corp.com/XE?auth=kerberos")
eq(bad, nil, "kerberos is rejected for oracle")
assert(err:match("SQL Server"), "oracle kerberos error names the supported type, got: " .. tostring(err))

bad, err = connections.parse_uri("sqlserver://db.corp.com/KB?auth=ntlm")
eq(bad, nil, "an unknown auth scheme is rejected")
assert(err:match("kerberos"), "unknown-scheme error lists the schemes, got: " .. tostring(err))

bad, err = connections.parse_uri("sqlserver://me@db.corp.com/KB?mode=fast")
eq(bad, nil, "an unknown query key is rejected")

-- ── jdbc_url ────────────────────────────────────────────────────────────────

local conn = {
  type = "sqlserver", host = "db.corp.com", port = 36362,
  database = "KnowledgeBase", auth = "kerberos",
}

eq(connections.jdbc_url(conn),
  "jdbc:sqlserver://db.corp.com:36362;databaseName=KnowledgeBase;encrypt=true;" ..
  "trustServerCertificate=true;integratedSecurity=true;authenticationScheme=JavaKerberos",
  "kerberos jdbc url")

eq(connections.jdbc_url({
    type = "sqlserver", host = "db.corp.com", port = 1433,
    database = "KB", user = "me", password = "pw",
  }),
  "jdbc:sqlserver://db.corp.com:1433;databaseName=KB;encrypt=true;trustServerCertificate=true",
  "sql-auth jdbc url is unchanged")

-- ── env ─────────────────────────────────────────────────────────────────────
-- The ticket cache holds the credentials, so nothing is passed to the binary.
-- DB_USER in particular must stay unset: the binary treats its presence as a
-- request for SQL authentication.

local env = connections.env(conn)
eq(env.DB_USER, nil, "kerberos passes no DB_USER")
eq(env.DB_PASSWORD, nil, "kerberos passes no DB_PASSWORD")
assert(env.DB_URL:match("authenticationScheme=JavaKerberos"), "kerberos env carries the url")

-- ── add / update round trip ─────────────────────────────────────────────────
-- A Kerberos entry must save without a username, and turning Kerberos back off
-- has to clear the stored scheme rather than leave it behind.

local name = "kerberos-spec-" .. tostring(vim.uv.hrtime())
local saved = connections.add({
  name = name, type = "sqlserver", host = "db.corp.com",
  port = 36362, database = "KnowledgeBase", auth = "kerberos",
})
eq(saved.auth, "kerberos", "saved auth")
eq(connections.get_by_name(name).auth, "kerberos", "auth survives a reload")

local back = connections.update(saved.id, { auth = "sql", user = "me", password = "pw" })
eq(back.auth, nil, "switching back to sql clears the scheme")
eq(connections.jdbc_url(back):match("JavaKerberos"), nil, "the url drops the kerberos properties")

connections.delete(saved.id)

print("kerberos_spec ok")
