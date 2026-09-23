local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local icons = {}
local extensions = {}
local filetypes = {}
local icon_calls = 0

package.loaded["nvim-web-devicons"] = {
  get_icons = function() return icons end,
  get_icons_by_extension = function() return extensions end,
  get_icon_name_by_filetype = function(ft) return filetypes[ft] end,
  set_icon = function(values)
    icon_calls = icon_calls + 1
    for key, value in pairs(values) do icons[key] = value end
  end,
  set_icon_by_filetype = function(values)
    for key, value in pairs(values) do filetypes[key] = value end
  end,
}

local devicons = require("dblite.devicons")
devicons.setup()

assert(icons.redis, "the .redis icon is registered")
assert(icons.redis.icon == "", "the Redis Nerd Font glyph is used")
assert(filetypes.redis == "redis", "the redis filetype uses the extension icon")

icons.redis = { icon = "custom" }
filetypes.redis = "custom"
devicons.setup()

assert(icon_calls == 1, "an existing user icon is not replaced")
assert(icons.redis.icon == "custom", "the user's extension icon is preserved")
assert(filetypes.redis == "custom", "the user's filetype icon is preserved")

print("devicons_spec: ok")
