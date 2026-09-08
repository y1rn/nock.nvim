# nock.nvim

VSCode `Cmd+P` style popup selector for Neovim — `Input + Filtered List + Action + Preview` in a single native floating window.

> **Zero external dependencies.** Pure `nvim_open_win` / `nvim_create_buf` / extmarks. No `nui.nvim`, no compiled binaries. The core ships only `files`; everything else is an opt-in `Preset`.

---

## Installation

`lazy.nvim`:

```lua
{
  "your-username/nock.nvim",
  config = function()
    require("nock").setup({
      -- all fields optional; shown with defaults
      maxheight = 10,
      width = 0.3,       -- 0..1 = ratio of columns, clamped [40,80]; >1 = fixed cols
      row = 0,           -- 0 = pinned top; 0..1 = ratio of lines; >=1 = fixed row
      matcher = "auto",  -- "auto" | "vim.fn" | "native" | fun(query, items, recency) -> results
      show_on_open = true,
      hijack_ui_select = true,  -- vim.ui.select -> nock.pick
      hijack_lsp_goto = true,   -- vim.lsp.buf.definition etc -> nock.lsp.*
      lsp = {
        timeout = 1000,          -- ms for buf_request_sync fallback
        auto_jump_single = true, -- N==1 auto-jump without picker
        preview = true,          -- preview for goto selector
      },
    })
  end,
}
```

No `dependencies` field required.

---

## Quickstart

```lua
require("nock").setup()

-- <C-p> opens files (the only built-in Mode, prefix = "")
-- Type to fuzzy-filter, <Up>/<Down> wrap, <CR> confirm, <Esc> cancel
-- Click to select, double-click to confirm, <C-u> two-stage line clear
```

- Empty query: **Initial Display** — `files.show` (default `false`) + `modes.files.show` (default `true`, overrides) controls it. `false` → MRU open buffers only; `true` → `MRU buffers ++ project files` deduped (MRU first, `fd` → `git ls-files` → `vim.fs.find` order, respects `files.ignore` + `files.gitignore` merged `.gitignore`).
- Typed query (trimmed both ends, `%s` only): searches **Project Files Snapshot** (per-`cwd` cache, invalidated on `Shell.open("files")` and on `BufWritePost`/`BufNewFile`/`BufDelete`/`BufAdd`/`DirChanged` debounced 150ms; opt-in `files.watch` via `vim.uv.new_fs_event`). `U+3000` is not trimmed.
- In-popup prefix: deleting the prefix char or `<C-u>` second stage returns to fallback `files`.
- Height is `1` when `0` matches, otherwise `2 + min(#filtered, maxheight)` live (1 Input + 1 separator + List). `0` matches collapses to Input-only.

---

## Built-in vs Presets

| Kind | Mode | Prefix | Default keymap | What it does |
|------|------|--------|----------------|--------------|
| **Built-in** | `files` | `""` (fallback) | `<C-p>` | MRU buffers → project files, `fd`/`gitignore` aware, snapshot-cached |
| **Preset** (opt-in) | via `nock.presets.*()` | you choose | you choose | see below |

The core has **only `files`**. All other modes are constructed with `nock.presets` and registered through `setup({ modes = { ... } })`. There is no hidden `commands` mode — it is just another preset.

### Presets — one line to enable

Presets are under `require("nock.presets")`. Each call returns a full `Mode` spec you can drop into `setup.modes`.

