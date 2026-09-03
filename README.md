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
      -- all fields are optional; shown with defaults
      maxheight = 10,
      width = 0.3,       -- 0.3 = 30% of columns, clamped to [40, 80]; number >1 = fixed cols
      row = 0,           -- 0 = pinned top; 0..1 = ratio of lines; >=1 = fixed row
      matcher = "auto",  -- "auto" | "vim.fn" | "native" | function(query, items) -> results
      show_on_open = true,
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
-- Click to select, double-click to confirm
```

- Empty query shows **MRU open buffers** (alternate buffer `#` first, most-recent on top).
- Typed query searches **project files** (`fd` → `git ls-files` → `vim.fs.find`, respects `.gitignore`).
- Height is `1 + 1(sep) + min(#filtered, maxheight)` live; `0` matches collapses to Input-only.

---

## Built-in vs Presets

| Kind | Mode | Prefix | Default keymap | What it does |
|------|------|--------|----------------|--------------|
| **Built-in** | `files` | `""` (fallback) | `<C-p>` | MRU buffers → project files, `fd` aware |
| **Preset** (opt-in) | via `nock.presets.*()` | you choose | you choose | see below |

The core has **only `files`**. All other modes are constructed with `nock.presets` and registered through `setup({ modes = { ... } })`. There is no hidden `commands` mode — it is just another preset.

### Presets — one line to enable

Presets are under `require("nock.presets")`. Each call returns a full `Mode` spec you can drop into `setup.modes`.

