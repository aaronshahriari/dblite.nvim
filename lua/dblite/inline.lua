-- Headless query execution.
--
-- `dblite.inline` runs one statement against a *named* saved connection and
-- hands the decoded result back to Lua. Unlike every other run path it touches
-- no UI state at all: no result buffer, no spinner, no query history, no jobs
-- panel, no flash highlight, and it neither reads nor changes the active
-- connection. That makes it safe to call from timers, autocmds, statusline
-- functions and other plugins — the caller decides what to do with the rows.

local config      = require("dblite.config")
local connections = require("dblite.connections")
local binds_mod   = require("dblite.binds")

local M = {}

-- Rows arrive from the binary as objects keyed by column label, which is what
-- most callers want. `values` exposes the same rows positionally, in column
-- order, and is built only if something actually reads it.
local result_mt = {
  __index = function(t, key)
    if key ~= "values" then return nil end
    local columns, out = rawget(t, "columns"), {}
    for i, row in ipairs(rawget(t, "rows")) do
      local tuple = {}
      for j, col in ipairs(columns) do tuple[j] = row[col] end
      out[i] = tuple
    end
    rawset(t, "values", out)
    return out
  end,
}

local function build_result(parsed, raw, elapsed, conn_name)
  local res = {
    conn         = conn_name,
    columns      = parsed.columns      or {},
    column_types = parsed.column_types or {},
    rows         = parsed.rows         or {},
    update_count = parsed.update_count,
    elapsed      = elapsed,
    json         = raw,
  }
  res.count = #res.rows
  if parsed.script then
    res.script   = true
    res.results  = parsed.results  or {}
    res.executed = parsed.executed or 0
    res.failed   = parsed.failed   or 0
    res.total    = parsed.total    or #res.results
  end
  return setmetatable(res, result_mt)
end

-- Validates opts and resolves the connection + final SQL. Returns a prepared
-- table on success, or nil + an error message.
local function prepare(opts)
  if type(opts) ~= "table" then
    return nil, "inline: opts must be a table"
  end
  if type(opts.sql) ~= "string" or opts.sql:match("^%s*$") then
    return nil, "inline: sql is required"
  end
  if type(opts.conn) ~= "string" or opts.conn == "" then
    return nil, "inline: conn is required (the name of a saved connection)"
  end

  if vim.fn.executable(config.binary) ~= 1 then
    return nil, "inline: dblite binary not found — run :DbliteBuild"
  end

  local conn = connections.get_by_name(opts.conn)
  if not conn then
    return nil, "inline: no saved connection named '" .. opts.conn .. "'"
  end

  -- Binds are explicit here. dblite.binds.json is a per-cwd editing aid, so an
  -- API call only sees it when it asks for it; either way we fail with the
  -- missing names rather than popping open the binds editor.
  local sql = opts.sql
  if next(binds_mod.names_for(conn, sql) or {}) ~= nil then
    local values = opts.binds_file and binds_mod.flatten(binds_mod.load_file()) or {}
    for k, v in pairs(opts.binds or {}) do values[k] = v end
    local missing = binds_mod.missing(sql, values)
    if #missing > 0 then
      return nil, "inline: missing bind params: " .. table.concat(missing, ", ")
    end
    sql = binds_mod.apply(sql, values)
  end

  local cmd = { config.binary }
  if opts.script then
    table.insert(cmd, "--script")
  else
    local max_rows = opts.max_rows or config.max_rows
    if max_rows and max_rows > 0 then
      table.insert(cmd, "--max-rows")
      table.insert(cmd, tostring(max_rows))
    end
  end

  return {
    cmd  = cmd,
    sql  = sql,
    conn = conn,
    sys  = {
      stdin   = sql,
      text    = true,
      env     = connections.env(conn),
      timeout = opts.timeout,
    },
  }
end

-- Turns a finished vim.system result into (res, err).
local function interpret(out, prepared, elapsed, null_as_nil)
  if out.signal ~= 0 then
    return nil, "inline: query cancelled"
  end
  if out.code ~= 0 then
    local stderr = (out.stderr or ""):gsub("%s+$", "")
    return nil, "inline: " .. (stderr ~= "" and stderr or ("binary exited " .. out.code))
  end
  -- vim.json.decode rejects an explicit nil second argument, so only pass one.
  local ok, parsed
  if null_as_nil then
    ok, parsed = pcall(vim.json.decode, out.stdout, { luanil = { object = true, array = true } })
  else
    ok, parsed = pcall(vim.json.decode, out.stdout)
  end
  if not ok or type(parsed) ~= "table" then
    return nil, "inline: could not parse result JSON: " .. tostring(parsed)
  end
  return build_result(parsed, out.stdout, elapsed, prepared.conn.name)
end

-- Run `opts.sql` on the saved connection `opts.conn`.
--
--   opts.sql          statement to run                        (required)
--   opts.conn         name of a saved connection              (required)
--   opts.binds        table of bind values for :name refs
--   opts.binds_file   also read dblite.binds.json  (default false)
--   opts.max_rows     row cap; 0 = uncapped       (default config.max_rows)
--   opts.script       run as a multi-statement script
--   opts.timeout      milliseconds before the query is killed
--   opts.null_as_nil  decode SQL NULL as nil instead of vim.NIL
--   opts.sync         block and return instead of calling back
--
-- Async (default): returns the vim.system handle, so the caller can `:kill()`
-- an in-flight query. `callback(err, res)` runs on the main loop.
-- Sync (`opts.sync = true`, or no callback): returns `res, err`.
function M.run(opts, callback)
  local sync = (opts and opts.sync) or callback == nil

  local prepared, err = prepare(opts)
  if not prepared then
    if sync then return nil, err end
    vim.schedule(function() callback(err, nil) end)
    return nil
  end

  local started = vim.uv.hrtime()
  local function since() return (vim.uv.hrtime() - started) / 1e9 end

  if sync then
    local ok, out = pcall(function()
      return vim.system(prepared.cmd, prepared.sys):wait()
    end)
    if not ok then return nil, "inline: " .. tostring(out) end
    local res, run_err = interpret(out, prepared, since(), opts.null_as_nil)
    if callback then callback(run_err, res) end
    return res, run_err
  end

  return vim.system(prepared.cmd, prepared.sys, function(out)
    local elapsed = since()
    -- vim.system's callback is a fast event context; callers will want to
    -- notify, set buffers or otherwise touch the API, so hand off first.
    vim.schedule(function()
      local res, run_err = interpret(out, prepared, elapsed, opts.null_as_nil)
      callback(run_err, res)
    end)
  end)
end

return M