```lua
local presets = require("nock.presets")

require("nock").setup({
  modes = {
    files = { keymap = "<C-p>" }, -- keep default

    -- 1) Ex commands (":Foo" style, `:` stripped before :cmd)
    --    prefix = ">"  — type ">" then filter command names
    my_commands = presets.commands({
      prefix = ">",
      keymap = "<C-S-p>",
    }),

    -- 2) LSP document symbols — current buffer outline
    --    Fans out to all clients via client:request (async, callback),
    --    falls back to buf_request_sync 1000ms when no callback.
    --    Flattens nested children. Each Item: [Function] name, kind, detail, location
    --    Binds vim.lsp.buf.document_symbol -> nock.open(mode) via _lsp_target (prefix hijack)
    doc_symbols = presets.lsp_document_symbols({
      prefix = "@",
      keymap = "<leader>ss",
      -- timeout = 1000, preview = true,
    }),

    -- 3) LSP workspace symbols — async, query-dependent
    --    Empty query returns []; non-empty fans out workspace/symbol to all clients.
    --    incremental = false. Stale callbacks dropped via ctx.is_cancelled().
    workspace_symbols = presets.lsp_workspace_symbols({
      prefix = "#",
      keymap = "<leader>sw",
      -- show_on_open = false (default), preview = true
    }),

    -- 4) Diagnostics — current buffer by default, or workspace
    --    Uses vim.diagnostic.get(). Each Item: [Error] msg, detail "path:lnum:col"
    --    WARN/HINT are filtered out (only Error/Info shown)
    diagnostics = presets.diagnostics({
      prefix = "!",
      keymap = "<leader>sd",
      -- workspace = false, -- true = all buffers
    }),
    workspace_diagnostics = presets.diagnostics({
      prefix = "?",
      keymap = "<leader>sD",
      workspace = true,
    }),

    -- 5) Go to line — current buffer lines
    --    Shows "  12:   foo()" with kind = "Line", jumps with set_cursor
    lines = presets.lines({
      prefix = ":",
      keymap = "<leader>sl",
    }),
  },
})
```

**Prefix resolution**: each non-empty `prefix` must be exactly one ASCII punctuation character (`!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`); letters, digits, whitespace and multibyte characters are rejected. No two Modes share the same non-empty `prefix`, and at most one provider-eligible `prefix = ""` fallback exists (`files`). No match → fallback to `prefix = ""` (`files`). Deleting the prefix character inside the popup instantly returns to `files`. Violations fail fast in `setup()` / `register_mode()` with `error()`.

---

## Custom Mode — simple, flexible, unified

A `Mode` is just `{ prefix, keymap, provider, action, preview }`.

```lua
-- Minimal example: recent git branches
require("nock").register_mode("branches", {
  prefix = "$",
  keymap = "<leader>sb",
  preview = false, -- no location jump

  -- provider(query, ctx, callback) -> nil[, cancel_fn] (async-only)
  provider = function(query, ctx, callback)
    -- ctx = { win = origin_win, buf = origin_buf, file = origin_file,
    --         is_cancelled = function() -> bool }
    -- query is the effective query (prefix stripped + trimmed)
    -- Always callback, never return items. May return a cancel_fn killing the job.
    local job = vim.system({ "git", "branch", "--format=%(refname:short)" }, { text = true }, function(obj)
      vim.schedule(function()
        if ctx.is_cancelled and ctx.is_cancelled() then return end
        local items = {}
        for _, b in ipairs(vim.split(obj.stdout or "", "\n")) do
          if b ~= "" then
            table.insert(items, {
              label = b,
              -- filter_text = b, -- optional: search text if different from label
              -- kind = "Branch",  -- optional: renders as "[Branch] main" or icon
              -- detail = "branch", -- right-side dimmed text
              -- location = { path = "file", lnum = 1, col = 0 }, -- enables preview
              value = b,
            })
          end
        end
        callback(items)
      end)
    end)
    return nil, function() job:kill("TERM") end
  end,
  -- action(item, ctx) — called on <CR> / double-click
  action = function(item, ctx)
    vim.cmd("!git checkout " .. vim.fn.shellescape(item.value))
  end,
})
```

### Item shape

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `label` | `string` | yes | Display + default search text. With `kind`, rendered as icon + label or `"[Kind] label"` |
| `filter_text` | `string` | no | Matcher uses this instead of `label` when present |
| `kind` | `string` | no | `"Function"`, `"Class"`, `"Error"`, `"Warn"`… prefix via icon or `[Kind]` |
| `detail` | `string` | no | Secondary dimmed text (e.g. file path, diagnostic source) |
| `location` | `{path, lnum, col, end_lnum, end_col}` | no | Enables live **Preview** (transient jump) and default `actions.edit` |
| `value` | `any` | no | Payload for `action` |
| `bufnr` | `number` | no | Buffer handle when applicable |

