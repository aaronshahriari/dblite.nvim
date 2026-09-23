local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local icons = {}
local filetypes = {}

require("dblite.devicons").setup()
assert(not icons.redis, "registration waits when devicons is unavailable")

package.loaded["nvim-web-devicons"] = {
  get_icons = function() return icons end,
  get_icons_by_extension = function() return {} end,
  get_icon_name_by_filetype = function(ft) return filetypes[ft] end,
  set_icon = function(values)
    for key, value in pairs(values) do icons[key] = value end
  end,
  set_icon_by_filetype = function(values)
    for key, value in pairs(values) do filetypes[key] = value end
  end,
}
vim.wait(100, function() return icons.redis ~= nil end)

assert(icons.redis and icons.redis.icon == "", "the icon is registered after devicons loads")
assert(filetypes.redis == "redis", "the filetype mapping is registered after devicons loads")

print("devicons_late_spec: ok")
