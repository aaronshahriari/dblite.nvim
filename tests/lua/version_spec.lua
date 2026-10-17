-- The binary carries no version of its own, so what `:Dblite version` prints
-- is whatever was written down when the binary arrived. The cases that matter
-- are the ones where that record is missing or stale, since both look like a
-- working install until a fix mysteriously fails to take effect.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local version = require("dblite.version")

local function eq(got, want, what)
  assert(got == want,
    string.format("%s: expected %s, got %s", what, vim.inspect(want), vim.inspect(got)))
end

local function contains(lines, pattern, what)
  for _, line in ipairs(lines) do
    if line:match(pattern) then return line end
  end
  error(string.format("%s: no line matching %s in:\n%s", what, pattern, table.concat(lines, "\n")))
end

local function absent(lines, pattern, what)
  for _, line in ipairs(lines) do
    assert(not line:match(pattern),
      string.format("%s: unexpected line %s", what, vim.inspect(line)))
  end
end

-- ── normalize / compare ─────────────────────────────────────────────────────
-- A release tag is v0.8.3 and a pom version is 0.8.3; they must compare equal.

eq(version.normalize("v0.8.3"), "0.8.3", "tag loses its v")
eq(version.normalize("0.8.3"), "0.8.3", "a bare version is unchanged")
eq(version.normalize(nil), "", "nil normalizes to empty")

eq(version.compare("0.8.3", "v0.8.3"), 0, "tag equals bare version")
eq(version.compare("0.8.2", "0.8.3"), -1, "older is less")
eq(version.compare("0.8.3", "0.8.2"), 1, "newer is greater")
-- The reason this is not a string comparison:
eq(version.compare("0.8.9", "0.8.10"), -1, "double-digit patch sorts after single")
eq(version.compare("0.8", "0.8.0"), 0, "a missing component counts as zero")
eq(version.compare("1.0.0", "0.9.9"), 1, "major outranks minor")

-- ── plugin version ──────────────────────────────────────────────────────────
-- Read from the real pom, so a malformed match shows up here rather than in a
-- fixture that agrees with itself.

local plugin = version.plugin(root)
assert(plugin and plugin:match("^%d+%.%d+%.%d+$"),
  "plugin version should look like a version, got " .. vim.inspect(plugin))
eq(version.plugin("/nonexistent"), nil, "no pom, no version")

-- ── record round trip ───────────────────────────────────────────────────────

local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox .. "/bin", "p")

eq(version.binary(sandbox), nil, "no record yet")

version.record(sandbox, { version = "0.8.3", source = "release" })
local rec = version.binary(sandbox)
eq(rec.version, "0.8.3", "recorded version")
eq(rec.source, "release", "recorded source")
assert(rec.at and rec.at:match("^%d%d%d%d%-%d%d%-%d%d"), "recorded timestamp, got " .. vim.inspect(rec.at))

-- A later install overwrites the earlier one.
version.record(sandbox, { version = "0.9.0", source = "build" })
eq(version.binary(sandbox).version, "0.9.0", "record is replaced, not appended")
eq(version.binary(sandbox).source, "build", "source is replaced too")

-- Garbage on disk reads as "unknown" rather than raising into the command.
local f = assert(io.open(sandbox .. "/bin/dblite.version", "w"))
f:write("not json at all")
f:close()
eq(version.binary(sandbox), nil, "unparseable record is treated as missing")

-- ── report ──────────────────────────────────────────────────────────────────

-- Matching versions: no warning.
local fresh = vim.fn.tempname()
vim.fn.mkdir(fresh .. "/bin", "p")
vim.fn.writefile({ "<artifactId>dblite</artifactId><version>0.8.3</version>" }, fresh .. "/pom.xml")
version.record(fresh, { version = "0.8.3", source = "release" })

local lines = version.report(fresh, fresh .. "/bin/dblite")
contains(lines, "^dblite 0%.8%.3$", "header names the plugin version")
contains(lines, "binary%s+0%.8%.3%s+%(release", "binary line names version and source")
contains(lines, "path%s+" .. vim.pesc(fresh), "report names the binary it describes")
absent(lines, "older than plugin", "no warning when they agree")

-- A tag records as the bare version, so a release install is not read as stale.
version.record(fresh, { version = version.normalize("v0.8.3"), source = "release" })
absent(version.report(fresh, "x"), "older than plugin", "a v-prefixed tag still matches")

-- Stale binary: the case this command exists for.
version.record(fresh, { version = "0.8.2", source = "release" })
lines = version.report(fresh, "x")
contains(lines, "binary 0%.8%.2 is older than plugin 0%.8%.3", "stale binary is called out")
contains(lines, ":DbliteBuild", "stale binary says what to do about it")

-- A binary newer than the plugin is not a problem worth shouting about.
version.record(fresh, { version = "0.9.0", source = "build" })
absent(version.report(fresh, "x"), "older than plugin", "newer binary raises nothing")

-- No record at all: say so plainly instead of guessing.
local bare = vim.fn.tempname()
vim.fn.mkdir(bare .. "/bin", "p")
vim.fn.writefile({ "<artifactId>dblite</artifactId><version>0.8.3</version>" }, bare .. "/pom.xml")
lines = version.report(bare, bare .. "/bin/dblite")
contains(lines, "binary%s+unknown", "missing record reads as unknown")
contains(lines, ":DbliteBuild", "missing record says how to fix it")
absent(lines, "older than plugin", "unknown is not compared")

print("version_spec ok")
