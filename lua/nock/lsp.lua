local actions = require("nock.actions")
local utils = require("nock.utils")

local _lsp = nil
local function get_lsp()
  if _lsp then return _lsp end
  return {
    get_clients = function(opts) return vim.lsp.get_clients(opts) end,
    buf_request_sync = function(buf, method, params, timeout)
      return vim.lsp.buf_request_sync(buf, method, params, timeout)
    end,
    make_text_document_params = function(buf)
      if vim.lsp.util.make_text_document_params then
        local p = vim.lsp.util.make_text_document_params(buf)
        if p.textDocument then return p else return { textDocument = p } end
      elseif vim.lsp.util.make_text_document_identifier then
        return { textDocument = vim.lsp.util.make_text_document_identifier(buf) }
      else
        return { textDocument = { uri = vim.uri_from_bufnr(buf) } }
      end
    end,
    make_position_params = function(win, enc)
      if vim.lsp.util.make_position_params then
        return vim.lsp.util.make_position_params(win, enc)
      end
      -- fallback
      local buf = vim.api.nvim_win_get_buf(win)
      local pos = vim.api.nvim_win_get_cursor(win)
      return {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = pos[1] - 1, character = pos[2] },
      }
    end,
    client_request = function(client, method, params, handler, bufnr)
      return client:request(method, params, handler, bufnr)
    end,
  }
end

local M = {}

local function get_cfg()
  local ok, cfg = pcall(require, "nock.config")
  if ok and cfg and cfg.options and cfg.options.lsp then return cfg.options.lsp end
  return { timeout = 1000, auto_jump_single = true, preview = true }
end

local PROMPTS = {
  ["textDocument/definition"] = "Definitions:",
  ["textDocument/declaration"] = "Declarations:",
  ["textDocument/typeDefinition"] = "Type Definitions:",
  ["textDocument/implementation"] = "Implementations:",
  ["textDocument/references"] = "References:",
}

local KIND_MAP = {
  ["textDocument/definition"] = "Definition",
  ["textDocument/declaration"] = "Declaration",
  ["textDocument/typeDefinition"] = "TypeDefinition",
  ["textDocument/implementation"] = "Implementation",
  ["textDocument/references"] = "Reference",
}

local NOTIFY_MSG = {
  ["textDocument/definition"] = "No definition found",
  ["textDocument/declaration"] = "No declaration found",
  ["textDocument/typeDefinition"] = "No type definition found",
  ["textDocument/implementation"] = "No implementation found",
  ["textDocument/references"] = "No references found",
}

local function handle_items(items, ctx)
  local method = ctx.method
  local win = ctx.win
  local bufnr = ctx.bufnr
  local prompt = ctx.prompt or PROMPTS[method] or "LSP:"
  local cfg = get_cfg()
  local auto_jump = ctx.auto_jump_single
  if auto_jump == nil then auto_jump = cfg.auto_jump_single end
  if auto_jump == nil then auto_jump = true end
  local preview = ctx.preview
  if preview == nil then preview = cfg.preview end
  if preview == nil then preview = true end

  if #items == 0 then
    local msg = NOTIFY_MSG[method] or "No results"
    pcall(vim.notify, msg, vim.log.levels.WARN)
    if ctx.on_choice then pcall(ctx.on_choice, nil, nil) end
    return
  end
  if #items == 1 and auto_jump then
    pcall(actions.edit, items[1], { win = win, buf = bufnr })
    if ctx.on_choice then pcall(ctx.on_choice, items[1], 1) end
    return
  end
  -- N>1: show picker, default select first (shell.pick handles selected_idx=1)
  local pick_opts = { prompt = prompt, preview = preview }
  -- Use shell.pick directly if available to avoid double hijack recursion
  local ok_shell, shell = pcall(require, "nock.shell")
  local on_choice = function(item, idx)
    if not item then
      if ctx.on_choice then pcall(ctx.on_choice, nil, nil) end
      return
    end
    pcall(actions.edit, item, { win = win, buf = bufnr })
    if ctx.on_choice then pcall(ctx.on_choice, item, idx) end
  end
  if ok_shell and shell and shell.pick then
    shell.pick(items, pick_opts, on_choice)
  else
    -- fallback to vim.ui.select (already hijacked)
    vim.ui.select(items, pick_opts, on_choice)
  end
end

