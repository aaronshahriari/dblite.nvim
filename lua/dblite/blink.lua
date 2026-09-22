-- blink.cmp source for dblite.nvim
-- Register in your blink.cmp config:
--
--   sources = {
--     providers = {
--       dblite = { module = 'dblite.blink', name = 'dblite' },
--     },
--     default = { 'lsp', 'path', 'snippets', 'buffer', 'dblite' },
--   }

local SQL_KEYWORDS = {
  "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "BETWEEN", "LIKE",
  "IS NULL", "IS NOT NULL", "ORDER BY", "GROUP BY", "HAVING",
  "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL OUTER JOIN", "ON", "AS",
  "DISTINCT", "UNION", "UNION ALL", "INSERT INTO", "VALUES", "UPDATE", "SET",
  "DELETE FROM", "CREATE TABLE", "DROP TABLE", "ALTER TABLE", "TRUNCATE",
  "COMMIT", "ROLLBACK", "BEGIN", "DECLARE",
  "ROWNUM", "SYSDATE", "SYSTIMESTAMP", "NVL", "NVL2", "DECODE", "DUAL",
  "CONNECT BY", "START WITH", "PRIOR", "LEVEL",
  "ISNULL", "CONVERT", "CAST", "GETDATE", "NEWID",
  "COALESCE", "NULLIF", "CASE", "WHEN", "THEN", "ELSE", "END",
  "COUNT", "SUM", "AVG", "MIN", "MAX",
}

-- SQL keywords that can't be table aliases
local CLAUSE_WORDS = {
  WHERE=1, JOIN=1, ON=1, SET=1, GROUP=1, HAVING=1, ORDER=1,
  LIMIT=1, INNER=1, LEFT=1, RIGHT=1, FULL=1, OUTER=1, CROSS=1,
  UNION=1, EXCEPT=1, INTERSECT=1, FETCH=1, OFFSET=1, AS=1,
  SELECT=1, FROM=1, INTO=1, UPDATE=1, DELETE=1, INSERT=1, AND=1, OR=1,
}

local KIND = {
  Field    = 5,
  Variable = 6,
  Class    = 7,
  Module   = 9,
  Keyword  = 14,
}

local function insert_identifier(conn, name)
  if conn.type ~= "sqlite" then return name end
  return '"' .. name:gsub('"', '""') .. '"'
end

local function ci_key(tbl, wanted)
  if tbl[wanted] ~= nil then return wanted end
  wanted = wanted:upper()
  for key in pairs(tbl) do
    if type(key) == "string" and key:upper() == wanted then return key end
  end
end

local function resolve_fqn(sch, owner, tname)
  local owner_key = ci_key(sch.owner_tables, owner)
  if not owner_key then return end
  for _, candidate in ipairs(sch.owner_tables[owner_key]) do
    if candidate:upper() == tname:upper() then return owner_key .. "." .. candidate end
  end
end

-- Scan the buffer for FROM/JOIN [owner.]table [AS] [alias] references.
-- Returns:
--   qcols   — deduplicated columns from all referenced tables, [{name, type, src}]
--   fqn_map — {TNAME_OR_ALIAS_UPPER -> "OWNER.TABLE"} for dot-completion lookups
local function query_context(bufnr, sch, unqualified_owner)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text  = table.concat(lines, " ")

  local qcols    = {}
  local seen_col = {}
  local fqn_map  = {}

  local function add_fqn(owner, tname, alias)
    local fqn = resolve_fqn(sch, owner, tname)
    if not fqn then return end
    fqn_map[tname:upper()] = fqn
    if alias then fqn_map[alias:upper()] = fqn end
    local tbl_cols = sch.columns[fqn]
    if tbl_cols then
      for _, col in ipairs(tbl_cols) do
        if not seen_col[col.name] then
          seen_col[col.name] = true
          table.insert(qcols, { name = col.name, type = col.type, src = tname:upper() })
        end
      end
    end
  end

  -- Match FROM / JOIN  owner.table  [AS] [alias]
  -- Four passes keeps the patterns readable and avoids fragile mega-patterns.
  for _, kw_pat in ipairs({ "[Ff][Rr][Oo][Mm]", "[Jj][Oo][Ii][Nn]" }) do
    -- basic: owner.table
    for owner, tname in text:gmatch(kw_pat .. "%s+([%w_]+)%.([%w_]+)") do
      add_fqn(owner, tname, nil)
    end
    -- with AS alias: owner.table AS alias
    for owner, tname, alias in text:gmatch(
        kw_pat .. "%s+([%w_]+)%.([%w_]+)%s+[Aa][Ss]%s+([%w_]+)") do
      add_fqn(owner, tname, alias)
    end
    -- bare alias: owner.table alias  (alias must not be a SQL keyword)
    for owner, tname, alias in text:gmatch(
        kw_pat .. "%s+([%w_]+)%.([%w_]+)%s+([%w_]+)") do
      if not CLAUSE_WORDS[alias:upper()] then
        add_fqn(owner, tname, alias)
      end
    end
    if unqualified_owner then
      -- SQLite normally uses unqualified table names.
      for tname, alias in text:gmatch(kw_pat .. "%s+([%w_]+)%s+[Aa][Ss]%s+([%w_]+)") do
        add_fqn(unqualified_owner, tname, alias)
      end
      for tname, alias in text:gmatch(kw_pat .. "%s+([%w_]+)%s+([%w_]+)") do
        if not CLAUSE_WORDS[alias:upper()] then add_fqn(unqualified_owner, tname, alias) end
      end
      for tname in text:gmatch(kw_pat .. "%s+([%w_]+)") do
        add_fqn(unqualified_owner, tname, nil)
      end
      for tname, alias in text:gmatch(kw_pat .. '%s+"([^"]+)"%s+[Aa][Ss]%s+([%w_]+)') do
        add_fqn(unqualified_owner, tname, alias)
      end
      for tname, alias in text:gmatch(kw_pat .. '%s+"([^"]+)"%s+([%w_]+)') do
        if not CLAUSE_WORDS[alias:upper()] then add_fqn(unqualified_owner, tname, alias) end
      end
      for tname in text:gmatch(kw_pat .. '%s+"([^"]+)"') do
        add_fqn(unqualified_owner, tname, nil)
      end
    end
  end

  return qcols, fqn_map