### Provider contract

```lua
---@param query string        -- effective query, prefix stripped + trimmed; "" = initial display
---@param ctx table           -- { win, buf, file, is_cancelled: ()->bool }
---@param callback function?  -- async: callback(items) when ready, return nil
---@return table|nil          -- sync: Item[]
function provider(query, ctx, callback) end
```

- `query == ""` → return initial list (e.g. MRU, diagnostics) when `show_on_open ~= false`.
- Non-empty → return filtered source; matcher does fuzzy scoring (`filter_text` → `label`).
- `ctx.is_cancelled()` + generation token: Shell drops stale async results automatically.

### Actions & Utils

```lua
local actions = require("nock.actions")
local utils   = require("nock.utils")

-- Standard actions
actions.edit(item, ctx)       -- open buf/file at location, set cursor (MRU-aware, win_call)
actions.cmd(item, ctx)        -- vim.cmd(value or label without leading ":")
actions.set_cursor(item, ctx) -- jump cursor in origin win (for :lines)

-- Converters
utils.lsp_symbol_kind_name(12)               -- 12 -> "Function"
utils.lsp_symbol_to_item(sym, opts)          -- LSP Symbol -> Item { kind, location }
utils.lsp_location_to_item(loc, opts)        -- LSP Location/LocationLink -> Item { kind="Definition", location }
utils.lsp_locations_to_items(input, opts)    -- Location[] | buf_request_sync map -> Item[] (deduped by path:lnum:col)
utils.format_diagnostic(diag, opts)          -- vim.diagnostic -> Item { kind="Error"/"Warn", detail="path:lnum:col" }
```

### Two ways — persistent Mode vs Selector (vim.ui.select)

nock has two usage patterns. Pick the right one:

|  | **Way 1 — Persistent Mode** | **Way 2 — Selector** |
|---|---|---|
| When | **Searchable large list**: results depend on what you type, many candidates | **One-shot small list via `vim.ui.select`**: results already known, `N` is small (2–20), determined by cursor position |
| Examples | `files`, `:lines`, LSP `document/workspace_symbols`, `diagnostics`, `commands` | `textDocument/definition` (`gd`), `implementation` (`gi`), `references` (`gr`), `typeDefinition`, `code_action` — plus any plugin that calls `vim.ui.select` |
| Source | `provider(query, ctx, cb) -> nil[, cancel_fn]` — generated dynamically per `query`, delivered via `cb(items)` | `items: any[]` already computed: `utils.lsp_locations_to_items(res, …)` or any `string|table` list passed to `vim.ui.select` |
| How to open | `prefix` (e.g. `@`/`#`/`>`) + `keymap` + `nock.open("mode")`; Input shows `prefix + query` | `vim.ui.select(items, opts, on_choice)` — hijacked to `nock.pick`; or direct `nock.pick(items, opts, on_choice)`; **no prefix**, Input starts empty, typing only filters the same `items` |
| Occupies `prefix` table | Yes — single ASCII punctuation, global prefix resolution | **No** |
| What Input shows | `>foo` / `@MyClass` — prefix participates in `filter.resolve` | Empty + `opts.prompt` as placeholder; when `N>1` the list shows all `N` immediately |

> **Why `gd`/`gi` do not fit Way 1:** Using `setup({ modes = { lsp_definitions = { prefix="gd", provider=function(_, _, cb) cb(cache); return nil end }}})` + `nock.open("lsp_definitions")` requires a global `prefix="gd"`, a mutable `defs_cache`, and a fake-persistent `provider` — the whole `Input→resolve→provider→matcher` chain runs for a one-shot result. Way 2 just calls `pick`/`vim.ui.select` with no `prefix` and no `cache`. Note: `prefix="gd"` is also invalid (multi-char + letters rejected with `error()`).

`setup()` hijacks `vim.ui.select` by default (`hijack_ui_select = true`). Opt out with `setup({ hijack_ui_select = false })` and restore via `require("nock").restore_ui_select()`. Original is saved as `nock._orig_ui_select`.

