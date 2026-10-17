-- What version of the binary is actually installed?
--
-- The binary cannot answer that itself: nothing stamps a version into the
-- native image, and asking it would cost a process launch anyway. The only
-- honest answer is the one recorded at the moment the binary arrived, so
-- download.lua writes a record beside it and everything here reads that back.
--
-- A binary installed before this existed has no record. That is reported as
-- unknown rather than guessed at — a wrong version is worse than no version
-- when the question being asked is "am I testing the fix or not".

local M = {}

local RECORD = "/bin/dblite.version"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  return raw
end

--- The plugin's own version, read from the pom the binary is built from.
--- Both ship from one tag, so one number describes the pair.
function M.plugin(root)
  local xml = root and read_file(root .. "/pom.xml")
  if not xml then return nil end
  -- The project's own version is the one that follows its artifactId; the
  -- dependency blocks further down carry versions of their own.
  return xml:match("<artifactId>dblite</artifactId>%s*<version>([^<]+)</version>")
end

--- Records how the binary at `root` got there. Called after a download or a
--- build, never on its own — an unwritten record means "we do not know".
function M.record(root, info)
  local f = io.open(root .. RECORD, "w")
  if not f then return end
  f:write(vim.json.encode({
    version = info.version,
    source  = info.source,
    at      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }))
  f:close()
end

--- The recorded version of the binary at `root`, or nil if there is none.
function M.binary(root)
  local raw = root and read_file(root .. RECORD)
  if not raw then return nil end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" or type(data.version) ~= "string" then return nil end
  return data
end

--- Strips the `v` a release tag carries so a tag and a pom version compare.
function M.normalize(v)
  return (tostring(v or ""):gsub("^v", ""))
end

--- -1, 0 or 1, comparing version strings component by component. Numbers, not
--- text: 0.8.10 is after 0.8.9, which a string comparison gets backwards.
function M.compare(a, b)
  local function parts(v)
    local out = {}
    for n in M.normalize(v):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

--- The lines `:Dblite version` prints.
function M.report(root, binary_path)
  local plugin = M.plugin(root)
  local lines  = { "dblite " .. (plugin or "(version unknown)") }

  local rec = M.binary(root)
  if rec then
    local source = rec.source == "release" and "release" or "built from source"
    local when   = rec.at and (", " .. rec.at:sub(1, 10)) or ""
    lines[#lines + 1] = ("  binary   %s  (%s%s)"):format(rec.version, source, when)
  else
    lines[#lines + 1] = "  binary   unknown  (installed before dblite recorded versions)"
  end
  lines[#lines + 1] = "  path     " .. (binary_path or "?")

  -- The case worth catching: the plugin updated and the binary did not, which
  -- otherwise looks like the fix you just pulled failing to work.
  if rec and plugin and M.compare(rec.version, plugin) < 0 then
    lines[#lines + 1] = ("  ! binary %s is older than plugin %s — run :DbliteBuild to update it")
      :format(M.normalize(rec.version), plugin)
  elseif not rec then
    lines[#lines + 1] = "  run :DbliteBuild to reinstall it and record the version"
  end

  return lines
end

return M
