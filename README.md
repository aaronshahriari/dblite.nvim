<div align="center">

<img src="dblite_logo.svg" alt="dblite.nvim" width="400" />

# dblite.nvim

Query **Oracle**, **SQL Server**, and **SQLite** from Neovim — write SQL in any buffer, run it, and page results in a split.

![Neovim 0.11+](https://img.shields.io/badge/Neovim-0.11+-4c566a?style=flat-square&logo=neovim&logoColor=white)
![GraalVM native](https://img.shields.io/badge/GraalVM-native%20·%20no%20JVM-4c566a?style=flat-square)

[Features](#features) · [Install](#installation) · [Quick start](#quick-start) · [Configuration](#configuration)

</div>

<div align="center">

<a href="https://www.youtube.com/watch?v=pNn2kxlpTro">
  <img src="https://img.youtube.com/vi/pNn2kxlpTro/maxresdefault.jpg" alt="Watch the dblite.nvim demo on YouTube" width="640" />
</a>

<sub>▶ <b><a href="https://www.youtube.com/watch?v=pNn2kxlpTro">Watch the demo on YouTube</a></b></sub>

</div>

The database work runs in a native binary (GraalVM), so there's **no JVM at runtime** — it's downloaded pre-built on install, falling back to a source build only if no binary matches your platform.

<!-- DEMO SCREENSHOT: save the screenshot to the repo root as `dblite_demo.png`,
     then delete this comment wrapper (the two lines marked <<< / >>>) to show it.
<<<
<div align="center">

<img src="dblite_demo.png" alt="dblite.nvim running a query with results in the dbout split" width="900" />

<sub>A query in a `.sql` buffer, results paginated in the <b>dbout</b> split with timing and connection in the status line.</sub>

</div>
>>>
-->

## Features

- **Run from any buffer** — the whole buffer, or just the statement under the cursor (treesitter-aware).
- **Paginated result split** with column-type annotations, query timing, and a per-session result history you can page back through.
- **Named connections** with `$ENV_VAR` password references, stored at `chmod 600`.
- **Typed bind parameters** from a `dblite.binds.json` file — numbers, quoted strings, and raw SQL expressions.
- **Export** the entire result set (not just the current page) to CSV or JSON.
- **Bulk background exports** — stream huge queries straight to a file asynchronously (no row cap), tracked in a jobs panel with live progress, while you keep working.
- **Load** a CSV into a table with a SQL\*Loader-style `LOAD DATA` block — previewed as `INSERT`s before you commit.
- **Inspect** any page untruncated as JSON, table, or CSV.
- **Inline queries from Lua** — `db.inline{ conn = 'prod', sql = ... }` runs headlessly and hands you the rows, so you can embed a query in a keymap, timer or autocommand without touching the UI.
- **SQL autocomplete** via [blink.cmp](https://github.com/Saghen/blink.cmp) — tables, columns, and bind names from the live schema.
- **Connection UI** — a built-in side panel, or an opt-in [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker.

## Requirements

- Neovim 0.11+
- Optional: [`jq`](https://jqlang.github.io/jq/) (prettier JSON), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (picker), [blink.cmp](https://github.com/Saghen/blink.cmp) (completion)
- Only if building from source (no prebuilt binary for your platform): GraalVM `native-image`

## Installation

The binary is fetched automatically on install and update.

**vim.pack (Neovim 0.11+)** — register the `PackChanged` hook **before** `vim.pack.add()`:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == 'dblite' and (kind == 'install' or kind == 'update') then
      require('dblite.download').download_or_build()
    end
  end,
})

vim.pack.add({ { src = 'https://github.com/aaronshahriari/dblite.nvim' } })
require('dblite').setup()
```

If the hook wasn't in place on first install, run `:DbliteBuild` manually.

**lazy.nvim** — the bundled `build.lua` is picked up automatically, so no `build =` key is needed:

```lua
{ 'aaronshahriari/dblite.nvim', config = function() require('dblite').setup() end }
```

<details>
<summary>Other plugin managers</summary>

```vim
" vim-plug
Plug 'aaronshahriari/dblite.nvim', { 'do': ':DbliteBuild' }
```

```lua
-- packer.nvim
use { 'aaronshahriari/dblite.nvim', run = ':DbliteBuild' }
```

```sh
# Manual
git clone https://github.com/aaronshahriari/dblite.nvim
```

For a manual install, add the directory to `runtimepath`, call `require('dblite').setup()`, and run `:DbliteBuild`.

</details>

## Quick start

```vim
:DbliteAddConn oracle://system:oracle@localhost:1521/XEPDB1   " add a connection
:DbliteUseConn XEPDB1                                          " make it active
```

For SQLite, point the URI at an existing database file:

```vim
:DbliteAddConn sqlite:///absolute/path.db
```

Then write SQL in any buffer and run it:

```vim
:Dblite run       " run the whole buffer
:Dblite run at    " run the statement under the cursor
```

Results open in the **dbout** split. Page with `L`/`H`, walk history with `[`/`]`, hover `K` to see the executed SQL.

## Connections

Connections live at `~/.local/share/nvim/dblite/connections.json` (`chmod 600`). Passwords can be stored as `$ENV_VAR` references and are expanded from the environment at query time.

| Command | Description |
|---|---|
| `:DbliteAddConn [uri]` | Add a connection (URI, or prompts field-by-field) |
| `:DbliteListConns` | List connections; active one marked `*` |
| `:DbliteUseConn <name>` | Set the active connection |
| `:DbliteEditConn <name>` | Edit a saved connection |
| `:DbliteDeleteConn <name>` | Delete a connection |
| `:Dblite conn file` | Open the raw connections JSON |
| `:DbliteConnPicker` | Pick a connection with a telescope picker |

Name arguments support tab-completion.

**URI formats** — port defaults to `1521` (Oracle) / `1433` (SQL Server) when omitted:

```
oracle://user[:password]@host[:port]/service
sqlserver://user[:password]@host[:port]/database
sqlite:///absolute/path.db
```

SQLite paths must point to an existing regular file. `:memory:` is unsupported because each command starts a new process and database connection. Run `:DbliteAddConn` without an argument to enter a URI interactively; leave that prompt blank for field-by-field setup (SQLite asks for type and database path). URI setup still prompts for a connection name.

SQL Server connections use `encrypt=true;trustServerCertificate=true` for broad compatibility with local dev and Azure SQL.

## Running queries

| Command | Description |
|---|---|
| `:Dblite run` | Run the entire buffer |
| `:Dblite run at` | Run the statement under the cursor (treesitter-aware) |
| `:Dblite toggle dbout` | Show/hide the result window (query keeps running if in-flight) |
| `:Dblite inspect [json\|table\|csv]` | Open the current page untruncated in a scratch window |
| `:Dblite export <csv\|json> [path]` | Write the **entire** result set to a file |
| `:Dblite run bulk <csv\|json> [path]` | Run the current query **in the background**, streaming the full result straight to a file |
| `:Dblite jobs` | Toggle the background-jobs panel |
| `:Dblite load` | Load a CSV into a table from a `LOAD DATA` control block (preview, then commit) |

Trailing semicolons are stripped automatically. The legacy `:DbliteRun`, `:DbliteRunAt`, and `:DbliteToggleOut` commands remain as aliases. Running from a different tab moves the dbout split to that tab.

**dbout keymaps:**

| Key | Action | Key | Action |
|---|---|---|---|
| `L` / `H` | Next / previous page | `[` / `]` | Previous / next result in history |
| `K` | Hover the query that produced this result | `d` | Toggle column type annotations |
| `gi` | Inspect current page (untruncated) | `<leader>l` | Toggle dbout fullscreen |
| `<C-c>` | Cancel in-flight query | | |

`<C-c>` also cancels from any buffer while a query runs — dblite sets it globally for the duration and restores your mapping afterward.

## More

<details>
<summary><b>Bind parameters</b></summary>

Bind params come from a `dblite.binds.json` file in the current working directory. Create/edit it with `:Dblite binds` or `<leader>b`; it's re-read on every query. When you run a query with missing params, the file opens so you can fill them in, then re-run.

```json
{
  "status": "pending",
  "user_id": 42,
  "name": "O'Brien",
  "dt": "~SYSDATE"
}
```

Values are typed and formatted for SQL automatically:

| JSON / prefix | SQL output |
|---|---|
| JSON number | verbatim — `42` → `42` |
| String | auto-quoted, single-quotes escaped — `"O'Brien"` → `'O''Brien'` |
| String starting with `~` | raw SQL expression — `"~SYSDATE"` → `SYSDATE` |

The binds window is a vertical split by default; set `binds_split.style = 'float'` for a centered float. Add `"binds_file"` to `style.dbout.sections` to show a `binds` badge when the file exists in the cwd.

</details>

<details>
<summary><b>Exporting results</b></summary>

`:Dblite export csv|json` (or `:DbliteExport`) writes the **full** result set — every row, not just the current page — to a file:

```
:Dblite export csv ~/exports/jobs.csv
:Dblite export json ./out/jobs.json
:DbliteExport csv                       " omit the path to be prompted (with completion)
```

`~`, env vars, and relative paths are expanded, and missing parent directories are created. CSV is RFC-4180 escaped; JSON is pretty-printed via `jq` when available (compact fallback otherwise).

`export` works off the result set already loaded in dbout, so it's capped by `max_rows`. To dump **more rows than `max_rows`** — or to keep working while a huge query runs — use a **bulk background export** instead (below).

</details>

<details>
<summary><b>Bulk background exports</b></summary>

`:Dblite run bulk csv|json [path]` (or `:DbliteRunBulk`) runs the query at the cursor (or the whole buffer) **asynchronously**, streaming the full result set straight to a file via the native binary — no `max_rows` cap and no in-editor buffering, so it handles arbitrarily large pulls (e.g. 50k+ rows) without blocking your session:

```
:Dblite run bulk csv ~/exports/big.csv
:Dblite run bulk json ./out/big.json
:DbliteRunBulk csv                      " omit the path to be prompted (with completion)
:'<,'>DbliteRunBulk csv                 " export just the selected statement(s)
```

Both commands accept a range, so you can visually select some SQL and dump exactly that — the selection is expanded to the whole statement(s) it touches. The `run_bulk` keymap also fires from visual mode.

Jobs run in the background, so you can keep running normal queries meanwhile. `:Dblite jobs` (or `:DbliteJobs`) toggles a floating **jobs panel** showing status, output file name, duration, and exported row count.

**Persistent history:** finished jobs are recorded to a shared store (`stdpath('data')/dblite/jobs.json` by default), so the panel shows your past exports even across restarts and **across every Neovim instance** on the machine. Control it via `jobs.history`: `show` (how many past jobs to display, e.g. last 10/50), `max_entries` (how many to keep on disk), or `enabled = false` for in-memory only. Deleting a finished entry (`x`) prompts first, then removes it from the store; cancelling a running job also prompts first.

**Jobs panel keymaps:**

| Key | Action |
|---|---|
| `<CR>` | Open the output file of the job under the cursor in a new tab |
| `x` | Cancel a running job / delete a finished one from history |
| `q` | Close the panel |
| `keymaps.jobs.toggle` | Toggle the panel from inside (off by default; set to your open key for symmetry) |

There is **no client-side query timeout**, so a bulk export runs until the database returns — fine for multi-minute queries. Bind parameters are resolved the same way as normal queries.

> **Note:** bulk export needs a native binary that includes `--to-file` support. If you installed a pre-built release binary, force a source rebuild with `:DbliteBuild!` (or `:Dblite build force`) to pick it up — plain `:DbliteBuild` downloads the latest *release*, which may not include it yet.

</details>

<details>
<summary><b>Loading CSV data</b></summary>

Write a SQL\*Loader-style control block in any buffer and run `:Dblite load` (or `:DbliteLoad`). dblite parses it, reads the CSV, and opens a **preview** of the `INSERT`s it will run — nothing touches the database until you commit:

```
LOAD DATA
INFILE 'employees.csv'
INTO TABLE employees
SKIP 1
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
( employee_id, name, department )
```

In the preview buffer, press `<CR>` to commit — the `INSERT`s run through script mode and land as a per-row OK/ERROR log in dbout — or `q` to cancel. The preview is editable SQL, so you can tweak it before committing. Keys are set by `keymaps.load`; the window style by `load_view` (`tab` | `vertical` | `horizontal` | `float`).

> This is an **emulation**, not real `sqlldr` — the `dblite` binary has no Oracle client, so a practical subset of the control syntax is converted to `INSERT`s and run over your existing JDBC connection.

| Control clause | Behaviour |
|---|---|
| `INFILE 'path'` | CSV path — relative to cwd, `~` and `$ENV_VAR` expanded (`INFILE *` unsupported) |
| `INTO TABLE name` | Target table; optional `APPEND` (default), `REPLACE` (DELETE first), or `TRUNCATE` (`DELETE FROM` on SQLite) |
| `SKIP n` | Skip the first `n` rows (e.g. a header) |
| `FIELDS TERMINATED BY 'c'` | Field separator (default `,`; also `X'09'` hex, e.g. tab) |
| `(OPTIONALLY) ENCLOSED BY 'c'` | Quote character (default `"`) |
| `TRAILING NULLCOLS` | Pad rows with fewer fields than columns as `NULL` |
| `( col, col, ... )` | Target columns, in file order |

Values are typed best-effort: numbers unquoted, empty fields become `NULL`, everything else is single-quoted (with `''` escaping). Dates rely on Oracle's implicit NLS conversion. Per-column datatypes/transforms, positional fields, and direct-path are not supported.

</details>

<details>
<summary><b>Result history</b></summary>

Every successful query is saved to a history ring. Page past results with `[` / `]` — the status line shows `◀ 2/5 ▶` when multiple entries exist. Press `K` to hover the executed SQL (bind params already substituted), SQL-highlighted, auto-dismissing on cursor move.

Size is controlled by `max_history` (default `20`; `0` = unlimited).

</details>

<details>
<summary><b>Column types</b></summary>

Press `d` in the dbout buffer to toggle database type annotations in the header:

```
EMPLOYEE_ID [NUMBER] | FIRST_NAME [VARCHAR2] | HIRE_DATE [DATE]
```

Show them by default with `show_column_types = true`. Annotations use the `DbliteColumnType` highlight (links to `Comment`); override via `style.dbout.column_type_hl`.

</details>

<details>
<summary><b>Inspect</b></summary>

`gi` (or `:Dblite inspect`) opens the current page in a scratch window with no truncation. Tab-complete the format:

| Format | Description |
|---|---|
| `json` | Pretty-printed via `jq` (raw fallback) |
| `table` | Same layout as dbout, widths fit content |
| `csv` | RFC-4180 escaped |

Opens per `json_view` (default `"tab"`); `q` closes. In `json`, cell values that are themselves serialized JSON are decoded and nested inline instead of shown as an escaped blob — set `inspect_expand_json = false` to keep raw strings.

</details>

<details>
<summary><b>Autocomplete (blink.cmp)</b></summary>

Add the source to your blink config:

```lua
sources = {
  providers = { dblite = { module = 'dblite.blink', name = 'dblite' } },
  default = { 'lsp', 'path', 'snippets', 'buffer', 'dblite' },
}
```

| Context | Completions |
|---|---|
| Any SQL buffer | SQL keywords + table names |
| After `FROM` / `JOIN` / `INTO` / `UPDATE` | table names first |
| After `table.` | that table's columns |
| After `:` | existing `dblite.binds.json` keys + columns as bind suggestions |
| Inside `dblite.binds.json` | dotted column keys like `orders.id` |

Schema is fetched once per connection switch in the background, then served from cache. It uses whatever connection `:DbliteUseConn` set — no extra config. For SQLite, completion covers tables and views in the `main` schema.

</details>

<details>
<summary><b>Connections panel & telescope picker</b></summary>

`:DblitePanel` toggles a side panel of saved connections (active one marked `✓`):

| Key | Action |
|---|---|
| `<CR>` | Activate the connection under the cursor |
| `cw` | Edit it |
| `q` | Close the panel |

Prefer a fuzzy picker? Set `connection_picker = "telescope"` (requires telescope.nvim, **off by default**). Then `:DblitePanel` opens the picker instead; the active connection is marked `●` and the preview pane masks the password. `:DbliteConnPicker` always opens the picker regardless of the setting, so you can bind it directly:

```lua
require('dblite').setup({
  connection_picker = 'telescope',
  telescope_picker = {
    preview       = true, -- show the details preview pane
    width         = 0.4,  -- fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,
    preview_width = 0.5,  -- preview width as a fraction of the picker
  },
})
vim.keymap.set('n', '<leader>dc', '<cmd>DbliteConnPicker<cr>', { desc = 'dblite: pick connection' })
```

</details>

## API

Everything is callable from Lua — handy for custom keymaps:

```lua
local db = require('dblite')
db.execute()               -- run the current buffer
db.execute_at_cursor()     -- run the statement under the cursor
db.toggle_dbout()          -- show/hide the result window
db.inspect(format)         -- 'json' | 'table' | 'csv'
db.load()                  -- preview + commit a LOAD DATA control block in the buffer
db.toggle_binds()          -- toggle the dblite.binds.json split
db.toggle_panel()          -- toggle the connections panel
db.get_active_conn()       -- active connection object, or nil
db.get_flat_binds()        -- flattened dblite.binds.json as a table
db.inline(opts, cb)        -- run a query headlessly, no UI (see below)
```

### Inline queries

`db.inline()` runs a statement on a **named** saved connection and hands the rows
back to Lua. It is the only run path with no UI at all: no result window, no
spinner, no history entry, no jobs panel — and it neither reads nor changes the
active connection. Embed it in keymaps, timers, autocommands or your own plugins.

```lua
require('dblite').inline({
  conn = 'prod',
  sql  = 'select expires_at from creds where service = :svc',
  binds = { svc = 'prod-aws' },
}, function(err, res)
  if err then return vim.notify(err, vim.log.levels.ERROR) end
  vim.notify('creds expire ' .. res.rows[1].EXPIRES_AT)
end)
```

Rows come back keyed by column label (`res.rows[1].EXPIRES_AT`), which is the
binary's own wire format. `res.values` gives the same rows positionally, and
`res.json` the raw JSON if you would rather parse it yourself.

| option | default | |
| --- | --- | --- |
| `sql` | — | statement to run (required) |
| `conn` | — | name of a saved connection (required) |
| `binds` | `{}` | values for `:name` references |
| `binds_file` | `false` | also read `dblite.binds.json` from the cwd |
| `max_rows` | `config.max_rows` | row cap; `0` = uncapped |
| `script` | `false` | run as a multi-statement script |
| `timeout` | — | ms before the query is killed |
| `null_as_nil` | `false` | decode SQL `NULL` as `nil` instead of `vim.NIL` |
| `sync` | `false` | block and return instead of calling back |

Async by default: it returns the `vim.system()` handle (so you can `job:kill(15)`)
and your callback runs on the main loop, safe for `vim.notify` and API calls.
Pass `sync = true` to get `res, err` directly — handy in a statusline, but pair
it with `timeout` so a slow query cannot freeze the editor.

```lua
local res, err = require('dblite').inline({
  conn = 'prod', sql = 'select count(*) n from jobs where state = 1',
  sync = true, timeout = 2000,
})
```

Nothing throws. A missing binary, unknown connection, unresolved bind or SQL
error all arrive as an error string, with `res` nil. Full reference:
`:help dblite-inline`.

<details>
<summary>Full API surface</summary>

```lua
db.open_binds()            -- open/focus the binds split (does not close)
db.edit_binds()            -- alias for toggle_binds()
db.edit_connections_file() -- open connections JSON for direct editing
db.open_panel()            -- open the panel
db.close_panel()           -- close the panel
db.is_panel_open()         -- true/false
```

</details>

## Configuration

`setup()` takes no options if you're happy with the defaults. Common ones:

```lua
require('dblite').setup({
  split_dir         = 'horizontal', -- 'vertical' | 'horizontal' | 'tab'
  page_size         = 100,          -- rows per page
  max_rows          = 10000,        -- hard cap on rows returned
  max_col_width     = 50,           -- truncate wider cells; 0 = no limit
  max_history       = 20,           -- results kept in history; 0 = unlimited
  show_column_types = false,        -- show [TYPE] headers by default
  connection_picker = 'panel',      -- 'panel' | 'telescope'
})
```

<details>
<summary>All options & defaults</summary>

```lua
require('dblite').setup({
  split_dir      = 'horizontal',  -- 'vertical' | 'horizontal' | 'tab'
  split_size     = { width = 80, height = 20 },
  page_size      = 100,           -- rows per page in the result buffer
  max_rows       = 10000,         -- hard cap on rows returned
  max_col_width  = 50,            -- truncate cells wider than this; 0 = no limit
  max_history    = 20,            -- past query results to keep; 0 = unlimited
  show_column_types = false,      -- show [TYPE] next to column headers by default
  filetypes      = { 'sql', 'plsql', 'mysql', 'sqlite' }, -- buffers dblite attaches to (editor keymaps + on_attach)
  on_attach      = nil,           -- function(bufnr) run per SQL buffer for custom buffer-local keybinds
  filetype       = '',            -- filetype for the result buffer ('' = no highlighting)
  flash_timeout  = 2000,          -- ms to hold the query highlight; 0 = hold until results
  json_view      = 'tab',         -- where inspect opens: 'tab' | 'vertical' | 'horizontal' | 'float'
  load_view      = 'tab',         -- where the CSV-load preview opens: 'tab' | 'vertical' | 'horizontal' | 'float'
  inspect_format = 'json',        -- default inspect format: 'json' | 'table' | 'csv'
  inspect_expand_json = true,     -- json inspect: decode cell values that are themselves JSON strings
  panel = {
    width = 30,                   -- side panel width in columns
  },
  jobs = {                        -- background bulk-export jobs (:Dblite run bulk)
    panel = { width = 46 },       -- jobs-panel width in columns
    cleanup_delay  = 300,         -- seconds a finished job lingers in the live list; 0 = keep until dismissed
    default_format = 'csv',       -- default bulk format: 'csv' | 'json'
    open_on_start  = true,        -- auto-open the jobs panel when a bulk export starts
    focus          = true,        -- move the cursor into the panel when you toggle it open
    history = {                   -- persistent job history, shared across all Neovim instances
      enabled     = true,         -- record finished jobs to disk (false = in-memory only)
      show        = 20,           -- how many past jobs to display in the panel (0 = all kept)
      max_entries = 200,          -- hard cap on stored jobs; oldest dropped past this
      -- file = stdpath('data')..'/dblite/jobs.json'  -- override the store location
    },
  },
  connection_picker = 'panel',    -- 'panel' | 'telescope' (requires telescope.nvim)
  telescope_picker = {
    preview       = true,         -- show the connection-details preview (password masked)
    width         = 0.4,          -- fraction of editor (<= 1) or absolute columns (> 1)
    height        = 0.4,
    preview_width = 0.5,          -- preview pane width as a fraction of the picker
  },
  binds_split = {
    style        = 'split',       -- 'split' | 'float'
    split_dir    = 'vertical',    -- 'vertical' | 'horizontal' (split only)
    width        = 40,            -- columns for vertical split. 0 = let nvim decide.
    height       = 20,            -- rows for horizontal split. 0 = let nvim decide.
    float_width  = 0,             -- float width in columns.  0 = 70% of editor width.
    float_height = 0,             -- float height in rows.    0 = 60% of editor lines.
  },
  style = {
    dbout = {
      cursorline = false,         -- highlight the line under the cursor
      column_type_hl = 'DbliteColumnType',
      -- Status line sections. Each entry: { "item", sep = "…", hl = "HlGroup" }
      -- Available items: "history" | "pagination" | "query_time" | "connection" | "binds_file"
      sections = {
        { "history" },
        { "pagination", sep = "  " },
        { "query_time", sep = "  —  " },
        { "connection", sep = "  ·  " },
      },
    },
  },
  keymaps = {
    global = {  -- active from any buffer/window. '' = disabled.
      run           = '',          -- run the whole buffer
      run_at        = '',          -- run the statement under the cursor
      run_script    = '',          -- run the buffer as a SQL*Plus script
      run_bulk      = '',          -- background bulk export to a file
      toggle_dbout  = '',          -- show/hide the result window
      toggle_panel  = '',          -- toggle the connections panel
      toggle_jobs   = '',          -- toggle the background-jobs panel
      toggle_binds  = '',          -- toggle dblite.binds.json
      inspect       = '',          -- inspect current page untruncated
      fullscreen    = '',          -- toggle dbout fullscreen
      connections   = '',          -- open the connections JSON file
    },
    dbout = {
      next = 'L', prev = 'H', cancel = '<C-c>', inspect = 'gi',
      history_prev = '[', history_next = ']', hover_query = 'K', toggle_types = 'd',
      toggle_dbout = '',
    },
    editor = {  -- buffer-local, set only in `filetypes` buffers. '' = disabled.
      run          = '',          -- run the whole buffer
      run_at       = '',          -- run the statement under the cursor
      run_script   = '',          -- run the buffer as a SQL*Plus script
      run_bulk     = '',          -- background bulk export to a file
      toggle_dbout = '',          -- show/hide the result window
      toggle_panel = '',          -- toggle the connections panel
      toggle_jobs  = '',          -- toggle the background-jobs panel
      inspect      = '',          -- inspect current page untruncated
      binds        = '<leader>b', -- toggle dblite.binds.json split
      connections  = '',          -- open the connections JSON file
      fullscreen   = '<leader>l', -- toggle dbout fullscreen
      hover_bind   = 'K',         -- hover the bind value under the cursor
    },
    panel = { select = '<CR>', edit = 'cw', close = 'q', toggle = '' },
    binds = { toggle = '' },
    jobs  = { open = '<CR>', cancel = 'x', close = 'q', toggle = '' },  -- background-jobs panel
    load  = { commit = '<CR>', cancel = 'q' },  -- CSV-load preview buffer
  },
})
```

</details>

<details>
<summary><b>Custom keybindings</b></summary>

dblite supports optional global keymaps for cross-cutting actions that should work from anywhere. They all default to `''` (disabled):

```lua
require('dblite').setup({
  keymaps = {
    global = {
      toggle_dbout = '<leader>o',
      toggle_jobs  = '<leader>j',
      toggle_binds = '<leader>b',
    },
  },
})
```

Editor keymaps remain **buffer-local** and are set only in the buffers listed in `filetypes` (default `sql`, `plsql`, `mysql`, `sqlite`), so they never fire in unrelated buffers or windows. Use them for SQL-buffer-only actions:

```lua
require('dblite').setup({
  keymaps = {
    editor = {
      run      = '<leader>r',   -- run the whole buffer
      run_at   = '<leader>rr',  -- run the statement under the cursor
      run_bulk = '<leader>rb',  -- background bulk export
      toggle_dbout = '<leader>o',
      toggle_jobs  = '<leader>j',
    },
  },
})
```

For anything more custom (conditional maps, visual-mode maps, extra behaviour), use the **`on_attach(bufnr)`** hook — the idiomatic replacement for manual `FileType`/`BufWinEnter` autocmds. It runs once per SQL buffer, after the built-in editor maps:

```lua
require('dblite').setup({
  on_attach = function(buf)
    local d, o = require('dblite'), { buffer = buf, silent = true }
    vim.keymap.set('n', '<leader>r',  d.execute,                    o)
    vim.keymap.set('n', '<leader>rr', d.execute_at_cursor,          o)
    vim.keymap.set('n', '<leader>rb', function() d.run_async() end, o)
    vim.keymap.set('n', '<leader>j',  d.toggle_jobs,                o)
  end,
})
```

Managing attachment yourself? `require('dblite').attach(bufnr)` applies the configured editor maps + runs `on_attach` for a buffer on demand.

**Public API** (all on `require('dblite')`):

| Function | Action |
|---|---|
| `execute()` | Run the whole buffer |
| `execute_at_cursor()` | Run the statement under the cursor |
| `execute_script()` | Run the buffer as a SQL\*Plus script |
| `run_async(format?, path?)` | Background bulk export (prompts if args omitted) |
| `toggle_dbout()` | Show/hide the result window |
| `toggle_panel()` / `open_panel()` / `close_panel()` / `is_panel_open()` | Connections panel |
| `toggle_jobs()` / `open_jobs()` / `close_jobs()` / `is_jobs_open()` | Background-jobs panel |
| `toggle_fullscreen()` | Toggle dbout fullscreen |
| `inspect(format?)` | Inspect the current page untruncated |
| `export(format, path?)` | Write the full result set to a file |
| `load()` | Load a CSV via a `LOAD DATA` control block |
| `edit_binds()` / `hover_bind()` | Bind-parameter helpers |
| `pick_connection()` / `get_active_conn()` | Connection helpers |
| `attach(bufnr)` | Apply editor maps + `on_attach` to a buffer |

</details>

Full reference is also available in `:help dblite`.

## License

[MIT](LICENSE) © 2026 Aaron Shahriari
