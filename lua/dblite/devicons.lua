local M = {}

local redis_icon = {
  icon = "",
  color = "#D82C20",
  cterm_color = "160",
  name = "Redis",
}

local function register()
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then return false end

  local icons = type(devicons.get_icons) == "function" and devicons.get_icons() or {}
  local extensions = type(devicons.get_icons_by_extension) == "function"
    and devicons.get_icons_by_extension() or {}
  if not icons.redis and not extensions.redis and type(devicons.set_icon) == "function" then
    devicons.set_icon({ redis = redis_icon })
  end

  local filetype_icon = type(devicons.get_icon_name_by_filetype) == "function"
    and devicons.get_icon_name_by_filetype("redis") or nil
  if not filetype_icon and type(devicons.set_icon_by_filetype) == "function" then
    devicons.set_icon_by_filetype({ redis = "redis" })
  end
  return true
end

function M.setup()
  if register() then return end

  -- Plugin managers may add devicons later in the same startup sequence than
  -- dblite. Retry once configuration has yielded instead of imposing a load
  -- order or making devicons a required dependency.
  vim.schedule(register)
end

return M
