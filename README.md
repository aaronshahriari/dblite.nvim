<div align="center">

<img src="dblite_logo.svg" alt="dblite.nvim" width="400" />

# dblite.nvim

Query **Oracle**, **SQL Server**, **SQLite**, and **Redis** from Neovim — write SQL (or Redis commands) in any buffer, run it, and page results in a split.

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
- **Redis, Valkey and Dragonfly** over `redis://` and `rediss://` — replies land in the same grid (a hash becomes field/value, a sorted set member/score), so paging, export, history and watch all work unchanged. No `redis-cli` needed; the protocol is spoken directly, so values with newlines, spaces or binary survive intact.
- **Named connections** with `$ENV_VAR` password references, stored at `chmod 600`.
- **Typed bind parameters** from a `dblite.binds.json` file — numbers, quoted strings, and raw SQL expressions.
- **Export** the entire result set (not just the current page) to CSV or JSON.
- **Bulk background exports** — stream huge queries straight to a file asynchronously (no row cap), tracked in a jobs panel with live progress, while you keep working.
- **Watch a query** — re-run the statement under your cursor on an interval until something you're waiting for happens (a row lands, a count crosses a threshold, a column flips to `DONE`), then get notified. Every watch is visible and stoppable from one panel.
- **Load** a CSV into a table with a SQL\*Loader-style `LOAD DATA` block — previewed as `INSERT`s before you commit.
- **Inspect** any page untruncated as JSON, table, or CSV.
- **Inline queries from Lua** — `db.inline{ conn = 'prod', sql = ... }` runs headlessly and hands you the rows, so you can embed a query in a keymap, timer or autocommand without touching the UI.
- **SQL autocomplete** via [blink.cmp](https://github.com/Saghen/blink.cmp) — tables, columns, and bind names from the live schema. On Redis: command names, key namespaces one level at a time, and hash fields.
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

**URI formats** — port defaults to `1521` (Oracle) / `1433` (SQL Server) / `6379` (Redis) when omitted:

```
oracle://user[:password]@host[:port]/service
sqlserver://user[:password]@host[:port]/database
sqlite:///absolute/path.db
redis://[[user][:password]@]host[:port][/db]     # rediss:// for TLS
```

SQLite paths must point to an existing regular file. `:memory:` is unsupported because each command starts a new process and database connection. Run `:DbliteAddConn` without an argument to enter a URI interactively; leave that prompt blank for field-by-field setup (SQLite asks for type and database path). URI setup still prompts for a connection name.

SQL Server connections use `encrypt=true;trustServerCertificate=true` for broad compatibility with local dev and Azure SQL.

Redis needs only a host — auth is optional, and the database is an index (default `0`) rather than a name. Credentials travel in the environment rather than in the URL, so nothing has to be percent-encoded once saved; a password in a URI *is* percent-decoded when you paste it (`redis://:p%40ss@host` → `p@ss`). Both a bare password and an ACL `user:password` pair work. `rediss://` uses your system truststore, so a managed Redis with a public CA works with no extra setup.

## Running queries

| Command | Description |
|---|---|
| `:Dblite run` | Run the entire buffer |
| `:Dblite run at` | Run the statement under the cursor (treesitter-aware) |
| `:Dblite toggle dbout` | Show/hide the result window (query keeps running if in-flight) |
| `:DbliteSplit <dir>` | Move the result window: `right`, `left`, `below`, `above`, `tab` |
| `:DbliteOutput <mode>` | How results are drawn: `auto`, `grid`, `json`, `text` |
| `:Dblite inspect [json\|table\|csv]` | Open the current page untruncated in a scratch window |
| `:Dblite export <csv\|json> [path]` | Write the **entire** result set to a file |
| `:Dblite run bulk <csv\|json> [path]` | Run the current query **in the background**, streaming the full result straight to a file |
| `:Dblite watch [spec]` | Re-run the statement at the cursor on an interval until a condition matches |
| `:Dblite watch file [spec]` | Same, but watch the whole buffer |
| `:Dblite watch stop` | Stop every running watch |
| `:Dblite jobs` | Toggle the activity panel (watches + background exports) |
| `:Dblite load` | Load a CSV into a table from a `LOAD DATA` control block (preview, then commit) |

Trailing semicolons are stripped automatically. The legacy `:DbliteRun`, `:DbliteRunAt`, and `:DbliteToggleOut` commands remain as aliases. Running from a different tab moves the dbout split to that tab.

**dbout keymaps:**

| Key | Action | Key | Action |
|---|---|---|---|
| `L` / `H` | Next / previous page | `[` / `]` | Previous / next result in history |
| `K` | Hover the query that produced this result | `d` | Toggle column type annotations |
| `gi` | Inspect current page (untruncated) | `<leader>l` | Toggle dbout fullscreen |
| `go` | Cycle rendering: auto / grid / json / text | `<C-c>` | Cancel in-flight query |

`<C-c>` also cancels from any buffer while a query runs — dblite sets it globally for the duration and restores your mapping afterward.

## More

<details>
<summary><b>Redis, Valkey & Dragonfly</b></summary>

Pick a Redis connection and the buffer becomes a Redis command buffer — same keys, same result grid, same everything above it.

**One command per line.** Keep a scratch buffer of the commands you use, put the cursor on one, and run it. `*.redis` files get dblite's editor keymaps automatically; so does any `.sql` buffer, since routing is by **connection**, not filetype:

```redis
KEYS *
KEYS user:*
KEYS session:a83f-2291
HGETALL user:1042
ZRANGE leaderboard 0 -1 WITHSCORES
INFO replication
```

| | |
|---|---|
| `:Dblite run at` | run **the line under the cursor** |
| `:Dblite run` | run **every** line, in order, with a per-statement OK/ERROR log |
| `:'<,'>Dblite run bulk csv` | export the selected lines to a file in the background |

Redis has no statement terminator, so a line is a statement — no blank lines needed between commands, and `run at` never picks up the line below. That scratch buffer replaces the filter box, and unlike a filter box it is a file you can keep and commit.

**Finding keys.** `KEYS <pattern>` is served by a full `SCAN` cursor loop rather than the real (server-blocking) `KEYS` command, so it is safe to run anywhere. Results are de-duplicated, since `SCAN` may hand back the same key more than once:

```
key                | type   | ttl | size
-------------------+--------+-----+-----
user:1042          | hash   |     | 7
session:a83f-2291  | string | 900 | 1204
queue:jobs         | list   |     | 4
```

`ttl` is remaining seconds, blank when the key has no expiry. `size` is bytes for a string and element count for everything else — the number you want when hunting for outliers.

A pattern with no glob metacharacters (`*`, `?`, `[`) is a key *name*, so it skips `SCAN` entirely and resolves in one round trip. Pasting a full key like `KEYS session:a83f-2291` is O(1), not a keyspace walk.

Use `SCAN` itself if you want the raw cursor semantics; it is passed through untouched.

**How replies land in the grid:**

| Reply | Columns |
|---|---|
| `HGETALL`, `CONFIG GET`, any RESP3 map | `field` · `value` |
| `ZRANGE … WITHSCORES`, `ZPOPMIN`/`ZPOPMAX` | `member` · `score` (a real number) |
| `LRANGE`, `SMEMBERS`, any array | `index` · `value` |
| `INFO` | `section` · `field` · `value` |
| `GET`, `TTL`, anything scalar | `result` |
| `KEYS` | `key` · `type` · `ttl` · `size` |

Nested replies (`XRANGE`, `CLUSTER SLOTS`) keep their shape as JSON inside the cell, ready for `gi`.

**JSON.** A value that is a JSON document is tagged `json` in the column types — press `d` to see the tag. A reply that is *nothing but* one such value skips the grid entirely and is pretty-printed into dbout, so `JSON.GET` and a `GET` of a serialized payload both arrive readable rather than truncated into a cell. The inspect view (`gi`) decodes JSON-inside-a-string recursively, so nested payloads unwrap into real structure rather than a wall of escapes.

A value holding **JSONL** expands to one row per record, so paging and export operate on records instead of one giant cell:

```
line | value
-----+------------------
0    | {"id":1,"k":"a"}
1    | {"id":2,"k":"b"}
```

**Watching.** `SCAN` gives no consistency guarantee — a key added or removed mid-scan may or may not appear — which is why a manual refresh is a real habit and not paranoia. `:Dblite watch` automates it:

```vim
:Dblite watch every=5s        " on LLEN queue:jobs — live queue depth
:Dblite watch every=30s       " on INFO replication — replication lag, diffed
```

**Scripts.** In script mode (`:Dblite run script`) one command per line, `#` comments ignored — so a purge or cache-warm routine can live in a file you commit.

**Writing** is done by writing the command, the same way you would write an `UPDATE` rather than editing a result cell:

```redis
HSET user:1042 email new@example.com
EXPIRE session:a83f 3600
DEL session:expired:a83f
```

Because the protocol is length-prefixed, values containing newlines, spaces, commas or quotes round-trip exactly. Quote them as you would in `redis-cli` — `"a\nb"` for an escape, `'{"a": 1}'` for a JSON literal.

**Performance.** A key listing's cost is round trips, not bytes. `SCAN`'s cursor is sequential and cannot be pipelined, so a listing costs roughly `keyspace_size / scan_count` blocking round trips, each paying full network latency. `MATCH` does **not** help — Redis examines every key and filters afterwards.

Measured against a synthetic keyspace (`RedisScanPerfTest` prints these):

| keyspace | matched | SCAN round trips | commands |
|---|---|---|---|
| 10,000 | 100 | 1 | 301 |
| 100,000 | 500 | 10 | 1,510 |
| 1,000,000 | 2,000 | 100 | 6,100 |
| 1,000,000 | 200,000 (capped 10k) | 5 | 30,005 |
| 1,000,000 | 200,000, `key_details = false` | 100 | **100** |

Three knobs, in the order worth reaching for:

```lua
redis = {
  scan_count  = 10000,  -- keys examined per SCAN iteration
  key_details = true,   -- false = key names only, no type/ttl/size
},
max_rows = 10000,       -- caps a dense match early
```

- **`scan_count`** is the big lever. At the old default of 500, a million-key keyspace was 2,000 round trips — 10s at 5ms RTT, 30s at 15ms. Raise it further on a large or remote keyspace; the tradeoff is a longer single-`SCAN` stall on the (single-threaded) server.
- **`key_details = false`** drops `type`/`ttl`/`size`, which are one command *each per key* — 30,000 commands for a 10,000-key listing. Set it false if you mostly want to know which keys exist.
- **`max_rows`** ends a dense match early: a prefix matching 200,000 keys stops after 5 `SCAN`s instead of walking the whole keyspace.

To see which regime you're in:

```redis
DBSIZE
INFO server
```

`DBSIZE` is your keyspace size — divide by `scan_count` for the round-trip count. If `redis_version` is 8 or newer, the server also optimizes glob patterns internally, so prefix scans are cheaper before any of this applies.

**The inherent limit:** a sparse prefix in a huge keyspace is `O(keyspace)` no matter how it's tuned. If you control the writes, maintaining a `SET` of keys per namespace turns the lookup into an `O(1)` `SMEMBERS` — that's the only way to actually beat a scan. An exact key name already skips `SCAN` entirely.

**Completion.** There is no Redis language server, so dblite builds completion from the live instance via [blink.cmp](https://github.com/Saghen/blink.cmp):

| where the cursor is | what you get |
|---|---|
| start of a line | the server's own command list, with arity and flags (so modules like `JSON.GET` show up too) |
| argument position | key namespaces **one level at a time** — `user:` → `user:sessions:` → the keys |
| after a hash key | that key's field names (`HGET user:1042 <tab>`) |

Progressive namespaces are what make this usable on a real keyspace: you never get a 40,000-item list, just the handful of prefixes at your current depth. Cached per connection, refreshed when you switch or edit the connection.

```lua
redis = { completion = { enabled = true, max_keys = 5000 } }
```

`max_keys` caps how many keys are pulled in for completion (`0` = no cap). Note it's a `SCAN`, so it costs a keyspace walk on first use — lower it on a huge instance, or set `enabled = false`.

**The `.redis` filetype.** Neovim ships none, so dblite provides it: `#` comments (not SQL's `--`), highlighting that separates the command from its flags, keys, quoted arguments and JSONPath expressions, and an `iskeyword` that treats `JSON.GET` and `user:1042:profile` as single words — so `w`, `*` and `yiw` stop where you'd expect. Only recognised flags highlight, which makes a typo visible. If `nvim-web-devicons` is installed, dblite also registers its Redis icon for the extension and filetype without replacing a user override.

**Not supported yet:** `redis+cluster://` and `redis+sentinel://`. Bind parameters are a SQL feature and are switched off for Redis — otherwise every colon-namespaced key (`queue:jobs`) would read as a missing `:jobs` parameter. `:Dblite load` is SQL-only.

</details>

<details>
<summary><b>How results are drawn</b></summary>

A grid is right for a tabular reply and wrong for a single document. `JSON.GET` returns one value; as a one-cell table truncated at `max_col_width` you see almost none of it. So dbout picks a renderer per result:

```
JSON.GET user:1042:profile $
```
```jsonc
// ◀ 3/7 ▶  (json, 9 lines)  —  0.012s  ·  cache

{
  "id": 1042,
  "email": "…",
  "flags": [
    "beta",
    "staff"
  ]
}
```

With the default `output.mode = 'auto'`, a reply that is one row and one column typed `json` renders as JSON, a lone multi-line value renders as raw text, and everything else stays a grid. The backend tags a column `json` only when every value in it is a document, so the tag is worth switching renderers on.

Pin commands where detection isn't what you want — keys match the first word, case-insensitively:

```lua
output = {
  commands = {
    ['JSON.GET'] = 'json',
    GET          = 'text',   -- a blob you'd rather see raw
    INFO         = 'grid',
  },
}
```

`:DbliteOutput json|text|grid|auto` switches the result on screen and keeps using that renderer for the ones that follow, so a second `JSON.GET` doesn't snap back to a grid; `auto` hands the choice back to detection. `go` inside dbout cycles through all four. Inspect and export are unaffected — both work from the raw reply.

</details>

<details>
<summary><b>Where the result window opens</b></summary>

`split_dir` sets the default placement; `:DbliteSplit` changes it live:

```vim
:DbliteSplit right     " beside the editor — good for long JSON values
:DbliteSplit below     " under the editor — good for wide grids
:DbliteSplit left | above | tab
:DbliteSplit           " report the current placement
```

`right`/`left`/`below`/`above` are the unambiguous names; the older `vertical` (= right) and `horizontal` (= below) still work.

If dbout is open it moves immediately and re-renders at the new width; otherwise the placement applies next time it opens. Either way it is **remembered** — for the next toggle and the next session, along with any size you dragged it to. `:Dblite split right` is the same command, and `cycle_split` (unmapped by default) flips between right and below:

```lua
keymaps = { editor = { cycle_split = '<leader>ds' } }
```

The placement is remembered **per connection type**, so moving dbout on a Redis connection doesn't move it for your Oracle ones.

</details>

<details>
<summary><b>Per-connection-type settings</b></summary>

Redis and a SQL database want different windows often enough that one global setting can't serve both — a single document reads well in a tall right-hand pane, a result grid in a short wide one. `types` overrides the top-level defaults for whichever connection is active:

```lua
require('dblite').setup({
  split_dir = 'below',              -- what SQL connections get
  types = {
    redis = {
      split_dir  = 'right',
      split_size = { width = 90 },
      output     = { commands = { ['JSON.GET'] = 'json' } },
    },
  },
})
```

Overridable: `split_dir`, `split_size`, `filetype`, `page_size`, `max_col_width`, `show_column_types`, `output`. Anything absent falls through to the top-level default, and `output` is merged rather than replaced, so a type block can pin one command without restating the table. Type names are the connection types: `oracle`, `sqlserver`, `sqlite`, `redis`.

</details>

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

Jobs run in the background, so you can keep running normal queries meanwhile. `:Dblite jobs` (or `:DbliteJobs`) toggles the **activity panel**, which tracks exports alongside your watches — see *The activity panel* above for its layout and keymaps. Deleting a finished entry (`x`) prompts first, then removes it from the store; cancelling a running job also prompts first.

There is **no client-side query timeout**, so a bulk export runs until the database returns — fine for multi-minute queries. Bind parameters are resolved the same way as normal queries.

> **Note:** bulk export needs a native binary that includes `--to-file` support. If you installed a pre-built release binary, force a source rebuild with `:DbliteBuild!` (or `:Dblite build force`) to pick it up — plain `:DbliteBuild` downloads the latest *release*, which may not include it yet.

</details>

<details>
<summary><b>Watching a query</b></summary>

Some queries you don't run once — you run them over and over waiting for something to land. `:Dblite watch` (or `:DbliteWatch`) polls the statement under the cursor on an interval and tells you when it happens, so you can go do something else.

With no arguments it opens a small popup where the four settings are plain text you edit with normal motions:

```
  watch · orders.sql:12

  select id, status, created
    from orders
   where created > sysdate - 1

  every   30s
  until   changed
  max     50
  errors  3

  <CR> start · q cancel
```

Or skip the popup by passing a spec:

```
:DbliteWatch 30s x50                      " every 30s, at most 50 ticks
:DbliteWatch every=2m until=rows>5        " until more than 5 rows come back
:DbliteWatch 1m for=1h until=STATUS=DONE  " every minute for an hour
:'<,'>DbliteWatch 10s                     " watch just the selected statement(s)
:DbliteWatchFile 30s                      " watch the whole buffer
```

`for=` is sugar — it divides by the interval to get a tick cap. `x50` and `max=50` are the same thing; `max=0` means no cap.

**Conditions** — the thing you're waiting for lives in the watch, not in the SQL, so you don't have to rewrite the query to poll it:

| `until=` | Matches when |
|---|---|
| `changed` *(default)* | The result differs from the first tick |
| `rows>5` | Row count comparison — `>` `>=` `<` `<=` `=` `!=` |
| `STATUS=DONE` | Any row whose `STATUS` column equals `DONE` |
| `NAME~aaron` | Any row whose `NAME` column contains `aaron` (case-insensitive) |
| `STATUS!=PENDING` | Any row whose `STATUS` column is not `PENDING` |
| `never` | Nothing — just run to the tick cap |

Column names are matched case-insensitively (handy when your database hands back `UPPERCASE` labels); values are matched exactly. If the column doesn't exist in the result, you get one warning rather than a watch that silently never fires.

A watch stops on the first match, at its tick cap, after `errors` consecutive failures, or when you stop it by hand — and `vim.notify`s either way, naming what matched:

```
dblite: watch matched — orders.sql:12 · STATUS=DONE (row 3)
```

**How it behaves:** ticks are *chained*, not intervalled — the next run is scheduled when the previous one finishes, so a query that outlives its interval delays the next tick instead of stacking up. The connection and the bind values are frozen when the watch starts, so switching connections or editing `dblite.binds.json` mid-flight never changes what's being polled. Each tick spawns a fresh process, so nothing is held open between ticks. Watches are session-local and never persisted — quitting warns you if any are still running.

`watch.max_active` (default 5) caps how many can run at once, so you can't quietly accumulate a dozen pollers you've forgotten about.

</details>

<details>
<summary><b>The activity panel</b></summary>

`:Dblite jobs` (or `:DbliteJobs`) toggles a right-side panel showing everything dblite has in flight — watches first, then running background exports, with finished exports folded behind one line:

```
  dblite

  ◐ orders.sql:12      7/50 · 6 rows · 24s
  ◐ queue_depth.sql:4   3/∞ · 112 rows · run
  ⋯ big_dump.csv          running · ? rows

  ▸ History (18)
```

A watch line reads *tick / cap · rows · time until the next tick* (or `run` while a tick is in flight). The panel redraws once a second while anything is live, so the countdown stays honest.

| Key | Action |
|---|---|
| `<CR>` | **Job:** open its output file in a new tab · **Watch:** show its latest result in dbout · **History:** fold/unfold |
| `K` | Details of the entry under the cursor — a watch includes its full per-tick log |
| `x` | Stop a running watch/job, or remove a finished one |
| `r` | Re-point a job at a moved/renamed output file (persists the new path) |
| `<Tab>` | Fold/unfold the finished-exports History section |
| `q` | Close the panel |

Pressing `<CR>` on a watch pushes its latest snapshot into the normal result window, so paging, `gi` inspect, export and `[` / `]` history navigation all work on it unchanged.

**Persistent export history:** finished *exports* are recorded to a shared store (`stdpath('data')/dblite/jobs.json` by default), so the History section survives restarts and is shared across every Neovim instance on the machine. Control it via `jobs.history`: `show`, `max_entries`, `start_open` (expand the fold by default), or `enabled = false` for in-memory only. Watches are never written there — they're session-local by design.

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
db.watch(spec, range)      -- watch the statement at the cursor ('30s x50 until=rows>5')
db.watch_file(spec)        -- watch the whole buffer
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
| `sql` | — | statement to run — a Redis command on a Redis connection (required) |
| `conn` | — | name of a saved connection (required) |
| `binds` | `{}` | values for `:name` references (SQL only; ignored for Redis) |
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
db.set_split_dir(dir)      -- move dbout: 'right'|'left'|'below'|'above'|'tab'
db.cycle_split()           -- flip dbout between right and below
db.set_output_mode(mode)   -- draw results as 'auto'|'grid'|'json'|'text'
db.cycle_output()          -- cycle dbout through all four renderers
```

</details>

## Configuration

`setup()` takes no options if you're happy with the defaults. Common ones:

```lua
require('dblite').setup({
  split_dir         = 'horizontal', -- 'right' | 'left' | 'below' | 'above' | 'tab'
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
  split_dir      = 'horizontal',  -- 'right' | 'left' | 'below' | 'above' | 'tab'
                                  -- ('vertical' = right, 'horizontal' = below)
                                  -- change live with :DbliteSplit; it is remembered
  split_size     = { width = 80, height = 20 },  -- defaults; a size you drag to is remembered
  page_size      = 100,           -- rows per page in the result buffer
  max_rows       = 10000,         -- hard cap on rows returned
  max_col_width  = 50,            -- truncate cells wider than this; 0 = no limit
  max_history    = 20,            -- past query results to keep; 0 = unlimited
  show_column_types = false,      -- show [TYPE] next to column headers by default
  filetypes      = { 'sql', 'plsql', 'mysql', 'sqlite', 'redis' }, -- buffers dblite attaches to (editor keymaps + on_attach)
  redis          = {
    scan_count   = 10000,  -- keys examined per SCAN iteration (main perf lever)
    key_details  = true,   -- false = key listings return names only, no type/ttl/size
    completion   = { enabled = true, max_keys = 5000 }, -- command/key/field completion
  },
  on_attach      = nil,           -- function(bufnr) run per SQL buffer for custom buffer-local keybinds
  filetype       = '',            -- filetype for the result buffer ('' = no highlighting)
  output = {                      -- how results are drawn
    mode          = 'auto',       -- 'auto' | 'grid' | 'json' | 'text'
    json_indent   = 2,            -- spaces per level in the json view
    json_filetype = 'jsonc',      -- filetype for the json view
    commands      = {},           -- per-command pins, e.g. { ['JSON.GET'] = 'json' }
  },
  types          = {},            -- per-connection-type overrides, e.g.
                                  --   { redis = { split_dir = 'right' } }
  flash_timeout  = 2000,          -- ms to hold the query highlight; 0 = hold until results
  json_view      = 'tab',         -- where inspect opens: 'tab' | 'vertical' | 'horizontal' | 'float'
  load_view      = 'tab',         -- where the CSV-load preview opens: 'tab' | 'vertical' | 'horizontal' | 'float'
  inspect_format = 'json',        -- default inspect format: 'json' | 'table' | 'csv'
  inspect_expand_json = true,     -- json inspect: decode cell values that are themselves JSON strings
  panel = {
    width = 30,                   -- side panel width in columns
  },
  jobs = {                        -- the activity panel: exports (:Dblite run bulk) + watches
    panel = { width = 44 },       -- activity-panel width in columns
    cleanup_delay  = 300,         -- seconds a finished job lingers in the live list; 0 = keep until dismissed
    default_format = 'csv',       -- default bulk format: 'csv' | 'json'
    open_on_start  = true,        -- auto-open the jobs panel when a bulk export starts
    focus          = true,        -- move the cursor into the panel when you toggle it open
    history = {                   -- persistent job history, shared across all Neovim instances
      enabled     = true,         -- record finished jobs to disk (false = in-memory only)
      show        = 20,           -- how many past jobs to display in the panel (0 = all kept)
      start_open  = false,        -- expand the folded History section when the panel opens
      max_entries = 200,          -- hard cap on stored jobs; oldest dropped past this
      -- file = stdpath('data')..'/dblite/jobs.json'  -- override the store location
    },
  },
  watch = {                       -- repeating queries (:Dblite watch)
    default_interval  = '30s',    -- time between ticks when none is given
    default_max       = 50,       -- tick cap when none is given; 0 = unlimited
    default_condition = 'changed',-- what to wait for by default
    max_active        = 5,        -- refuse to start more than this many at once (0 = no cap)
    stop_after_errors = 3,        -- consecutive failed ticks before giving up (0 = never)
    notify            = true,     -- notify when a watch matches, fails, or runs out
    cleanup_delay     = 0,        -- seconds a finished watch lingers in the panel; 0 = until dismissed
    log_size          = 100,      -- per-watch tick log entries kept for the hover view
    prompt            = true,     -- :DbliteWatch with no args opens the popup; false = use defaults
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
      watch         = '',          -- watch the statement under the cursor
      watch_file    = '',          -- watch the whole buffer
      toggle_dbout  = '',          -- show/hide the result window
      toggle_panel  = '',          -- toggle the connections panel
      toggle_jobs   = '',          -- toggle the activity panel
      toggle_binds  = '',          -- toggle dblite.binds.json
      inspect       = '',          -- inspect current page untruncated
      fullscreen    = '',          -- toggle dbout fullscreen
      connections   = '',          -- open the connections JSON file
    },
    dbout = {
      next = 'L', prev = 'H', cancel = '<C-c>', inspect = 'gi',
      history_prev = '[', history_next = ']', hover_query = 'K', toggle_types = 'd',
      cycle_output = 'go', toggle_dbout = '',
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
      cycle_split  = '',          -- flip dbout between right and below
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

Editor keymaps remain **buffer-local** and are set only in the buffers listed in `filetypes` (default `sql`, `plsql`, `mysql`, `sqlite`, `redis`), so they never fire in unrelated buffers or windows. Use them for SQL-buffer-only actions:

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
