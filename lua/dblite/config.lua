local function resolve_binary()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local plugin_root = src:sub(2):gsub("/lua/dblite/config%.lua$", "")
    local candidate = plugin_root .. "/bin/dblite"
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return "dblite"  -- fallback: binary must be on PATH
end

local M = {
  binary = resolve_binary(),
  -- Filetypes dblite attaches to: editor keymaps (below) are set buffer-local
  -- on these, and `on_attach` fires for each such buffer.
  filetypes = { "sql", "plsql", "mysql", "sqlite" },
  -- Optional per-buffer hook: on_attach(bufnr) runs once for every SQL buffer
  -- (after the built-in editor keymaps are applied). Use it for custom,
  -- buffer-local keybinds/behaviour instead of hand-rolled autocmds, e.g.
  --   on_attach = function(buf)
  --     local d, o = require("dblite"), { buffer = buf, silent = true }
  --     vim.keymap.set("n", "<leader>r",  d.execute,           o)
  --     vim.keymap.set("n", "<leader>rr", d.execute_at_cursor, o)
  --     vim.keymap.set("n", "<leader>rb", function() d.run_async() end, o)
  --   end
  on_attach = nil,
  max_rows = 10000,
  split_dir = "horizontal", -- "vertical" | "horizontal" | "tab"
  split_size = {
    width = 80,   -- columns; used when split_dir = "vertical". 0 = let nvim decide.
    height = 20,  -- rows;    used when split_dir = "horizontal". 0 = let nvim decide.
  },
  filetype = "", -- buffer filetype for results. "" disables highlighting (fastest for huge results).
  page_size = 100,    -- rows per page in the result buffer
  max_col_width = 50, -- truncate cell values wider than this; 0 = no limit
  max_history = 20,        -- number of past query results kept in history; 0 = unlimited
  show_column_types = false, -- show [TYPE] next to column headers by default (toggle with d)
  panel = {
    width = 30,  -- columns for the side panel
  },
  jobs = {  -- the activity panel: bulk exports (`:Dblite run bulk`) and watches
    panel = { width = 44 },  -- activity panel: right-side vertical split, this many columns wide
    cleanup_delay  = 300,    -- seconds a finished job lingers in the LIVE list before removal (it stays visible via history); 0 = keep until deleted
    default_format = "csv",  -- default output format for bulk exports: "csv" | "json"
    open_on_start  = true,   -- pop the jobs panel open automatically when a bulk export starts
    close_on_open  = true,   -- close the jobs panel after opening a finished job's output file
    focus          = true,   -- when you toggle/open the panel (`:DbliteJobs`), move the cursor into it. false = keep the cursor where it is
    history = {  -- persistent job history, shared across all Neovim instances
      enabled     = true,    -- record finished jobs to disk (false = in-memory only)
      show        = 20,      -- how many past jobs to display in the panel (0 = all kept)
      start_open  = false,   -- expand the folded History section when the panel opens
      max_entries = 200,     -- hard cap on stored jobs; oldest are dropped past this
      -- file: defaults to stdpath("data").."/dblite/jobs.json". Set to override.
    },
  },
  watch = {  -- repeating queries — see `:DbliteWatch`
    default_interval  = "30s",      -- time between ticks when none is given
    default_max       = 50,         -- tick cap when none is given; 0 = unlimited
    default_condition = "changed",  -- what to wait for by default; see :h dblite-watch-conditions
    max_active        = 5,          -- refuse to start more than this many at once (0 = no cap)
    stop_after_errors = 3,          -- consecutive failed ticks before giving up (0 = never)
    notify            = true,       -- vim.notify when a watch matches, fails, or runs out
    cleanup_delay     = 0,          -- seconds a finished watch lingers in the panel; 0 = until dismissed
    log_size          = 100,        -- per-watch tick log entries kept for the hover view
    prompt            = true,       -- `:DbliteWatch` with no args opens the popup; false = use defaults
  },
  -- How `:DblitePanel` / `M.toggle_panel()` select a connection:
  --   "panel"     → the built-in side panel (default)
  --   "telescope" → a telescope.nvim picker (requires nvim-telescope/telescope.nvim)
  -- `:DbliteConnPicker` always opens the telescope picker regardless of this setting.
  connection_picker = "panel",
  telescope_picker = {  -- sizing/behaviour for the telescope connection picker
    preview       = true, -- show a side preview with connection details (password masked)
    width         = 0.4,  -- picker width:  fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,  -- picker height: fraction of editor (<= 1) or absolute rows (> 1)
    preview_width = 0.5,  -- preview pane width as a fraction of the picker (when preview = true)
  },
  binds_split = {
    style        = "split",    -- "split" | "float"
    split_dir    = "vertical", -- "vertical" | "horizontal" (split only)
    width        = 40,         -- columns for vertical split. 0 = let nvim decide.
    height       = 20,         -- rows for horizontal split. 0 = let nvim decide.
    float_width  = 0,          -- float width in columns.  0 = 70% of editor width.
    float_height = 0,          -- float height in rows.    0 = 60% of editor lines.
  },
  flash_timeout  = 2000,  -- ms to hold the query highlight before auto-clearing (0 = wait for results)
  json_view      = "tab",  -- where to open the inspector: "tab" | "vertical" | "horizontal" | "float"
  load_view      = "tab",  -- where to open the CSV-load preview: "tab" | "vertical" | "horizontal" | "float"
  inspect_format = "json", -- default inspect format: "json" | "table" | "csv"
  inspect_expand_json = true, -- in json inspect, decode cell values that are themselves JSON strings so they nest cleanly
  style = {
    dbout = {
      cursorline = false, -- highlight the line under the cursor in dbout
      -- Each section: { "item", sep = "separator_before", hl = "HlGroup" }
      -- Items: "pagination" | "query_time" | "connection" | "binds_file"
      -- sep defaults to "  ·  " for non-first visible items
      sections = {
        { "history" },
        { "pagination", sep = "  " },
        { "query_time", sep = "  —  " },
        { "connection", sep = "  ·  " },
      },
    },
  },
  keymaps = {
    global = {  -- normal-mode keymaps active from any buffer/window; all disabled by default
      run           = "", -- run the whole buffer
      run_at        = "", -- run the statement under the cursor
      run_script    = "", -- run the buffer as a SQL*Plus script
      run_bulk      = "", -- background bulk export to a file
      watch         = "", -- watch the statement under the cursor
      watch_file    = "", -- watch the whole buffer
      toggle_dbout  = "", -- show/hide the result window
      toggle_panel  = "", -- toggle the connections panel
      toggle_jobs   = "", -- toggle the background-jobs panel
      toggle_binds  = "", -- toggle dblite.binds.json
      inspect       = "", -- inspect current page untruncated
      fullscreen    = "", -- toggle dbout fullscreen
      connections   = "", -- open the connections JSON file
    },
    dbout = {  -- keymaps active inside the result/output buffer
      next    = "L",       -- next page (set to "" or false to disable)
      prev    = "H",       -- prev page
      cancel  = "<C-c>",  -- kill in-flight query
      inspect      = "gi",      -- open inspector for current page
      history_prev = "[",       -- previous query result in history
      history_next = "]",       -- next query result in history
      hover_query  = "K",       -- hover to show the executed query
      toggle_types = "d",       -- toggle column type annotations
      toggle_dbout = "",        -- show/hide the result window from inside dbout
    },
    -- Editor keymaps are buffer-local and set ONLY in SQL buffers (see
    -- `filetypes` below), so they never fire in unrelated buffers/windows.
    -- Everything except binds/fullscreen/hover_bind defaults to "" (disabled) —
    -- set an lhs to enable it. For anything more custom, use `on_attach`.
    editor = {
      run          = "",           -- run the whole buffer                (M.execute)
      run_at       = "",           -- run the statement under the cursor  (M.execute_at_cursor)
      run_script   = "",           -- run the buffer as a SQL*Plus script (M.execute_script)
      run_bulk     = "",           -- background bulk export to a file    (M.run_async)
      watch        = "",           -- watch the statement under the cursor (M.watch)
      watch_file   = "",           -- watch the whole buffer               (M.watch_file)
      toggle_dbout = "",           -- show/hide the result window         (M.toggle_dbout)
      toggle_panel = "",           -- toggle the connections panel        (M.toggle_panel)
      toggle_jobs  = "",           -- toggle the background-jobs panel     (M.toggle_jobs)
      inspect      = "",           -- inspect current page untruncated    (M.inspect)
      binds        = "<leader>b",  -- open dblite.binds.json popup         (M.edit_binds)
      connections  = "",           -- open the connections JSON file       (M.edit_connections_file)
      fullscreen   = "<leader>l",  -- toggle dbout fullscreen              (M.toggle_fullscreen)
      hover_bind   = "K",          -- hover to show bind value under cursor (M.hover_bind)
    },
    panel = {    -- keymaps active inside the connections panel
      select = "<CR>", -- activate connection under cursor
      edit   = "cw",   -- edit connection under cursor
      close  = "q",    -- close panel
      toggle = "",     -- toggle the panel from inside
    },
    binds = {     -- keymaps active inside dblite.binds.json
      toggle = "",     -- toggle the binds window from inside
    },
    jobs = {     -- keymaps active inside the activity panel
      open     = "<CR>",  -- job: open its output file · watch: show its latest result in dbout
      cancel   = "x",     -- stop a running job/watch, or remove a finished one; default also maps "X"
      hover    = "K",     -- details of the entry under the cursor (watches include their tick log)
      relocate = "r",     -- re-point a job at a moved/renamed output file (persists the new path)
      fold     = "<Tab>", -- fold/unfold the finished-exports History section
      close    = "q",     -- close the panel
      toggle   = "",      -- toggle the panel from inside (set to your open key for symmetry)
    },
    load = {     -- keymaps active inside the CSV-load preview buffer
      commit = "<CR>", -- run the generated INSERTs
      cancel = "q",    -- discard the preview without running
    },
  },
}

return M
