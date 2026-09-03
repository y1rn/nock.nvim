local M = {}

-- Built-in Modes now use real Providers/Actions (Ticket 03).
-- Lazy require to avoid circular dependency (providers require config at call time).
local function files_provider(q)
  return require("nock.providers.files").provider(q)
end

local function files_action(item, ctx)
  return require("nock.providers.files").action(item, ctx)
end


---@type table
M.defaults = {
  maxheight = 10,
  width = 0.3,
  row = 0,
  matcher = "auto",
  recency = nil,
  show_on_open = true,
  hijack_lsp_goto = true,
  hijack_ui_select = true,
  lsp = {
    timeout = 1000,
    auto_jump_single = true,
    preview = true,
  },
  icons = {
    enabled = true,
    symbols = {
      File = "󰈙",
      Module = "󰆧",
      Namespace = "󰅪",
      Package = "󰏗",
      Class = "",
      Method = "󰊕",
      Property = "󰜢",
      Field = "󰇽",
      Constructor = "",
      Enum = "",
      Interface = "",
      Function = "󰊕",
      Variable = "󰀫",
      Constant = "󰏿",
      String = "",
      Number = "󰎠",
      Boolean = "",
      Array = "󰅪",
      Object = "",
      Key = "󰌋",
      Null = "󰟢",
      EnumMember = "",
      Struct = "󰙅",
      Event = "",
      Operator = "󰆕",
      TypeParameter = "",
      Reference = "󰌹",
      Definition = "󰈮",
      Declaration = "󰒠",
      Implementation = "󰆧",
      TypeDefinition = "󰠱",
    },
    diagnostics = {
      Error = "󰅚",
      Warn = "󰀪",
      Info = "󰋽",
      Hint = "󰌶",
    },
  },
  highlights = {
    match = "Search",
    selected = "CursorLine",
    preview = "IncSearch",
    separator = "FloatBorder",
    scrollbar = "NonText",
    loading = "MoreMsg",
  },
  window = {
    border = "rounded",
    winblend = 0,
    padding = { left = 1, right = 1 },
  },
  files = {
    ignore = { ".git", "node_modules", ".DS_Store" },
    gitignore = true,
    fd_cmd = nil,
    initial_sort = "recent",
    show = false,
  },
  modes = {
    files = {
      prefix = "",
      keymap = "<C-p>",
      provider = files_provider,
      action = files_action,
      preview = false,
      show_on_open = true,
      show = true,
      ignore = nil,
      gitignore = nil,
      fd_cmd = nil,
    },
  },
}
---@param recency table|fun(item:table):number|nil
function M._normalize_recency(recency)
  if recency == nil then
    return function() return 0 end
  end
  if type(recency) == "function" then
    return function(item)
      local ok, v = pcall(recency, item)
      if ok and type(v) == "number" then return v end
      if ok and v then return 1 end
      return 0
    end
  end
  if type(recency) == "table" then
    return function(item)
      local label = item.label or item.value or ""
      local v = recency[label]
      if v ~= nil then
        if type(v) == "number" then return v end
        if v then return 1 end
        return 0
      end
      local path = item.location and item.location.path or nil
      if path then
        v = recency[path]
        if v ~= nil then
          if type(v) == "number" then return v end
          if v then return 1 end
          return 0
        end
      end
      return 0
    end
  end
  return function() return 0 end
end


---@type table
M.options = vim.deepcopy(M.defaults)
M.options._recencyFn = M._normalize_recency(M.options.recency)

--- Deep-merge user opts over defaults, preserving unspecified built-ins.
--- Uses vim.tbl_deep_extend("force", defaults, user).
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- normalize: ensure each mode has string prefix (nil -> "") and validate provider
  for name, spec in pairs(M.options.modes or {}) do
    if spec.prefix == nil then spec.prefix = "" end
    if spec.provider ~= nil and type(spec.provider) ~= "function" then
      error(string.format("nock: mode '%s' provider must be function, got %s", name, type(spec.provider)))
    end
    if spec.prefix ~= nil and type(spec.prefix) ~= "string" then
      error(string.format("nock: mode '%s' prefix must be string, got %s", name, type(spec.prefix)))
    end
  end
  M.options._recencyFn = M._normalize_recency(M.options.recency)
  local ok, fp = pcall(require, "nock.providers.files")
  if ok and fp._reset_cache then fp._reset_cache() end
  -- Snapshot Invalidation (ADR-0018 Q5 B): autocmd-driven debounced clear per cwd
  pcall(function()
    local group = vim.api.nvim_create_augroup("NockFilesCache", { clear = true })
    local function schedule(args)
      local fp2_ok, fp2 = pcall(require, "nock.providers.files")
      if not fp2_ok or not fp2._schedule_invalidate then return end
      local fname = args and (args.file or args.match) or ""
      -- DirChanged carries no file; treat as cwd-level
      if args and args.event == "DirChanged" then fname = "" end
      pcall(fp2._schedule_invalidate, fname)
    end
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufNewFile", "BufDelete", "BufAdd", "BufWipeout" }, {
      group = group,
      callback = schedule,
    })
    vim.api.nvim_create_autocmd("DirChanged", {
      group = group,
      callback = schedule,
    })
  end)
end

--- Validate a mode spec (Q6 C: provider strict, prefix lax)
---@param name string
---@param spec table
local function validate_spec(name, spec)
  if spec.provider ~= nil and type(spec.provider) ~= "function" then
    error(string.format("nock: mode '%s' provider must be function, got %s", name, type(spec.provider)))
  end
  if spec.prefix ~= nil and type(spec.prefix) ~= "string" then
    error(string.format("nock: mode '%s' prefix must be string, got %s", name, type(spec.prefix)))
  end
end

--- Register or overwrite a Mode at runtime (hot-plug).
---@param name string
---@param spec table
function M.register_mode(name, spec)
  assert(type(name) == "string" and name ~= "", "register_mode: name must be non-empty string")
  assert(type(spec) == "table", "register_mode: spec must be table")
  validate_spec(name, spec)
  local existing = M.options.modes[name] or {}
  local merged = vim.tbl_deep_extend("force", existing, spec)
  if merged.prefix == nil then merged.prefix = "" end
  M.options.modes[name] = merged
end

--- Resolve raw input to (mode_name, eff_query) — longest prefix wins, fallback to provider-eligible mode
---@param raw string|nil
---@return string mode_name, string eff_query
function M.resolve(raw)
  raw = raw or ""
  local modes = M.options.modes or {}
  local best_name = nil
  local best_prefix = ""
  for name, spec in pairs(modes) do
    local pref = spec.prefix
    if type(pref) == "string" and pref ~= "" and raw:sub(1, #pref) == pref then
      if #pref > #best_prefix then
        best_prefix = pref
        best_name = name
      end
    end
  end
  if best_name then return best_name, raw:sub(#best_prefix + 1) end
  if modes.files and (modes.files.prefix == nil or modes.files.prefix == "") and type(modes.files.provider) == "function" then
    return "files", raw
  end
  local fallback = "files"
  for name, spec in pairs(modes) do
    if (spec.prefix == "" or spec.prefix == nil) and type(spec.provider) == "function" then
      fallback = name
      break
    end
  end
  return fallback, raw
end

function M.get_mode(name) return M.options.modes and M.options.modes[name] or nil end


function M.get()
  return M.options
end

function M.reset()
  M.options = vim.deepcopy(M.defaults)
  M.options._recencyFn = M._normalize_recency(M.options.recency)
  local ok, fp = pcall(require, "nock.providers.files")
  if ok and fp._reset_cache then fp._reset_cache() end
end

return M