`setup()` also hijacks `vim.lsp.buf.definition` / `declaration` / `typeDefinition` / `implementation` / `references` by default (`hijack_lsp_goto = true`) to `nock.lsp.*` (Selector path, `N==0` notifies, `N==1` auto-jumps, `N>1` picker). Opt out with `setup({ hijack_lsp_goto = false })`, restore via `require("nock").restore_lsp()` or `require("nock").restore()`. Independently, any Mode with `_lsp_target` (`presets.lsp_document_symbols` → `document_symbol`, `presets.lsp_workspace_symbols` → `workspace_symbol`) binds `vim.lsp.buf.document_symbol` / `workspace_symbol` to `nock.open(mode)`.

#### Recipe: `gd` / `gi` — via `nock.lsp` / `vim.ui.select` (Way 2, recommended)

Zero-config after `setup()` (default `hijack_lsp_goto = true`): `gd`, `gD`, `gi`, `gr`, `gy` already route to `nock.lsp.*` — no keymap needed. For manual wiring or custom methods:

```lua
local utils = require("nock.utils")

-- Option A: hijacked vim.lsp.buf.* is already nock.lsp.* — just set keymaps
vim.keymap.set("n", "gd", vim.lsp.buf.definition)
vim.keymap.set("n", "gi", vim.lsp.buf.implementation)
-- gr / typeDefinition / declaration likewise

-- Option B: call nock.lsp directly (explicit, works even with hijack_lsp_goto=false)
vim.keymap.set("n", "gd", function() require("nock.lsp").definition() end)
vim.keymap.set("n", "gr", function() require("nock.lsp").references() end)

-- Option C: generic vim.ui.select path (any items) — N==0→on_choice(nil), N==1 auto-jump, N>1 picker
-- preview auto-enables only if any item has location
vim.keymap.set("n", "gd", function()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients == 0 then return vim.notify("No LSP client attached", vim.log.levels.WARN) end
  local enc = clients[1].offset_encoding or "utf-16"
  local params = vim.lsp.util.make_position_params(win, enc)
  local res = vim.lsp.buf_request_sync(buf, "textDocument/definition", params, 1000)
  local items = utils.lsp_locations_to_items(res, { bufnr = buf, win = win })
  vim.ui.select(items, { prompt = "Definitions:", kind = "nock-lsp" }, function(item)
    if not item then return end
    require("nock.actions").edit(item, { win = win, buf = buf })
  end)
end)

-- Option D: any textDocument/* method via generic helper
vim.keymap.set("n", "<leader>cr", function()
  local params = vim.lsp.util.make_position_params(0, "utf-16")
  require("nock.lsp").pick_for_method("textDocument/references", params, { prompt = "References:" })
end)
```

`utils.lsp_locations_to_items` handles `Location` vs `LocationLink` (`targetUri/targetRange/targetSelectionRange`), `utf-16` → byte `col` via `vim.str_byteindex`, and `path:lnum:col` dedup. **Do not** `register_mode` for `gd` or occupy `prefix="gd"` — that is the Way 1 anti-pattern. For generic `vim.ui.select` callers, `nock.pick` auto-coerces `string|table` via `opts.format_item` → `label`, `opts.kind` → `kind`, and keeps original `value` for `on_choice`.

#### When to stay on Way 1

Use `presets.*` / `register_mode({ prefix, provider })` for things that stay searchable by `query`: `@` document symbols, `#` workspace symbols, `!` diagnostics, `:` lines.

---

## Configuration Reference

Full `setup` defaults (deep-merged via `vim.tbl_deep_extend("force", defaults, opts)`):

