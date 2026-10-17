local version = require("dblite.version")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    return src:sub(2):gsub("/lua/dblite/download%.lua$", "")
  end
end

local function detect_platform()
  local uname = vim.uv.os_uname()
  local sys     = uname.sysname:lower()
  local machine = uname.machine:lower()

  local os_name
  if sys == "darwin" then
    os_name = "macos"
  elseif sys == "linux" then
    os_name = "linux"
  else
    return nil, "unsupported OS: " .. uname.sysname
  end

  local arch
  if machine == "x86_64" or machine == "amd64" then
    arch = "x86_64"
  elseif machine == "aarch64" or machine == "arm64" then
    arch = "aarch64"
  else
    return nil, "unsupported architecture: " .. uname.machine
  end

  return arch .. "-" .. os_name
end

local REPO = "aaronshahriari/dblite.nvim"

local function latest_release_tag()
  local r = vim.system({
    "curl", "--fail", "--silent", "--show-error",
    "--header", "Accept: application/vnd.github.v3+json",
    ("https://api.github.com/repos/%s/releases/latest"):format(REPO),
  }, { text = true }):wait()
  if r.code ~= 0 then return nil, "GitHub API request failed: " .. (r.stderr or "") end
  local tag = r.stdout:match('"tag_name"%s*:%s*"(v[^"]+)"')
  if not tag then return nil, "no releases found on GitHub" end
  return tag
end

-- Download a pre-built binary from GitHub Releases.
-- Returns nil on success, or an error string on failure.
local function try_download(root)
  local platform, err = detect_platform()
  if not platform then return err end

  local ver, verr = latest_release_tag()
  if not ver then return verr end

  local dest     = root .. "/bin/dblite"
  local dest_tmp = dest .. ".tmp"
  local url      = ("https://github.com/%s/releases/download/%s/dblite-%s"):format(REPO, ver, platform)

  vim.fn.mkdir(root .. "/bin", "p")

  local r = vim.system({
    "curl", "--fail", "--location", "--silent", "--show-error",
    "--output", dest_tmp, url,
  }, { text = true }):wait()

  if r.code ~= 0 then
    vim.fn.delete(dest_tmp)
    return ("curl failed (HTTP error or network issue): %s"):format(r.stderr or "")
  end

  vim.fn.system({ "chmod", "+x", dest_tmp })

  local ok, rename_err = os.rename(dest_tmp, dest)
  if not ok then
    vim.fn.delete(dest_tmp)
    return "rename failed: " .. (rename_err or "")
  end

  -- The binary cannot be asked what it is later, so note it now.
  version.record(root, { version = version.normalize(ver), source = "release" })
  return nil
end

-- Build from source via Maven.
-- Returns nil on success, or an error string on failure.
local function try_build(root)
  if vim.fn.executable("mvn") ~= 1 then
    return "mvn not found on PATH"
  end
  local r = vim.system(
    { "mvn", "-q", "clean", "package", "-Pnative" },
    { cwd = root, text = true, env = { MISE_TRUSTED_CONFIG_PATHS = root .. "/mise.toml" } }
  ):wait()
  if r.code ~= 0 then
    return "build failed:\n" .. (r.stderr or "")
  end

  -- A source build is whatever the working tree says it is, which is not
  -- necessarily a released version — the record says so.
  version.record(root, { version = version.plugin(root) or "unknown", source = "build" })
  return nil
end

-- Try downloading a pre-built binary from GitHub Releases; fall back to Maven build.
-- Runs synchronously (suspends coroutine, does not block the event loop).
-- opts.force_build skips the download entirely and builds straight from source
-- (use when the local source is ahead of the latest release).
function M.download_or_build(opts)
  opts = opts or {}
  local root = plugin_root()
  if not root then
    vim.notify("dblite: cannot determine plugin root", vim.log.levels.ERROR)
    return
  end

  if not opts.force_build then
    vim.notify("dblite: downloading binary...", vim.log.levels.INFO)
    local dl_err = try_download(root)

    if not dl_err then
      vim.notify("dblite: binary downloaded", vim.log.levels.INFO)
      return
    end

    vim.notify(
      ("dblite: download skipped (%s) — building from source (this takes a few minutes)..."):format(dl_err),
      vim.log.levels.WARN
    )
  else
    vim.notify("dblite: building from source (this takes a few minutes)...", vim.log.levels.INFO)
  end

  local build_err = try_build(root)
  if build_err then
    vim.notify("dblite: " .. build_err, vim.log.levels.ERROR)
  else
    vim.notify("dblite: binary built from source", vim.log.levels.INFO)
  end
end

-- Check if binary exists; download only if missing. Safe to call every startup.
function M.ensure_binary()
  local root = plugin_root()
  if not root then return end
  if vim.fn.filereadable(root .. "/bin/dblite") == 1 then return end
  M.download_or_build()
end

return M
