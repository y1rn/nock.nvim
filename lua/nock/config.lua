local M = {}

-- Built-in Modes now use real Providers/Actions (Ticket 03).
-- Lazy require to avoid circular dependency (providers require config at call time).
local function files_provider(q, ctx, cb)
  return require("nock.providers.files").provider(q, ctx, cb)
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
    transparent = true,
    winhighlight = nil,
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

--- Prefix must be "" (fallback) or a single ASCII punctuation byte (Q1 A, Q3 A, Q4 A).
--- Rejects alnum, whitespace, and multibyte: #prefix==1 byte + byte in 33-47/58-64/91-96/123-126.
---@param name string
---@param prefix any
local function assert_valid_prefix(name, prefix)
  if type(prefix) ~= "string" then
    error(string.format("nock: mode '%s' prefix must be string, got %s", name, type(prefix)))
  end
  if prefix == "" then return end
  if #prefix ~= 1 then
    error(string.format("nock: mode '%s' prefix must be \"\" or single character, got %q", name, prefix))
  end
  local b = prefix:byte(1)
  local is_punct = (b >= 33 and b <= 47) or (b >= 58 and b <= 64) or (b >= 91 and b <= 96) or (b >= 123 and b <= 126)
  if not is_punct then
    error(string.format("nock: mode '%s' prefix must be single ASCII punctuation, got %q", name, prefix))
  end
end

--- No two modes share a non-empty prefix; at most one provider-eligible "" fallback (Q2 A, Q6 A).
---@param modes table
local function assert_no_prefix_collision(modes)
  local seen = {}
  local fallback_name = nil
  for name, spec in pairs(modes) do
    local pref = spec.prefix
    if pref == nil then pref = "" end
    if pref ~= "" then
      if seen[pref] then
        error(string.format("nock: duplicate prefix %q (modes '%s' and '%s')", pref, seen[pref], name))
      end
      seen[pref] = name
    elseif type(spec.provider) == "function" then
      if fallback_name then
        error(string.format("nock: duplicate fallback prefix \"\" (modes '%s' and '%s'); only one fallback mode allowed", fallback_name, name))
      end
      fallback_name = name
    end
  end
end

--- Validate a mode spec (Q6 C: provider strict, prefix strict single punctuation)
 local function validate_spec(name, spec)
   if spec.provider ~= nil and type(spec.provider) ~= "function" then
     error(string.format("nock: mode '%s' provider must be function, got %s", name, type(spec.provider)))
   end
  if spec.prefix ~= nil then assert_valid_prefix(name, spec.prefix) end
 end

--- Deep-merge user opts over defaults, preserving unspecified built-ins.
--- Uses vim.tbl_deep_extend("force", defaults, user).
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- normalize: ensure each mode has string prefix (nil -> "") and validate (Q1-Q6 A)
  for name, spec in pairs(M.options.modes or {}) do
    if spec.prefix == nil then spec.prefix = "" end
    validate_spec(name, spec)
  end
  assert_no_prefix_collision(M.options.modes or {})
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
      local ev = args and args.event or ""
      -- DirChanged carries no file; treat as cwd-level
      if ev == "DirChanged" then fname = "" end
      -- Lifecycle events from nameless or non-file buffers must not poison
      -- the snapshot: nock's own popup (nofile, unlisted, bufhidden=wipe)
      -- fires BufAdd/BufDelete/BufWipeout on every open/close, which used to
      -- wipe the snapshot ~150ms later so EVERY reopen was a cold load.
      -- BufWritePost (a real write happened) and DirChanged stay unconditional.
      if ev ~= "DirChanged" and ev ~= "BufWritePost" then
        local buftype = nil
        local buf = args and args.buf
        if buf and vim.api.nvim_buf_is_valid(buf) then
          pcall(function() buftype = vim.bo[buf].buftype end)
        end
        if fname == "" or (buftype ~= nil and buftype ~= "") then return end
      end
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
  assert_valid_prefix(name, merged.prefix)
  local probe = {}
  for k, v in pairs(M.options.modes or {}) do probe[k] = v end
  probe[name] = merged
  assert_no_prefix_collision(probe)
  M.options.modes[name] = merged
end

--- Resolve raw input to (mode_name, eff_query) — single-char prefix match, fallback to provider-eligible mode
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