```lua
require("nock").setup({
  maxheight = 10,          -- max visible rows; total height = 1 when #filtered==0 else 2 + min(#filtered, maxheight)
  width = 0.3,             -- 0..1 = ratio of columns, clamped [40,80]; >1 = fixed cols
  row = 0,                 -- 0 = pinned top; 0..1 = ratio of lines; >=1 = fixed row
  matcher = "auto",        -- "auto" (vim.fn.matchfuzzypos > lua fzy) | "vim.fn" | "native" | fun(query, items, recency)
  recency = nil,           -- nil | fun(item)->number | map { [label|path]=score } (tie-breaker after score/length)
  show_on_open = true,     -- global fallback for any mode without show_on_open
  hijack_ui_select = true, -- vim.ui.select -> nock.pick
  hijack_lsp_goto = true,  -- vim.lsp.buf.definition etc -> nock.lsp.*
  lsp = {
    timeout = 1000,          -- ms for buf_request_sync fallback
    auto_jump_single = true, -- N==1 goto directly without picker
    preview = true,          -- preview enable for goto selector N>1
  },
  icons = {
    enabled = true,        -- false -> fallback "[Kind]" text
    symbols = {            -- LSP 1..26 + extras, both number and string keys supported, merged over defaults
      File = "󰈙", Module = "󰆧", Namespace = "󰅪", Package = "󰏗", Class = "", Method = "󰊕",
      Property = "󰜢", Field = "󰇽", Constructor = "", Enum = "", Interface = "",
      Function = "󰊕", Variable = "󰀫", Constant = "󰏿", String = "", Number = "󰎠",
      Boolean = "", Array = "󰅪", Object = "", Key = "󰌋", Null = "󰟢",
      EnumMember = "", Struct = "󰙅", Event = "", Operator = "󰆕", TypeParameter = "",
      Reference = "󰌹", Definition = "󰈮", Declaration = "󰒠", Implementation = "󰆧", TypeDefinition = "󰠱",
    },
    diagnostics = {        -- severity -> icon, merged over defaults
      Error = "󰅚", Warn = "󰀪", Info = "󰋽", Hint = "󰌶",
    },
  },
  highlights = {
    selected  = "CursorLine",
    preview   = "IncSearch",
    separator = "FloatBorder",
    scrollbar = "NonText",
    loading   = "MoreMsg",
  },
  window = {
    border  = "rounded",               -- "rounded" | "single" | "double" | "none"
    winblend = 0,
    padding = { left = 1, right = 1 }, -- reserved, rendered via buffer content
  },
  files = {
    ignore = { ".git", "node_modules", ".DS_Store" }, -- glob or segment, e.g. "dist/**", "*.log"
    gitignore = true,    -- merge cwd/.gitignore patterns (cached per cwd+mtime)
    fd_cmd = nil,          -- string | false (disable fd); auto-detects fd/fdfind
    initial_sort = "recent",
    show = false,          -- global: empty query shows only MRU; modes.files.show=true overrides to MRU+files
  },
  modes = {
    files = {
      prefix = "",
      keymap = "<C-p>",
      provider = files_provider, -- (query, ctx, cb) -> Item[]
      action = files_action,     -- (item, ctx)
      preview = false,
      show_on_open = true,
      show = true,       -- nil inherits files.show; true/false overrides
      ignore = nil,      -- nil inherits files.ignore
      gitignore = nil,   -- nil inherits files.gitignore
      fd_cmd = nil,      -- nil inherits files.fd_cmd
    },
    -- add presets or custom modes here; any key is a new Mode
  },
})
```

- `modes[name].prefix` must be `""` (exactly one provider-eligible fallback) or a single ASCII punctuation character; letters/digits/whitespace/multibyte, multi-char strings, duplicate non-empty prefixes, and duplicate fallbacks all `error()` in `setup()` / `register_mode()`. Provider-less `""` modes don't count toward the single-fallback limit.
- `register_mode(name, spec)` hot-plugs / overwrites at runtime (deep-merged); also wires `keymap` and `_lsp_target` hijacks. Overwriting a Mode keeps its old `prefix` unless `spec.prefix` is given; the merged result is re-validated including collisions. To move the fallback, free `""` first (e.g. `setup({ modes = { files = { prefix = ";" }, custom = { prefix = "" } } })`).

---

## API

### `nock.setup(opts?)`

