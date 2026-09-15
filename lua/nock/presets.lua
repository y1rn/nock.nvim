local actions = require("nock.actions")
local utils = require("nock.utils")
-- LSP adapter seam: real vs fake for tests (two adapters = real seam)
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
    make_text_document_identifier = function(buf)
      if vim.lsp.util.make_text_document_identifier then
        return vim.lsp.util.make_text_document_identifier(buf)
      else
        return { uri = vim.uri_from_bufnr(buf) }
      end
    end,
    client_request = function(client, method, params, handler, bufnr)
      return client:request(method, params, handler, bufnr)
    end,
  }
end

local M = {}

--- Ex commands preset (">").
---@param opts table|nil optional overrides
---@return table Mode specification
function M.commands(opts)
  opts = opts or {}
  return {
    prefix = opts.prefix ~= nil and opts.prefix or ">",
    keymap = opts.keymap ~= nil and opts.keymap or "<C-S-p>",
    show_on_open = opts.show_on_open ~= nil and opts.show_on_open or true,
    ---@diagnostic disable-next-line: unused-local
    provider = function(_query, ctx, callback)
      if type(callback) ~= "function" then return nil end
      local items = {}
      local cmds = vim.api.nvim_get_commands({})
      local buf_cmds = (ctx and ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) and vim.api.nvim_buf_get_commands(ctx.buf, {}) or {}
      for name, def in pairs(cmds) do
        table.insert(items, {
          label = ":" .. name,
          filter_text = name,
          value = name,
          detail = def.definition or def.desc or "",
          kind = "Command",
        })
      end
      for name, def in pairs(buf_cmds) do
        table.insert(items, {
          label = ":" .. name,
          filter_text = name,
          value = name,
          detail = (def.definition or def.desc or "") .. " [buffer]",
          kind = "Command",
        })
      end
      vim.schedule(function()
        if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
        callback(items)
      end)
      return nil, function() end
    end,
    action = opts.action or actions.cmd,
    preview = opts.preview or false,
  }
end

--- LSP Document Symbols preset ("@").
---@param opts table|nil optional overrides
---@return table Mode specification
function M.lsp_document_symbols(opts)
  opts = opts or {}
  return {
    prefix = opts.prefix ~= nil and opts.prefix or "@",
    keymap = opts.keymap ~= nil and opts.keymap or "<leader>ss",
    _lsp_target = "document_symbol",
    provider = function(query, ctx, callback)
      if type(callback) ~= "function" then return nil end
      local lsp = get_lsp()
      local buf = (ctx and ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) and ctx.buf or vim.api.nvim_get_current_buf()
      local clients = lsp.get_clients({ bufnr = buf })
      if #clients == 0 then
        clients = lsp.get_clients()
        if #clients == 0 then
          -- Empty source, not an Item: notify on empty query, silent {} on typed queries.
          local empty_query = query == nil or query == ""
          vim.schedule(function()
            if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
            if empty_query then
              vim.notify("No LSP client attached", vim.log.levels.INFO)
            end
            callback({})
          end)
          return nil, function() end
        end
      end
      local pending = #clients
      local accumulated = {}
      local function flatten_to_acc(syms)
        for _, sym in ipairs(syms) do
          table.insert(accumulated, utils.lsp_symbol_to_item(sym, { bufnr = buf, default_path = ctx and ctx.file }))
          if sym.children and type(sym.children) == "table" and #sym.children > 0 then
            flatten_to_acc(sym.children)
          end
        end
      end
      for _, client in ipairs(clients) do
        lsp.client_request(client, "textDocument/documentSymbol", lsp.make_text_document_params(buf), function(err, result)
          if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
          pending = pending - 1
          if not err and result and type(result) == "table" then
            if result[1] and result[1].name then
              flatten_to_acc(result)
            elseif result[1] and result[1].result then
              for _, r in pairs(result) do if r.result then flatten_to_acc(r.result) end end
            end
          end
          if pending <= 0 then
            callback(accumulated)
          end
        end, buf)
      end
      return nil, function() end
    end,
    action = opts.action or actions.edit,
    preview = opts.preview ~= nil and opts.preview or true,
  }
end