end

-- ─────────────────────────────────────────────────────────────────────────────

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { ".", " ", ":" }
end

function source:get_completions(ctx, callback)
  local db     = require("dblite")
  local schema = require("dblite.schema")
  local conn   = db.get_active_conn()
  local line   = ctx.line:sub(1, ctx.cursor[2])

  local bufname  = vim.api.nvim_buf_get_name(ctx.bufnr)
  local is_binds = bufname:match("dblite%.binds%.json$") ~= nil

  -- Redis has no SQL catalog, so every suggestion below would be noise.
  if conn and conn.type == "redis" then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  -- ── dblite.binds.json: suggest table.column dotted keys ──────────────
  if is_binds then
    if not conn then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
      return
    end
    -- Non-blocking: emit columns only if the schema cache is already warm.
    -- While it's still fetching, return incomplete so blink re-queries until
    -- the catalog query lands — no dead window waiting on the DB.
    local sch = schema.peek(conn)
    if not sch then schema.prefetch(conn) end
    local items = {}
    if sch then
      for _, owner in ipairs(sch.owners) do
        for _, tname in ipairs(sch.owner_tables[owner] or {}) do
          local fqn = owner .. "." .. tname
          for _, col in ipairs(sch.columns[fqn] or {}) do
            local key = tname:lower() .. "." .. col.name:lower()
            table.insert(items, {
              label      = key,
              kind       = KIND.Field,
              detail     = col.type,
              insertText = key,
            })
          end
          table.insert(items, {
            label      = tname:lower(),
            kind       = KIND.Class,
            detail     = owner,
            insertText = tname:lower(),
          })
        end
      end
    end
    callback({ is_incomplete_forward = (sch == nil), is_incomplete_backward = false, items = items })
    return
  end

  -- ── SQL buffer ────────────────────────────────────────────────────────
  local kw_items = {}
  for _, kw in ipairs(SQL_KEYWORDS) do
    table.insert(kw_items, { label = kw, kind = KIND.Keyword, insertText = kw })
  end

  if not conn then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = kw_items })
    return
  end

  -- ── `:param` — bind keys are local (read from a file), so respond ────
  -- instantly. Column suggestions are a bonus: include them only if the
  -- schema cache is already warm, and mark the result incomplete while it
  -- isn't so blink re-queries and upgrades once the catalog query lands.
  local after_colon = (ctx.trigger and ctx.trigger.character == ":")
                   or line:match(":[a-zA-Z_][a-zA-Z0-9_.]*$") ~= nil
  if after_colon then
    local sch = schema.peek(conn)
    if not sch then schema.prefetch(conn) end
    local items = {}
    local flat = db.get_flat_binds()
    for key, val in pairs(flat) do
      local detail
      if val == vim.NIL then
        detail = "null"
      elseif type(val) == "string" then
        detail = val:sub(1, 1) == "~" and val:sub(2) or ('"' .. val .. '"')
      else
        detail = tostring(val)
      end
      table.insert(items, { label = key, kind = KIND.Variable, detail = detail, insertText = key })
    end
    if sch then
      local seen_col = {}
      for _, owner in ipairs(sch.owners) do
        for _, tname in ipairs(sch.owner_tables[owner] or {}) do
          local fqn = owner .. "." .. tname
          for _, col in ipairs(sch.columns[fqn] or {}) do
            local dotted = tname:lower() .. "." .. col.name:lower()
            if not seen_col[dotted] then
              seen_col[dotted] = true
              table.insert(items, { label = dotted, kind = KIND.Field, detail = col.type })
            end
            if not seen_col[col.name] then
              seen_col[col.name] = true
              table.insert(items, { label = col.name, kind = KIND.Field, detail = col.type })
            end
          end
        end
      end
    end
    callback({ is_incomplete_forward = (sch == nil), is_incomplete_backward = false, items = items })
    return
  end

  -- Everything below needs the schema. Peek the cache instead of blocking on
  -- the catalog query; while it's still warming, return keywords + incomplete
  -- so blink keeps re-querying and upgrades to full completions once it lands.
  local sch = schema.peek(conn)
  if not sch then
    schema.prefetch(conn)
    callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = kw_items })
    return
  end

  -- Build query-context columns and alias map from the current buffer.
  local qcols, fqn_map = query_context(ctx.bufnr, sch, conn.type == "sqlite" and "main" or nil)

  -- ── owner.table. — column completions (explicit two-level dot) ───────
  local dot2_owner, dot2_table = line:match("([%w_]+)%.([%w_]+)%.$")
  if not dot2_owner then
    dot2_owner, dot2_table = line:match('([%w_]+)%."([^"]+)"%.$')
  end
  if dot2_owner then
    local fqn  = resolve_fqn(sch, dot2_owner, dot2_table)
    local cols = fqn and sch.columns[fqn]
    local items = {}
    if cols then
      for _, col in ipairs(cols) do
        table.insert(items, {
          label = col.name,
          kind = KIND.Field,
          detail = col.type,
          insertText = insert_identifier(conn, col.name),
        })
      end
    end
    if #items == 0 then items = kw_items end
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    return
  end

  -- ── word. — owner (→ tables) OR table/alias (→ columns) ─────────────
  local after_dot = line:match("([%w_]+)%.$") or line:match('"([^"]+)"%.$')
  if after_dot then
    local upper = after_dot:upper()

    -- Is it an owner/schema?
    local owner_key = ci_key(sch.owner_tables, upper)
    local owner_tables = owner_key and sch.owner_tables[owner_key]
    if owner_tables then
      local items = {}
      for _, tname in ipairs(owner_tables) do
        table.insert(items, {
          label = tname,
          kind = KIND.Class,
          detail = owner_key,
          insertText = insert_identifier(conn, tname),
        })
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
      return
    end

    -- Is it a table name or alias referenced in this query?
    local fqn = fqn_map[upper]
    if fqn then
      local cols = sch.columns[fqn]
      if cols then
        local items = {}
        for _, col in ipairs(cols) do
          table.insert(items, {
            label = col.name,
            kind = KIND.Field,
            detail = col.type,
            insertText = insert_identifier(conn, col.name),
          })
        end
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
        return
      end
    end

    -- Unknown word before dot — fall through to general context
  end

  -- ── after FROM / JOIN / INTO / UPDATE — owner names first ────────────
  local after_kw = line:match('[Ff][Rr][Oo][Mm]%s+["%w_]*$')
                or line:match('[Jj][Oo][Ii][Nn]%s+["%w_]*$')
                or line:match('[Ii][Nn][Tt][Oo]%s+["%w_]*$')
                or line:match('[Uu][Pp][Dd][Aa][Tt][Ee]%s+["%w_]*$')
  if after_kw then
    local items = {}
    if conn.type == "sqlite" then
      for _, tname in ipairs(sch.owner_tables.main or {}) do
        table.insert(items, {
          label = tname,
          kind = KIND.Class,
          detail = "main",
          insertText = '"' .. tname:gsub('"', '""') .. '"',
        })
      end
    else
      for _, o in ipairs(sch.owners) do
        local n = sch.owner_tables[o] and #sch.owner_tables[o] or 0
        table.insert(items, { label = o, kind = KIND.Module, detail = n .. " tables" })
      end
    end
    vim.list_extend(items, kw_items)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    return
  end

  -- ── after SELECT / WHERE / AND / OR / SET / ON — columns first ───────
  local after_clause = line:match("[Ss][Ee][Ll][Ee][Cc][Tt]%s+$")
                    or line:match("[Ss][Ee][Ll][Ee][Cc][Tt]%s+.-%,%s*$")
                    or line:match("[Ww][Hh][Ee][Rr][Ee]%s+$")
                    or line:match("[Aa][Nn][Dd]%s+$")
                    or line:match("[Oo][Rr]%s+$")
                    or line:match("[Ss][Ee][Tt]%s+$")
                    or line:match("[Oo][Nn]%s+$")
  if after_clause and #qcols > 0 then
    local items = {}
    for _, col in ipairs(qcols) do
      table.insert(items, {
        label        = col.name,
        kind         = KIND.Field,
        detail       = col.type .. "  " .. col.src,
        insertText   = insert_identifier(conn, col.name),
        score_offset = 5,
      })
    end
    vim.list_extend(items, kw_items)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    return
  end

  -- ── general — query columns first, then owners + keywords ────────────
  local items = {}
  for _, col in ipairs(qcols) do
    table.insert(items, {
      label        = col.name,
      kind         = KIND.Field,
      detail       = col.type .. "  " .. col.src,
      insertText   = insert_identifier(conn, col.name),
      score_offset = 3,
    })
  end
  vim.list_extend(items, kw_items)
  for _, o in ipairs(sch.owners) do
    local n = sch.owner_tables[o] and #sch.owner_tables[o] or 0
    table.insert(items, { label = o, kind = KIND.Module, detail = n .. " tables" })
  end
  callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
end

return source