Deep-merge `defaults` with `opts`, reset file snapshot cache, bind `modes.*.keymap` across `n/i/v/x/c/t`, create `NockFilesCache` autocmd group, and hijack `vim.ui.select` when `hijack_ui_select ~= false` (original saved as `nock._orig_ui_select`) and hijack `vim.lsp.buf.definition` etc when `hijack_lsp_goto ~= false` (originals saved as `nock._orig_lsp_buf`). Prefix modes with `_lsp_target` hijack `vim.lsp.buf.document_symbol` / `workspace_symbol` independently.

```lua
require("nock").setup({ maxheight = 15, hijack_lsp_goto = false })
```

### `nock.open(mode_name?)`

Way 1 — open Shell for `mode_name` or fallback via prefix resolution when `nil`. Single native popup `mount`; if already open, switches mode in-place preserving `eff` and cursor offset. Clears `files` Project Files Snapshot for current `cwd` when opening `files` (or any `prefix=""`).

```lua
require("nock").open()        -- fallback (files)
require("nock").open("files") -- explicit
```

Shell-level `open(mode, opts)` also accepts `opts = { maxheight, width, row }` overrides; `nock.open` is the public entry (highlights lazy-setup included).

### `nock.pick(items, opts, on_choice)`

Way 2 / Selector — unified `vim.ui.select` replacement. Also assigned to `vim.ui.select` when hijacked.

```lua
---@param items table  any[] (string|table)
---@param opts table|nil { prompt:string, kind:string, format_item:fun(item)->string, preview:boolean, auto_jump_single:boolean, maxheight:number, width:number, row:number }
---@param on_choice fun(item, idx)|nil
---@return popup|nil
require("nock").pick(items, { prompt = "Pick:", kind = "nock-lsp" }, function(item, idx) end)
vim.ui.select(items, { prompt = "Code actions:" }, on_choice) -- same when hijacked
```

Behavior: `prompt` is placeholder via extmark overlay, `kind` maps to `Item.kind` (capitalized), `format_item` maps to `label`, `auto_jump_single=true` by default (`N==1` calls `on_choice(item,1)` without picker), `preview` auto-enables only if any coerced `Item` has `location`, `N==0` calls `on_choice(nil,nil)` with a notification and no picker.

### `nock.close(opts?)`

Close Shell, clear timers / namespace / preview highlight, `winrestview` when `opts.restore ~= false`, and clean transient `__pick__` mode. Selector cancel calls `on_choice(nil,nil)`.

```lua
require("nock").close()
require("nock").close({ restore = false })
```

### `nock.restore_ui_select()`

Restore original `vim.ui.select` saved at `setup`.

```lua
require("nock").restore_ui_select()
```

### `nock.restore_lsp()`

Restore original `vim.lsp.buf.definition` etc saved at `setup`.

```lua
require("nock").restore_lsp()
```

### `nock.restore()`

Restore both `vim.ui.select` and `vim.lsp.buf.*`.

```lua
require("nock").restore()
```

### `nock.register_mode(name, spec)`

Hot-plug a Mode spec; duplicate `name` overwrites (deep-merged). Wires `keymap` and `_lsp_target` immediately.

```lua
require("nock").register_mode("branches", { prefix = "$", provider = fn, action = fn })
```

### `nock.providers.files.invalidate(cwd?)`

Clears `Project Files Snapshot` (per-`cwd` if `cwd` given, else all) and `_cached_gitignore`; next non-empty query re-scans. Debounced autocmds call this via `_schedule_invalidate`. Exposed as `require("nock.providers.files").invalidate(cwd)`.

```lua
require("nock.providers.files").invalidate()          -- all
require("nock.providers.files").invalidate(vim.fn.getcwd())
```

### `nock.presets.*`

Return a Mode spec for `setup.modes`:

```lua
presets.commands({ prefix = ">", keymap = "<C-S-p>" })
presets.lsp_document_symbols({ prefix = "@", keymap = "<leader>ss" })  -- _lsp_target="document_symbol", preview=true
presets.lsp_workspace_symbols({ prefix = "#", keymap = "<leader>sw" }) -- show_on_open=false, incremental=false
presets.diagnostics({ prefix = "!", workspace = false })
presets.lines({ prefix = ":", keymap = "<leader>sl" })
```