--- LSP Workspace Symbols preset ("#").
function M.lsp_workspace_symbols(opts)
  opts = opts or {}
  return {
    prefix = opts.prefix ~= nil and opts.prefix or "#",
    _lsp_target = "workspace_symbol",
    keymap = opts.keymap ~= nil and opts.keymap or "<leader>sw",
    show_on_open = opts.show_on_open or false,
    incremental = false,
    provider = function(query, ctx, callback)
      if type(callback) ~= "function" then return nil end
      if query == "" then
        vim.schedule(function()
          if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
          callback({})
        end)
        return nil, function() end
      end
      local lsp = get_lsp()
      local buf = (ctx and ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) and ctx.buf or 0
      local clients = lsp.get_clients({ bufnr = buf })
      if #clients == 0 then
        clients = lsp.get_clients()
      end
      -- Only reachable with a non-empty query (empty query returns {} above):
      -- the user asked, but there is no source. Notify and keep the list empty.
      if #clients == 0 then
        vim.schedule(function()
          if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
          vim.notify("No workspace client", vim.log.levels.INFO)
          callback({})
        end)
        return nil, function() end
      end

      local pending = #clients
      local accumulated = {}

      for _, client in ipairs(clients) do
        lsp.client_request(client, "workspace/symbol", { query = query }, function(err, result)
          if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
          pending = pending - 1
          if not err and result and type(result) == "table" then
            for _, sym in ipairs(result) do
              table.insert(accumulated, utils.lsp_symbol_to_item(sym, { default_path = ctx and ctx.file }))
            end
          end
          if pending <= 0 then
            callback(accumulated)
          end
        end, buf)
      end
      return nil, function() end
    end,
    action = opts.action or actions.edit,
    preview = opts.preview ~= nil and opts.preview or true,
  }
end

--- Diagnostics preset ("!").
---@param opts table|nil optional { workspace = boolean }
---@return table Mode specification
function M.diagnostics(opts)
  opts = opts or {}
  return {
    prefix = opts.prefix ~= nil and opts.prefix or "!",
    keymap = opts.keymap ~= nil and opts.keymap or "<leader>sd",
    show_on_open = opts.show_on_open ~= nil and opts.show_on_open or true,
    provider = function(query, ctx, callback)
      if type(callback) ~= "function" then return nil end
      local diags
      if opts.workspace then
        diags = vim.diagnostic.get()
      else
        local buf = ctx and ctx.buf
        diags = (buf and vim.api.nvim_buf_is_valid(buf)) and vim.diagnostic.get(buf) or vim.diagnostic.get()
      end
      local items = {}
      for _, d in ipairs(diags or {}) do
        local sev = d.severity or vim.diagnostic.severity.ERROR
        if sev == vim.diagnostic.severity.WARN or sev == vim.diagnostic.severity.HINT then
          -- skip HINT/WARN per user request "clear all"
        else
          table.insert(items, utils.format_diagnostic(d, { default_path = ctx and ctx.file }))
        end
      end
      if #items == 0 and (query == nil or query == "") then
        -- Empty source, not an Item: notify and leave the list empty, so
        -- Enter on the empty list takes the shell._commit empty path (dismiss).
        vim.schedule(function()
          if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
          vim.notify("No diagnostics", vim.log.levels.INFO)
          callback({})
        end)
        return nil, function() end
      end
      vim.schedule(function()
        if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
        callback(items)
      end)
      return nil, function() end
    end,
    action = opts.action or actions.edit,
    preview = opts.preview ~= nil and opts.preview or true,
  }
end

--- Go to line preset (":").
---@param opts table|nil optional overrides
---@return table Mode specification
function M.lines(opts)
  opts = opts or {}
  return {
    prefix = opts.prefix ~= nil and opts.prefix or ":",
    keymap = opts.keymap ~= nil and opts.keymap or "<leader>sl",
    show_on_open = opts.show_on_open ~= nil and opts.show_on_open or true,
    ---@diagnostic disable-next-line: unused-local
    provider = function(_query, ctx, callback)
      if type(callback) ~= "function" then return nil end
      local buf = (ctx and ctx.buf and vim.api.nvim_buf_is_valid(ctx.buf)) and ctx.buf or vim.api.nvim_get_current_buf()
      if not vim.api.nvim_buf_is_valid(buf) then
        vim.schedule(function()
          if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
          callback({})
        end)
        return nil, function() end
      end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local items = {}
      for i, l in ipairs(lines) do
        local trimmed = vim.trim(l)
        if trimmed ~= "" or #lines <= 100 then
          table.insert(items, {
            label = string.format("%4d: %s", i, l),
            filter_text = string.format("%d %s", i, l),
            kind = "Line",
            detail = string.format("line %d", i),
            location = { path = ctx and ctx.file or "", lnum = i, col = 0 },
            bufnr = buf,
          })
        end
      end
      vim.schedule(function()
        if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
        callback(items)
      end)
      return nil, function() end
    end,
    action = opts.action or actions.set_cursor,
    preview = opts.preview ~= nil and opts.preview or true,
  }
end

-- Test seam: inject fake LSP adapter
function M._set_lsp(adapter) _lsp = adapter end
function M._get_lsp() return get_lsp() end
function M._reset_lsp() _lsp = nil end

return M