```lua
local presets = require("nock.presets")

require("nock").setup({
  modes = {
    -- keep the default
    files = { keymap = "<C-p>" },

    -- 1) Ex commands (":Foo" style, `:` removed before :cmd)
    --    prefix = ">"  — type ">" then filter command names
    my_commands = presets.commands({
      prefix = ">",
      keymap = "<C-S-p>",
    }),

    -- 2) LSP document symbols — current buffer outline
    --    Requires an attached LSP client; returns [] without one.
    --    Sync (buf_request_sync, timeout 1000ms), flattens nested children.
    --    Each Item: [Function] name, kind, detail, location
    doc_symbols = presets.lsp_document_symbols({
      prefix = "@",
      keymap = "<leader>ss",
      -- timeout = 1000, preview = true,
    }),

    -- 3) LSP workspace symbols — async
    --    Empty query returns []; non-empty query fans out to all clients.
    --    Callback-based async; stale callbacks are dropped via generation token.
    --    Supports ctx.is_cancelled() inside provider.
    workspace_symbols = presets.lsp_workspace_symbols({
      prefix = "#",
      keymap = "<leader>sw",
      -- show_on_open = false, timeout via client
    }),

    -- 4) Diagnostics — current buffer by default, or workspace
    --    Uses vim.diagnostic.get(). Each Item: [Error] msg, detail "path:lnum:col"
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

**Prefix resolution** (ADR-0005): longest matching `prefix` wins. No match → fallback to `prefix = ""` (`files`). Deleting the prefix character inside the popup instantly returns to `files`.

---

## Custom Mode — simple, flexible, unified

A `Mode` is just `{ prefix, keymap, provider, action, preview }`.

```lua
-- Minimal example: recent git branches
require("nock").register_mode("branches", {
  prefix = "$",
  keymap = "<leader>sb",
  preview = false, -- no location jump

  -- provider(query, ctx, callback?) -> Item[] | nil (async via callback)
  provider = function(query, ctx, callback)
    -- ctx = { win = origin_win, buf = origin_buf, file = origin_file,
    --         is_cancelled = function() -> bool }
    -- query is the effective query (prefix stripped)
    -- Return sync:
    local branches = vim.fn.systemlist("git branch --format='%(refname:short)'")
    local items = {}
    for _, b in ipairs(branches) do
      table.insert(items, {
        label = b,
        -- filter_text = b, -- optional: search text if different from label
        -- kind = "Branch",  -- optional: renders as "[Branch] main"
        -- detail = "branch", -- right-side dimmed text
        -- location = { path = "file", lnum = 1, col = 0 }, -- enables preview
        value = b,
      })
    end
    return items

    -- Async alternative:
    -- vim.system({"git","branch"}, {text=true}, function(obj)
    --   if ctx.is_cancelled() then return end
    --   callback(items)
    -- end)
    -- return nil
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
| `label` | `string` | yes | Display + default search text. With `kind`, rendered as `"[Kind] label"` |
| `filter_text` | `string` | no | Matcher uses this instead of `label` when present |
| `kind` | `string` | no | `"Function"`, `"Class"`, `"Error"`, `"Warn"`… prefix via `[Kind]` |
| `detail` | `string` | no | Secondary dimmed text (e.g. file path, diagnostic source) |
| `location` | `{path, lnum, col}` | no | Enables live **Preview** (transient jump) and default `actions.edit` |
| `value` | `any` | no | Payload for `action` |
| `bufnr` | `number` | no | Buffer handle when applicable |

### Provider contract

```lua
---@param query string        -- effective query, prefix stripped; "" = show_on_open list
---@param ctx table           -- { win, buf, file, is_cancelled: ()->bool }
---@param callback function?  -- async: callback(items) when ready, return nil
---@return table|nil          -- sync: Item[]
function provider(query, ctx, callback) end
```

- `query == ""` → return initial list (e.g. MRU, diagnostics) when `show_on_open ~= false`.
- Non-empty → return filtered source; matcher does fuzzy scoring.
- `ctx.is_cancelled()` + generation token: Shell drops stale async results automatically.

### Actions & Utils

```lua
local actions = require("nock.actions")
local utils   = require("nock.utils")

-- Standard actions
actions.edit(item, ctx)       -- open buf/file at location, set cursor (MRU-aware)
actions.cmd(item, ctx)        -- vim.cmd(value or label without leading ":")
actions.set_cursor(item, ctx) -- jump cursor in origin win (for :lines)

-- Converters
utils.lsp_symbol_kind_name(12)               -- 12 -> "Function"
utils.lsp_symbol_to_item(sym, opts)          -- LSP Symbol -> Item { kind, location }
utils.lsp_location_to_item(loc, opts)        -- LSP Location/LocationLink -> Item { kind="Definition", location }
utils.lsp_locations_to_items(input, opts)    -- Location[] | buf_request_sync map -> Item[] (deduped)
utils.format_diagnostic(diag, opts)          -- vim.diagnostic -> Item { kind="Error"/"Warn", detail="path:lnum:col" }
```

### Two ways — persistent Mode vs Selector (vim.ui.select)

nock has two usage patterns. Pick the right one:

|  | **Way 1 — Persistent Mode** | **Way 2 — Selector** |
|---|---|---|
| When | **Searchable large list**: results depend on what you type, many candidates | **One-shot small list via `vim.ui.select`**: results are already known, `N` is small (2–20), determined by cursor position |
| Examples | `files`, `:lines`, LSP `document/workspace_symbols`, `diagnostics`, `commands` | `textDocument/definition` (`gd`), `implementation` (`gi`), `references` (`gr`), `typeDefinition`, `code_action` — plus any plugin that calls `vim.ui.select` |
| Source | `provider(query, ctx, cb) -> Item[]` — generated dynamically per `query` | `items: any[]` already computed: `utils.lsp_locations_to_items(res, …)` or any `string|table` list passed to `vim.ui.select` |
| How to open | `prefix` (e.g. `@`/`#`/`>`) + `keymap` + `nock.open("mode")`; Input shows `prefix + query` | `vim.ui.select(items, opts, on_choice)` — hijacked to `nock.pick`; or direct `nock.pick(items, opts, on_choice)`; **no prefix**, Input starts empty, typing only filters the same `items` |
| Occupies `prefix` table | Yes — global `ADR-0005` longest-prefix wins | **No** |
| What Input shows | `>foo` / `@MyClass` — prefix participates in `filter.resolve` | Empty + `opts.prompt` as placeholder (e.g. `"Code actions:"`); when `N>1` the list shows all `N` immediately, no `gd` text |

> **Why `gd`/`gi` do not fit Way 1:** Using `setup({ modes = { lsp_definitions = { prefix="gd", provider=function() return cache end }}})` + `nock.open("lsp_definitions")` requires a global `prefix="gd"`, a mutable `defs_cache`, and a fake-persistent `provider` — the whole `Input→resolve→provider→matcher` chain runs for a one-shot result. Way 2 just calls `pick`/`vim.ui.select` with no `prefix` and no `cache`.

`setup()` hijacks `vim.ui.select` by default (`hijack_ui_select = true`). Opt out with `setup({ hijack_ui_select = false })` and restore via `require("nock").restore_ui_select()`. Original is saved as `nock._orig_ui_select`.

#### Recipe: `gd` / `gi` — via `vim.ui.select` (Way 2, recommended)

`vim.ui.select` is now `nock.pick`. No `register_mode`, no `prefix="gd"`. `N==0` calls `on_choice(nil,nil)`, `N==1` auto-jumps (`auto_jump_single=true` default), `N>1` shows empty Input + placeholder, `preview` auto-enables only if any item has `location`:

```lua
local utils = require("nock.utils")

local function select_or_jump(items, opts, on_choice)
  -- opts: {prompt?, kind?, format_item?} forwarded to nock.pick
  -- nock.pick handles 0→on_choice(nil), 1→auto on_choice(item,1), N→picker
  return vim.ui.select(items, opts, on_choice)
end

vim.keymap.set("n", "gd", function()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients == 0 then return vim.notify("No LSP client attached", vim.log.levels.WARN) end
  local enc = clients[1].offset_encoding or "utf-16"
  local params = vim.lsp.util.make_position_params(win, enc)
  local res = vim.lsp.buf_request_sync(buf, "textDocument/definition", params, 1000)
  local items = utils.lsp_locations_to_items(res, { bufnr = buf, win = win })
  -- nock.pick (via vim.ui.select) auto-handles 0/1/N; preview auto from location
  vim.ui.select(items, { prompt = "Definitions:", kind = "nock-lsp" }, function(item, idx)
    if not item then return end
    require("nock.actions").edit(item, { win = win, buf = buf })
  end)
end)

vim.keymap.set("n", "gi", function()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients == 0 then return vim.notify("No LSP client attached", vim.log.levels.WARN) end
  local enc = clients[1].offset_encoding or "utf-16"
  local params = vim.lsp.util.make_position_params(win, enc)
  local res = vim.lsp.buf_request_sync(buf, "textDocument/implementation", params, 1000)
  local items = utils.lsp_locations_to_items(res, { bufnr = buf, win = win })
  vim.ui.select(items, { prompt = "Implementations:", kind = "nock-lsp" }, function(item)
    if not item then return end
    require("nock.actions").edit(item, { win = win, buf = buf })
  end)
end)
-- gr / typeDefinition / code_action: same pattern, just change method/prompt
-- Any other plugin calling vim.ui.select (e.g. code_action) is now unified automatically.
```

`utils.lsp_locations_to_items` handles `Location` vs `LocationLink` (`targetUri/targetRange/targetSelectionRange`), `utf-16` → byte `col` via `vim.str_byteindex`, and `path:lnum:col` dedup. **Do not** `register_mode` for `gd` or occupy `prefix="gd"` — that is the Way 1 anti-pattern. For generic `vim.ui.select` callers, `nock.pick` auto-coerces `string|table` via `opts.format_item` → `label`, `opts.kind` → `kind`, and keeps original `value` for `on_choice`.

#### When to stay on Way 1

Use `presets.*` / `register_mode({ prefix, provider })` for things that stay searchable by `query`: `@` document symbols, `#` workspace symbols, `!` diagnostics, `:` lines.
## Configuration Reference

Full `setup` defaults (deep-merged via `vim.tbl_deep_extend("force", defaults, opts)`):

```lua
require("nock").setup({
  maxheight = 10,          -- max visible rows; total height = 1 + 1(sep) + min(#filtered, maxheight)
  width = 0.3,             -- 0..1 = ratio of columns, clamped [40,80]; >1 = fixed cols
  row = 0,                 -- 0 = pinned top; 0..1 = ratio of lines; >=1 = fixed row
  matcher = "auto",        -- "auto" (vim.fn.matchfuzzypos > lua fzy) | "vim.fn" | "native" | fun(query, items, recency)
  recency = nil,           -- nil | fun(item)->number | map { [label|path]=score } (tie-breaker after score/length)
  show_on_open = true,     -- show initial list for prefix="" mode
  icons = {
    enabled = true,        -- false -> fallback "[Kind]" text
    symbols = {            -- LSP 1..26, both number and string keys supported, merged over defaults (26 Nerd Codicons)
      File = "󰈙", Module = "󰆧", Namespace = "󰅪", Package = "󰏗", Class = "", Method = "󰊕",
      Property = "󰜢", Field = "󰇽", Constructor = "", Enum = "", Interface = "",
      Function = "󰊕", Variable = "󰀫", Constant = "󰏿", String = "", Number = "󰎠",
      Boolean = "", Array = "󰅪", Object = "", Key = "󰌋", Null = "󰟢",
      EnumMember = "", Struct = "󰙅", Event = "", Operator = "󰆕", TypeParameter = "",
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
  },
  window = {
    border  = "rounded",               -- "rounded" | "single" | "double" | "none"
    winblend = 0,
    padding = { left = 1, right = 1 }, -- reserved, rendered via buffer content
  },
  files = {
    ignore = { ".git", "node_modules", ".DS_Store" }, -- glob or segment, e.g. "dist/**", "*.log"
    fd_cmd = nil,          -- string | false (disable fd); auto-detects fd/fdfind
    initial_sort = "recent",
    show = false,          -- true: empty query shows MRU + all files (MRU first, fd order); false: only MRU
  },
  modes = {
    files = {
      prefix = "",
      keymap = "<C-p>",
      provider = files_provider, -- (query, ctx, cb) -> Item[]
      action = files_action,     -- (item, ctx)
      preview = false,
      show_on_open = true,
      show = nil,          -- nil inherits files.show; true/false overrides
      ignore = nil,        -- nil inherits files.ignore
    files = {
      prefix = "",
      keymap = "<C-p>",
      provider = files_provider, -- (query, ctx, cb) -> Item[]
      action = files_action,     -- (item, ctx)
      preview = false,
      show_on_open = true,
    },
    -- add presets or custom modes here; any key is a new Mode
  },
})
```

- `modes[name].prefix` must be explicit `""` to be fallback-eligible and needs `provider` function.
- `register_mode(name, spec)` hot-plugs / overwrites at runtime (deep-merged).

---

## API

| Function | Signature | Notes |
| `setup` | `setup(opts?)` | Deep-merge defaults, reset file cache, bind `modes.*.keymap`, create `NockFilesCache` autocmd group, and hijack `vim.ui.select` when `hijack_ui_select ~= false` (default `true`; original saved as `nock._orig_ui_select`) |
| `open` | `open(mode_name?, opts?) -> popup` | **Way 1** — `mode_name` or `nil` → fallback via prefix resolution; `opts = {maxheight,width,row}` overrides; single native popup `mount`; clears `files` Project Files Snapshot for current `cwd` on open |
| `pick` | `pick(items, opts, on_choice) -> popup\|nil` | **Way 2 / Selector** — unified `vim.ui.select` replacement; `items:any[]`, `opts:{prompt,kind,format_item,preview,auto_jump_single,maxheight,width,row}`, `on_choice(item, idx)`; `prompt` is placeholder (Q5=A), `kind`→`kind`, `format_item`→`label` (Q8=A), `auto_jump_single=true` (Q4), `preview` auto from `location` (Q9=A), `N==0` → `on_choice(nil,nil)` no picker (Q10=A); also `vim.ui.select` when hijacked |
| `close` | `close(opts?)` | `{restore=true}` winrestview; clears timers/ns/preview; also cleans transient `__pick__` mode; cancel calls `on_choice(nil,nil)` for Selector |
| `restore_ui_select` | `restore_ui_select()` | Restore original `vim.ui.select` saved at `setup` |
| `register_mode` | `register_mode(name, spec)` | Hot-plug; duplicate name overwrites |
| `invalidate` | `require("nock.providers.files").invalidate(cwd?)` | Clears Project Files Snapshot (per-`cwd` if `cwd` given, else all) and `_cached_gitignore`; next non-empty query re-scans; debounced autocmds call this via `_schedule_invalidate` |
| `presets.*` | `presets.commands(opts?)` etc | Returns Mode spec — see Presets table (Way 1) |
| `actions.*` | `actions.edit/cmd/set_cursor` | Standard `action(item,ctx)` |
| `utils.*` | `utils.lsp_symbol_to_item` etc | Converters |

---

## Highlights

| Group | Default link | Purpose |
|-------|--------------|---------|
| `NockMatch` | `Search` | Matched chars (`filter_text`/`label` positions via extmarks) |
| `NockSelected` | `CursorLine` | Current row |
| `NockPreview` | `IncSearch` | Transient preview highlight in origin buffer |
| `NockSeparator` | `FloatBorder` | `─` line between Input and List |
| `NockScrollbar` | `NonText` | Proportional `▐` thumb (`virt_text`) |

Override: `setup({ highlights = { match="MyMatch", selected="Visual" } })`.

---

## Architecture

- **Shell**: `lua/nock/shell.lua` — Input + List state, prefix resolution, debounce (50ms), incremental filter, generation-cancelled async, `render()` with separator/scrollbar.
- **Popup**: `lua/nock/ui/popup.lua` — single `nvim_open_win` wrapper (`mount`/`unmount`/`update_layout`/`is_valid`), `buftype=nofile`, `style=minimal`.
- **Matcher**: `lua/nock/matcher.lua` — chain `vim.fn.matchfuzzypos` → Lua fzy → native, `filter_text` aware, score→length→recency.
- **Geometry**: `lua/nock/geometry.lua` — clamps width/height/row/col.
- **Preview**: `lua/nock/preview.lua` — `winrestview` save/restore without jumplist pollution.

No residual state after close — timers, namespaces, preview hl, origin view, filter state all cleared.
