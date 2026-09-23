-- Neovim ships no `redis` filetype, so a `.redis` scratch buffer would
-- otherwise get no comment string, no word boundaries that survive a
-- colon-namespaced key, and no highlighting at all.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")

require("dblite").setup({})

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

local path = vim.fn.tempname() .. ".redis"
vim.fn.writefile({
  "# fetch a profile",
  "JSON.GET user:1042:profile $.name",
  "ZRANGE leaderboard 0 -1 WITHSCORES",
  'SET greeting "hello world" EX 60',
  "KEYS *",
}, path)
vim.cmd("edit " .. path)

eq(vim.bo.filetype, "redis", "a .redis file is detected")
eq(vim.bo.commentstring, "# %s", "comments are `#`, not SQL's `--`")
assert(vim.bo.iskeyword:find(":"), "a colon-namespaced key is one word")
assert(vim.bo.iskeyword:find("%."), "a dotted module command is one word")

local function group(line, col)
  return vim.fn.synIDattr(vim.fn.synID(line, col, 1), "name")
end

eq(group(1, 1),  "redisComment", "the # comment")
eq(group(2, 3),  "redisCommand", "JSON.GET is one command, not JSON then GET")
eq(group(2, 12), "redisKey",     "the namespaced key")
eq(group(2, 28), "redisPath",    "the JSONPath argument")
eq(group(3, 25), "redisFlag",    "the WITHSCORES flag")
eq(group(4, 2),  "redisCommand", "SET at line start is the command")
eq(group(4, 29), "redisFlag",    "EX mid-line is a flag")
eq(group(4, 16), "redisString",  "the quoted argument")
eq(group(4, 32), "redisNumber",  "the TTL")
eq(group(5, 6),  "redisGlob",    "a bare glob")

-- `SET` is a flag name too (`GEORADIUS ... STORE`, `CLIENT NO-EVICT`), and the
-- flag rule must not repaint a command sitting on column one.
assert(group(4, 2) ~= "redisFlag", "a command that is also a flag name stays a command")

vim.cmd("bdelete!")
os.remove(path)

print("redis_ft_spec: ok")
