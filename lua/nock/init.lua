local M = {}

local config = require("nock.config")
local highlights = require("nock.highlights")
local shell = require("nock.shell")

local function map(buf, modes, lhs, fn)
  if buf and type(buf) == "number" then
    pcall(vim.keymap.set, modes, lhs, fn, { buffer = buf, silent = true, nowait = true })
  else
    local m, l, f, desc
    if (type(buf) == "string" or type(buf) == "table") and type(modes) == "string" and type(lhs) == "function" then
      m, l, f, desc = buf, modes, lhs, fn
    elseif buf == nil then
      m, l, f = modes, lhs, fn
      desc = nil
    else
      m, l, f = modes, lhs, fn
      desc = nil
    end
    local opts = { noremap = true, silent = true }
    if desc and type(desc) == "string" then
      opts.desc = desc
    elseif f then
      opts.desc = "Nock open " .. tostring(l)
    end
    pcall(vim.keymap.set, m, l, f, opts)
  end
end

--- Setup nock with deep-merge over built-ins.
--- Handles maxheight, matcher, highlights, modes, keymaps and vim.ui.select hijack.
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  config.setup(opts)
  highlights.setup(config.options.highlights)

  for mode_name, mode_spec in pairs(config.options.modes) do
    if mode_spec.keymap and mode_spec.keymap ~= "" then
      local name = mode_name
      local lhs = mode_spec.keymap
      map({ "n", "i", "v", "x", "c", "t" }, lhs, function()
        M.open(name)
      end, "Nock open " .. name)
    end
  end
  -- Hijack vim.ui.select — default true, opt-out via hijack_ui_select=false or config.hijack_ui_select
  local hijack_ui = opts.hijack_ui_select
  if hijack_ui == nil then hijack_ui = config.options.hijack_ui_select end
  if hijack_ui == nil then hijack_ui = true end
  if hijack_ui then
    if vim.ui and vim.ui.select and vim.ui.select ~= M.pick then
      M._orig_ui_select = vim.ui.select
    end
    vim.ui.select = M.pick
  end
  -- Hijack LSP goto (B track) — default true via config.hijack_lsp_goto
  local hijack_goto = opts.hijack_lsp_goto
  if hijack_goto == nil then hijack_goto = config.options.hijack_lsp_goto end
  if hijack_goto == nil then hijack_goto = true end
  if hijack_goto then
    local lsp_mod = require("nock.lsp")
    M._orig_lsp_buf = M._orig_lsp_buf or {}
    local targets = {
      definition = "definition",
      declaration = "declaration",
      typeDefinition = "type_definition",
      type_definition = "type_definition",
      implementation = "implementation",
      references = "references",
    }
    for buf_fn, mod_fn in pairs(targets) do
      -- avoid double hijack
      if vim.lsp and vim.lsp.buf and type(lsp_mod[mod_fn]) == "function" then
        if M._orig_lsp_buf[buf_fn] == nil then
          M._orig_lsp_buf[buf_fn] = vim.lsp.buf[buf_fn]
        end
        vim.lsp.buf[buf_fn] = lsp_mod[mod_fn]
      end
    end
    -- alias typeDefinition already covered
  end
  -- Prefix Mode hijack (A track) — any mode with _lsp_target, independent of hijack_lsp_goto
  M._orig_lsp_prefix = M._orig_lsp_prefix or {}
  for mode_name, mode_spec in pairs(config.options.modes) do
    local target = mode_spec._lsp_target
    if target and type(target) == "string" and target ~= "" then
      -- diagnostic already excluded via no _lsp_target
      if vim.lsp and vim.lsp.buf then
        if M._orig_lsp_prefix[target] == nil then
          M._orig_lsp_prefix[target] = vim.lsp.buf[target]
        end
        local name = mode_name
        vim.lsp.buf[target] = function()
          return M.open(name)
        end
      end
    end
  end
end

--- Hot-plug a new Mode at runtime. Duplicate name overwrites.
---@param name string
---@param spec table
function M.register_mode(name, spec)
  config.register_mode(name, spec)
  if spec.keymap and spec.keymap ~= "" then
    local mode_name = name
    local lhs = spec.keymap
    map({ "n", "i", "v", "x", "c", "t" }, lhs, function()
      M.open(mode_name)
    end, "Nock open " .. mode_name)
  end
  if spec._lsp_target and type(spec._lsp_target) == "string" and spec._lsp_target ~= "" then
    M._orig_lsp_prefix = M._orig_lsp_prefix or {}
    local target = spec._lsp_target
    if M._orig_lsp_prefix[target] == nil and vim.lsp and vim.lsp.buf then
      M._orig_lsp_prefix[target] = vim.lsp.buf[target]
    end
    if vim.lsp and vim.lsp.buf then
      local mode_name = name
      vim.lsp.buf[target] = function()
        return M.open(mode_name)
      end
    end
  end
end
--- Open Shell for given Mode (or default). Single native popup.
---@param mode string|nil
function M.open(mode)
  if vim.fn.hlexists("NockMatch") == 0 then
    highlights.setup(config.options.highlights)
  end
  return shell.open(mode, {
    maxheight = config.options.maxheight,
    width = config.options.width,
    row = config.options.row,
  })
end

--- Selector: unified vim.ui.select replacement. Signature matches vim.ui.select.
---@param items table any[]
---@param opts table|nil {prompt?, kind?, format_item?, preview?, maxheight?, width?, row?, auto_jump_single?}
---@param on_choice function|nil fun(item, idx)
function M.pick(items, opts, on_choice)
  if vim.fn.hlexists("NockMatch") == 0 then
    highlights.setup(config.options.highlights)
  end
  opts = opts or {}
  if opts.maxheight == nil then opts.maxheight = config.options.maxheight end
  if opts.width == nil then opts.width = config.options.width end
  if opts.row == nil then opts.row = config.options.row end
  return shell.pick(items, opts, on_choice)
end

function M.close()
  return shell.close()
end

--- Restore original vim.ui.select if hijacked
function M.restore_ui_select()
  if M._orig_ui_select then
    vim.ui.select = M._orig_ui_select
    M._orig_ui_select = nil
  end
end

function M.restore_lsp()
  if M._orig_lsp_buf then
    for fn, orig in pairs(M._orig_lsp_buf) do
      if vim.lsp and vim.lsp.buf then
        if orig == nil then
          vim.lsp.buf[fn] = nil
        else
          vim.lsp.buf[fn] = orig
        end
      end
    end
    M._orig_lsp_buf = nil
  end
  if M._orig_lsp_prefix then
    for fn, orig in pairs(M._orig_lsp_prefix) do
      if vim.lsp and vim.lsp.buf then
        if orig == nil then
          vim.lsp.buf[fn] = nil
        else
          vim.lsp.buf[fn] = orig
        end
      end
    end
    M._orig_lsp_prefix = nil
  end
end

function M.restore()
  M.restore_ui_select()
  M.restore_lsp()
end

-- Standard toolset & presets for custom mode authoring (ADR-0008)
M.actions = require("nock.actions")
M.utils = require("nock.utils")
M.presets = require("nock.presets")
M.lsp = require("nock.lsp")

-- Expose for tests / introspection (high seam public API)
M._config = config
M._shell = shell
M._highlights = highlights

return M