--- Generic pick for any textDocument/* method
---@param method string LSP method
---@param params table LSP params
---@param opts table|nil { bufnr:number, win:number, prompt:string, preview:boolean, auto_jump_single:boolean, timeout:number, on_choice:function }
function M.pick_for_method(method, params, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local win = opts.win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(bufnr) then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_win_is_valid(win) then win = vim.api.nvim_get_current_win() end

  local lsp = get_lsp()
  local clients = lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    clients = lsp.get_clients()
    if #clients == 0 then
      local msg = NOTIFY_MSG[method] or "No LSP client attached"
      pcall(vim.notify, msg, vim.log.levels.WARN)
      if opts.on_choice then pcall(opts.on_choice, nil, nil) end
      return
    end
  end

  local cfg = get_cfg()
  local timeout = opts.timeout or cfg.timeout or 1000
  local use_async = true
  -- allow forcing sync via opts.sync = true (for tests)
  if opts.sync then use_async = false end

  if use_async then
    local pending = #clients
    local acc_results = {}
    local done = false
    for _, client in ipairs(clients) do
      lsp.client_request(client, method, params, function(err, result)
        pending = pending - 1
        if not err and result then
          if type(result) == "table" then
            if result.uri or result.targetUri then
              table.insert(acc_results, result)
            else
              for _, loc in ipairs(result) do
                if type(loc) == "table" then table.insert(acc_results, loc) end
              end
            end
          end
        end
        if pending <= 0 and not done then
          done = true
          local items = utils.lsp_locations_to_items(acc_results, { win = win, kind = KIND_MAP[method] or "Definition" })
          -- dedup already in utils, but ensure kind
          handle_items(items, {
            method = method,
            win = win,
            bufnr = bufnr,
            prompt = opts.prompt,
            preview = opts.preview,
            auto_jump_single = opts.auto_jump_single,
            on_choice = opts.on_choice,
          })
        end
      end, bufnr)
    end
    return
  else
    -- sync path
    local res = lsp.buf_request_sync(bufnr, method, params, timeout)
    local items = utils.lsp_locations_to_items(res, { win = win, kind = KIND_MAP[method] or "Definition" })
    handle_items(items, {
      method = method,
      win = win,
      bufnr = bufnr,
      prompt = opts.prompt,
      preview = opts.preview,
      auto_jump_single = opts.auto_jump_single,
      on_choice = opts.on_choice,
    })
  end
end

local function make_position_params_for_buf(win, bufnr)
  local lsp = get_lsp()
  local clients = lsp.get_clients({ bufnr = bufnr })
  local enc = "utf-16"
  if #clients > 0 and clients[1].offset_encoding then enc = clients[1].offset_encoding end
  return lsp.make_position_params(win, enc)
end

function M.definition(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(win)
  local params = make_position_params_for_buf(win, bufnr)
  return M.pick_for_method("textDocument/definition", params, {
    bufnr = bufnr,
    win = win,
    prompt = opts.prompt,
    preview = opts.preview,
    auto_jump_single = opts.auto_jump_single,
    timeout = opts.timeout,
    on_choice = opts.on_choice,
    sync = opts.sync,
  })
end

function M.declaration(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(win)
  local params = make_position_params_for_buf(win, bufnr)
  return M.pick_for_method("textDocument/declaration", params, {
    bufnr = bufnr,
    win = win,
    prompt = opts.prompt,
    preview = opts.preview,
    auto_jump_single = opts.auto_jump_single,
    timeout = opts.timeout,
    on_choice = opts.on_choice,
    sync = opts.sync,
  })
end

function M.type_definition(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(win)
  local params = make_position_params_for_buf(win, bufnr)
  return M.pick_for_method("textDocument/typeDefinition", params, {
    bufnr = bufnr,
    win = win,
    prompt = opts.prompt,
    preview = opts.preview,
    auto_jump_single = opts.auto_jump_single,
    timeout = opts.timeout,
    on_choice = opts.on_choice,
    sync = opts.sync,
  })
end
-- alias
M.typeDefinition = M.type_definition

function M.implementation(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(win)
  local params = make_position_params_for_buf(win, bufnr)
  return M.pick_for_method("textDocument/implementation", params, {
    bufnr = bufnr,
    win = win,
    prompt = opts.prompt,
    preview = opts.preview,
    auto_jump_single = opts.auto_jump_single,
    timeout = opts.timeout,
    on_choice = opts.on_choice,
    sync = opts.sync,
  })
end

function M.references(opts)
  opts = opts or {}
  local win = opts.win or vim.api.nvim_get_current_win()
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(win)
  local params = make_position_params_for_buf(win, bufnr)
  params.context = { includeDeclaration = opts.includeDeclaration ~= false }
  return M.pick_for_method("textDocument/references", params, {
    bufnr = bufnr,
    win = win,
    prompt = opts.prompt,
    preview = opts.preview,
    auto_jump_single = opts.auto_jump_single,
    timeout = opts.timeout,
    on_choice = opts.on_choice,
    sync = opts.sync,
  })
end

-- Test seam
function M._set_lsp(adapter) _lsp = adapter end
function M._get_lsp() return get_lsp() end
function M._reset_lsp() _lsp = nil end

return M
