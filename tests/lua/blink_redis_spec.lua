-- Redis completion: commands at the start of a line, key namespaces and keys in
-- argument position, hash fields once the key is known.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local keyspace_data = {
  keys = {
    "user:1042", "user:1043",
    "user:sessions:a83f", "user:sessions:b91c",
    "session:a83f", "cfg:app", "standalone",
  },
  types = {
    ["user:1042"]          = "hash",
    ["user:1043"]          = "hash",
    ["user:sessions:a83f"] = "string",
    ["user:sessions:b91c"] = "string",
    ["session:a83f"]       = "string",
    ["cfg:app"]            = "string",
    ["standalone"]         = "string",
  },
  commands = {
    { name = "GET",     arity = 2, flags = "readonly fast" },
    { name = "GETDEL",  arity = 2, flags = "write fast" },
    { name = "HGETALL", arity = 2, flags = "readonly" },
    { name = "SET",     arity = -3, flags = "write denyoom" },
  },
}

local fields_calls = {}

package.loaded["dblite"] = {
  get_active_conn = function() return { type = "redis", id = "test" } end,
  get_flat_binds  = function() return {} end,
}
package.loaded["dblite.schema"] = {
  peek = function() return nil end,
  prefetch = function() end,
}
package.loaded["dblite.keyspace"] = {
  enabled  = function() return true end,
  peek     = function() return keyspace_data end,
  prefetch = function() end,
  peek_fields = function(_, key)
    table.insert(fields_calls, key)
    if key == "user:1042" then return { "name", "email", "prefs" } end
    return nil
  end,
}

local blink = require("dblite.blink").new()

local function complete(line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  local result
  blink:get_completions({
    bufnr  = bufnr,
    line   = line,
    cursor = { 1, #line },
  }, function(items) result = items end)
  assert(result, "callback was not invoked for: " .. line)
  local labels, byLabel = {}, {}
  for _, item in ipairs(result.items) do
    table.insert(labels, item.label)
    byLabel[item.label] = item
  end
  return labels, byLabel, result
end

local function has(labels, want, what)
  for _, l in ipairs(labels) do
    if l == want then return end
  end
  error(string.format("%s: %q missing from { %s }", what, want, table.concat(labels, ", ")))
end

local function lacks(labels, unwanted, what)
  for _, l in ipairs(labels) do
    if l == unwanted then
      error(string.format("%s: %q should not be offered", what, unwanted))
    end
  end
end

-- ── commands at the start of a line ─────────────────────────────────────────

local labels, byLabel = complete("")
has(labels, "GET", "empty line offers commands")
has(labels, "HGETALL", "empty line offers commands")

labels, byLabel = complete("GET")
has(labels, "GET", "a command prefix offers itself")
has(labels, "GETDEL", "a command prefix offers longer matches")
lacks(labels, "SET", "a command prefix filters non-matches")
assert(byLabel.GET.detail:match("arity 2"), "command detail carries arity")
assert(byLabel.GET.detail:match("readonly"), "command detail carries flags")

-- Matching is case-insensitive, since commands are conventionally shouted.
labels = complete("hget")
has(labels, "HGETALL", "lowercase command prefix matches")

-- ── namespaces and keys in argument position ────────────────────────────────

labels, byLabel = complete("GET ")
has(labels, "user:", "argument position offers namespaces")
has(labels, "session:", "argument position offers namespaces")
has(labels, "user:1042", "argument position also offers full keys")
assert(byLabel["user:"].detail == "namespace", "namespace items are labelled")
assert(byLabel["user:1042"].detail == "hash", "key items carry their type")

-- `standalone` is a key, not just a prefix, so it must not be offered as a
-- namespace that would insert a trailing colon.
lacks(complete("GET "), "standalone:", "a real key is not offered as a namespace")
has(complete("GET "), "standalone", "a key with no separator is offered as itself")

-- Namespaces advance one level at a time: at the top only `user:` shows, not
-- the deeper `user:sessions:` that would skip a step.
labels = complete("")
lacks(complete("GET "), "user:sessions:", "only the next namespace level is offered")

labels = complete("GET user:")
has(labels, "user:1042", "a typed namespace offers its keys")
has(labels, "user:1043", "a typed namespace offers its keys")
has(labels, "user:sessions:", "a typed namespace offers the next level down")
lacks(labels, "session:a83f", "a typed namespace filters other namespaces")
lacks(labels, "user:", "the level already typed is not re-offered")

labels = complete("GET user:sessions:")
has(labels, "user:sessions:a83f", "a deep namespace offers its keys")
lacks(labels, "user:1042", "a deep namespace filters its siblings")
lacks(labels, "user:sessions:", "the deep level already typed is not re-offered")

-- Namespaces sort ahead of bare keys, so the short list comes first.
local _, byNs = complete("GET user:")
assert(byNs["user:sessions:"].sortText < byNs["user:1042"].sortText,
  "namespaces sort before keys")

labels = complete("GET user:1042")
has(labels, "user:1042", "a full key still matches itself")
lacks(labels, "user:1043", "a full key filters its siblings")

-- The replacement range must cover the whole partial token, so completing
-- `user:` to `user:1042` does not produce `user:user:1042`.
local _, byL = complete("GET user:")
local edit = byL["user:1042"].textEdit
assert(edit, "key items carry an explicit textEdit")
assert(edit.newText == "user:1042", "textEdit inserts the whole key")
assert(edit.range.start.character == 4, "textEdit starts at the token, got "
  .. tostring(edit.range.start.character))
assert(edit.range["end"].character == 9, "textEdit ends at the cursor, got "
  .. tostring(edit.range["end"].character))

-- ── hash fields ─────────────────────────────────────────────────────────────

labels, byLabel = complete("HGET user:1042 ")
has(labels, "name", "a hash command offers the key's fields")
has(labels, "prefs", "a hash command offers the key's fields")
lacks(labels, "user:1043", "field position does not offer keys")
assert(byLabel.name.detail == "user:1042", "field items name their key")

labels = complete("HGET user:1042 pre")
has(labels, "prefs", "a field prefix filters fields")
lacks(labels, "name", "a field prefix filters fields")

-- A hash command against a non-hash key falls back to key completion rather
-- than pretending the key has fields.
labels = complete("HGET cfg:app ")
has(labels, "user:1042", "a non-hash key falls back to key completion")

-- A non-hash command in the same position completes keys, not fields.
labels = complete("GET user:1042 ")
lacks(labels, "name", "a non-hash command does not offer fields")

-- ── still warming ───────────────────────────────────────────────────────────

package.loaded["dblite.keyspace"].peek = function() return nil end
local _, _, res = complete("GET ")
assert(res.is_incomplete_forward, "a cold keyspace returns incomplete so blink retries")
assert(#res.items == 0, "a cold keyspace offers nothing yet")
package.loaded["dblite.keyspace"].peek = function() return keyspace_data end

-- ── disabled ────────────────────────────────────────────────────────────────

package.loaded["dblite.keyspace"].enabled = function() return false end
local off = complete("GET ")
assert(#off == 0, "completion honours the disable switch")
package.loaded["dblite.keyspace"].enabled = function() return true end

print("blink_redis_spec: ok")
