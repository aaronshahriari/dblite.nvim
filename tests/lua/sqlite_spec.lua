local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local connections = require("dblite.connections")
local load = require("dblite.load")

local db_path = vim.fn.tempname() .. " database.sqlite"
local file = assert(io.open(db_path, "w"))
file:close()

local parsed, err = connections.parse_uri("sqlite://" .. db_path)
assert(parsed, err)
assert(parsed.type == "sqlite")
assert(parsed.path == vim.fn.fnamemodify(db_path, ":p"))
assert(connections.jdbc_url(parsed) == "jdbc:sqlite:" .. parsed.path)
assert(connections.jdbc_url({ type = "sqlite", path = "~/database.db" })
  == "jdbc:sqlite:" .. vim.fn.expand("~/database.db"))

local missing, missing_err = connections.parse_uri("sqlite://" .. db_path .. ".missing")
assert(missing == nil)
assert(missing_err:match("existing file"))

local memory, memory_err = connections.parse_uri("sqlite://:memory:")
assert(memory == nil)
assert(memory_err:match(":memory:"))

local built = load.build({
  columns = { "id", "name" },
  mode = "truncate",
  table = "items",
}, { { "1", "one" } }, "sqlite")
assert(built.statements[1] == "DELETE FROM items;")
assert(built.statements[2] == "INSERT INTO items (id, name) VALUES (1, 'one');")

assert(os.remove(db_path))
