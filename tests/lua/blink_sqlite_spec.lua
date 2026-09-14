local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local schema = {
  owners = { "main" },
  owner_tables = { main = { "users", "auction_cache" } },
  columns = {
    ["main.users"] = { { name = "email", type = "TEXT" } },
    ["main.auction_cache"] = { { name = "auction_date", type = "TEXT" } },
  },
}

package.loaded["dblite"] = {
  get_active_conn = function() return { type = "sqlite", id = "test" } end,
  get_flat_binds = function() return {} end,
}
package.loaded["dblite.schema"] = {
  peek = function() return schema end,
  prefetch = function() end,
}

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "select * from au" })

local result
require("dblite.blink").new():get_completions({
  bufnr = bufnr,
  line = "select * from au",
  cursor = { 1, 16 },
}, function(items) result = items end)

local labels = {}
for _, item in ipairs(result.items) do labels[item.label] = item end
assert(labels.auction_cache)
assert(labels.auction_cache.insertText == '"auction_cache"')
assert(not labels.auction_date)