### `nock.actions.*`

Standard `action(item, ctx)`:

```lua
actions.edit(item, ctx)       -- open buf/file at location, set cursor
actions.cmd(item, ctx)        -- vim.cmd(value or label sans ":")
actions.set_cursor(item, ctx) -- jump cursor in origin win
```

### `nock.utils.*`

Converters:

```lua
utils.lsp_symbol_kind_name(kind)
utils.lsp_symbol_to_item(sym, opts)
utils.lsp_location_to_item(loc, opts)
utils.lsp_locations_to_items(input, opts) -- Location[] or buf_request_sync map -> Item[] (deduped)
utils.format_diagnostic(diag, opts)
```

### `nock.lsp.*`

LSP Goto Selector (Way 2, async fan-out to all clients, `N==0/1/N` handling):

```lua
require("nock.lsp").definition({ bufnr, win, prompt, preview, auto_jump_single, timeout, on_choice })
require("nock.lsp").declaration(opts)
require("nock.lsp").type_definition(opts) -- alias typeDefinition
require("nock.lsp").implementation(opts)
require("nock.lsp").references(opts)
require("nock.lsp").pick_for_method("textDocument/definition", params, opts) -- generic
```

`pick_for_method(method, params, opts)` — `opts = { bufnr, win, prompt, preview, auto_jump_single, timeout, on_choice }`, fans out `client:request` async with 1000ms `buf_request_sync` fallback, dedupes via `lsp_locations_to_items`, delegates to `shell.pick`.

---

## Highlights

| Group | Default link | Purpose |
|-------|--------------|---------|
| `NockMatch` | `Search` | Matched chars (`filter_text`/`label` positions via extmarks) |
| `NockSelected` | `CursorLine` | Current row |
| `NockPreview` | `IncSearch` | Transient preview highlight in origin buffer |
| `NockSeparator` | `FloatBorder` | `─` line between Input and List |
| `NockScrollbar` | `NonText` | Proportional `▐` thumb (`virt_text`) |
| `NockLoading` | `MoreMsg` | Loading indicator in Input row |

Override: `setup({ highlights = { selected="Visual", loading="Comment" } })`.

---

## Architecture

- **Shell**: `lua/nock/shell.lua` — Input + List state, prefix resolution, debounce (50ms), incremental filter, generation-cancelled async, `render()` with separator/scrollbar, in-place mode switch, `pick` Selector.
- **Filter**: `lua/nock/filter.lua` — `apply(raw)` pipeline: trim `eff`, resolve Mode, `show_on_open` gate, Provider (sync/async + `is_cancelled`), Matcher scoring, `prev_query`/`prev_raw`/`req_id`/`pending_req` generational guard.
- **Popup**: `lua/nock/ui/popup.lua` — single `nvim_open_win` wrapper (`mount`/`unmount`/`update_layout`/`is_valid`), `buftype=nofile`, `style=minimal`.
- **Matcher**: `lua/nock/matcher.lua` — chain `vim.fn.matchfuzzypos` → Lua fzy → native, `filter_text` aware, score→length→recency.
- **Geometry**: `lua/nock/geometry.lua` — clamps width/height/row/col; height `1` vs `2+min(filtered,maxheight)`.
- **Preview**: `lua/nock/preview.lua` — `winrestview` save/restore without jumplist pollution, `zz` centered, extmark hl.
- **Loading**: `lua/nock/loading.lua` — grace-period indicator in Input row, bound to `pending_req == req_id`.
- **LSP**: `lua/nock/lsp.lua` — Goto Selector, `pick_for_method`, `handle_items` (`N==0` notify, `N==1` auto-jump), `_lsp` seam.
- **Providers/Presets**: `lua/nock/providers/files.lua` (Snapshot, `ignore`+`gitignore` merge, `fd` → `git ls-files` → `vim.fs.find`) and `lua/nock/presets.lua`.

No residual state after close — timers, namespaces, preview hl, origin view, filter state, loading, and transient `__pick__` mode all cleared.
