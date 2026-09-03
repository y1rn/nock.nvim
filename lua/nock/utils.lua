local M = {}

-- LSP SymbolKind map (LSP specification 3.17: 1..26)
local LSP_SYMBOL_KINDS = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

--- Convert LSP SymbolKind number to name.
---@param kind number|string|nil
---@return string
function M.lsp_symbol_kind_name(kind)
  if type(kind) == "string" then
    return kind
  end
  if type(kind) == "number" then
    return LSP_SYMBOL_KINDS[kind] or "Symbol"
  end
  return "Symbol"
end

--- Convert an LSP SymbolInformation / DocumentSymbol / Location to a standard Item.
---@param sym table
---@param opts table|nil optional { uri = string, bufnr = number, default_path = string }
---@return table Item
function M.lsp_symbol_to_item(sym, opts)
  opts = opts or {}
  local name = sym.name or sym.text or "Symbol"
  local kind_name = M.lsp_symbol_kind_name(sym.kind)
  local detail = sym.detail or sym.containerName or nil
  -- Icon: global, enabled check, supports string kind and number kind
  local icon = nil
  local ok_cfg, cfg = pcall(require, "nock.config")
  if ok_cfg and cfg.options and cfg.options.icons and cfg.options.icons.enabled then
    local sym_icons = cfg.options.icons.symbols or {}
    icon = sym_icons[kind_name] or sym_icons[sym.kind] or (type(sym.kind)=="number" and sym_icons[tostring(sym.kind)]) or nil
  end

  local path = opts.default_path or ""
  local lnum = 1
  local col = 0
  local end_lnum = nil
  local end_col = nil

  -- SymbolInformation has sym.location = { uri, range = { start = { line, character } } }
  if sym.location then
    local loc = sym.location
    if loc.uri then
      path = vim.uri_to_fname(loc.uri)
    end
    if loc.range and loc.range.start then
      lnum = (loc.range.start.line or 0) + 1
      local character = loc.range.start.character or 0
      if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
        local line = vim.api.nvim_buf_get_lines(opts.bufnr, lnum - 1, lnum, false)[1] or ""
        local ok, bcol = pcall(vim.str_byteindex, line, character, false)
        col = ok and bcol or character
      else
        col = character
      end
      if loc.range["end"] then
        end_lnum = (loc.range["end"].line or 0) + 1
        local ec = loc.range["end"].character or 0
        if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
          local eline = vim.api.nvim_buf_get_lines(opts.bufnr, end_lnum - 1, end_lnum, false)[1] or ""
          local ok2, ecol = pcall(vim.str_byteindex, eline, ec, false)
          end_col = ok2 and ecol or ec
        else
          end_col = ec
        end
      end
    end
  -- DocumentSymbol has sym.range or sym.selectionRange
  elseif sym.selectionRange or sym.range then
    local rng = sym.selectionRange or sym.range
    if rng and rng.start then
      lnum = (rng.start.line or 0) + 1
      local character = rng.start.character or 0
      if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
        local line = vim.api.nvim_buf_get_lines(opts.bufnr, lnum - 1, lnum, false)[1] or ""
        local ok, bcol = pcall(vim.str_byteindex, line, character, false)
        col = ok and bcol or character
      else
        col = character
      end
      if rng["end"] then
        end_lnum = (rng["end"].line or 0) + 1
        local ec = rng["end"].character or 0
        if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
          local eline = vim.api.nvim_buf_get_lines(opts.bufnr, end_lnum - 1, end_lnum, false)[1] or ""
          local ok2, ecol = pcall(vim.str_byteindex, eline, ec, false)
          end_col = ok2 and ecol or ec
        else
          end_col = ec
        end
      end
    end
  end

  local cwd = vim.fn.getcwd()
  local display_path = path
  if path:sub(1, #cwd) == cwd then
    display_path = path:sub(#cwd + 2)
  end

  local loc = { path = path, lnum = lnum, col = col }
  if end_lnum then loc.end_lnum = end_lnum end
  if end_col then loc.end_col = end_col end

  return {
    label = name,
    filter_text = name,
    kind = kind_name,
    icon = icon,
    detail = detail or (display_path ~= "" and display_path or nil),
    location = loc,
    bufnr = opts.bufnr,
    value = sym,
  }
end

local function char_to_byte(bufnr, win, lnum, character)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local ok, bcol = pcall(vim.str_byteindex, line, character, false)
    return ok and bcol or character
  elseif win and vim.api.nvim_win_is_valid(win) then
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) then
      local ok2, lines = pcall(vim.api.nvim_buf_get_lines, buf, lnum - 1, lnum, false)
      if ok2 and lines and lines[1] then
        local ok3, bcol = pcall(vim.str_byteindex, lines[1], character, false)
        return ok3 and bcol or character
      end
    end
  end
  return character
end

--- Convert LSP Location / LocationLink to a standard Item.
--- Handles both Location {uri, range} and LocationLink {targetUri, targetRange, targetSelectionRange}.
---@param loc table LSP Location or LocationLink
---@param opts table|nil optional { bufnr:number, win:number, default_path:string, kind:string }
---@return table Item
function M.lsp_location_to_item(loc, opts)
  opts = opts or {}
  local uri = loc.uri or loc.targetUri or opts.default_path or ""
  local range = loc.targetSelectionRange or loc.targetRange or loc.range
  local kind_name = opts.kind or "Definition"

  local icon = nil
  local ok_cfg, cfg = pcall(require, "nock.config")
  local sym_icons = ok_cfg and cfg.options and cfg.options.icons and cfg.options.icons.symbols or {}
  icon = sym_icons[kind_name] or sym_icons[loc.kind]
  if not icon and kind_name then
    local defaults = ok_cfg and cfg.defaults and cfg.defaults.icons and cfg.defaults.icons.symbols or {}
    icon = defaults[kind_name] or defaults[kind_name:lower()]
  end
  local path = ""
  if uri ~= "" then
    local ok, fname = pcall(vim.uri_to_fname, uri)
    path = ok and fname or uri
  elseif opts.default_path then
    path = opts.default_path
  end

  local lnum, col, end_lnum, end_col = 1, 0, nil, nil
  if range and range.start then
    lnum = (range.start.line or 0) + 1
    col = char_to_byte(opts.bufnr, opts.win, lnum, range.start.character or 0)
    if range["end"] then
      end_lnum = (range["end"].line or 0) + 1
      end_col = char_to_byte(opts.bufnr, opts.win, end_lnum, range["end"].character or 0)
    end
  end

  local cwd = vim.fn.getcwd()
  local display_path = path
  if path:sub(1, #cwd) == cwd then
    display_path = path:sub(#cwd + 2)
  end

  local filename = path ~= "" and vim.fn.fnamemodify(path, ":t") or "definition"
  local label = filename .. ":" .. lnum
  local detail = display_path ~= "" and display_path or path

  local loc_tbl = { path = path, lnum = lnum, col = col }
  if end_lnum then loc_tbl.end_lnum = end_lnum end
  if end_col then loc_tbl.end_col = end_col end

  return {
    label = label,
    filter_text = display_path .. " " .. label,
    kind = kind_name,
    icon = icon,
    detail = detail,
    location = loc_tbl,
    bufnr = opts.bufnr,
    value = loc,
  }
end

--- Convert mixed LSP definition results to Item[].
--- Accepts: nil | Location | Location[] | LocationLink[] | buf_request_sync result map { [client_id] = {result, error} }
---@param input table|nil
---@param opts table|nil optional { bufnr:number, win:number, default_path:string, kind:string }
---@return table Item[]
function M.lsp_locations_to_items(input, opts)
  opts = opts or {}
  if not input then return {} end

  local locs = {}

  -- Detect buf_request_sync map: keys are client_id numbers, values have .result
  local is_sync_map = false
  if type(input) == "table" then
    for k, v in pairs(input) do
      if type(v) == "table" and (v.result ~= nil or v.error ~= nil) and type(k) == "number" then
        is_sync_map = true
        break
      end
    end
  end

  if is_sync_map then
    for _, cr in pairs(input) do
      if cr.result and type(cr.result) == "table" then
        local r = cr.result
        -- single Location/LocationLink has uri/targetUri
        if r.uri or r.targetUri then
          table.insert(locs, r)
        elseif type(r) == "table" then
          -- array of locations
          for _, l in ipairs(r) do
            if type(l) == "table" then table.insert(locs, l) end
          end
        end
      end
    end
  elseif type(input) == "table" and (input.uri or input.targetUri) then
    -- single Location
    locs = { input }
  elseif type(input) == "table" then
    -- assume Location[]
    for _, l in ipairs(input) do
      if type(l) == "table" then table.insert(locs, l) end
    end
  end

  -- Deduplicate by path:lnum:col
  local seen = {}
  local items = {}
  for _, loc in ipairs(locs) do
    local item = M.lsp_location_to_item(loc, opts)
    local key = (item.location.path or "") .. "\0" .. tostring(item.location.lnum) .. "\0" .. tostring(item.location.col)
    if not seen[key] then
      seen[key] = true
      table.insert(items, item)
    end
  end
  return items
end

local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warn",
  [vim.diagnostic.severity.INFO] = "Info",
  [vim.diagnostic.severity.HINT] = "Hint",
}

function M.format_diagnostic(diag, opts)
  opts = opts or {}
  local sev = diag.severity or vim.diagnostic.severity.ERROR
  local kind = SEVERITY_NAMES[sev] or "Diagnostic"
  local msg = (diag.message or ""):gsub("\n", " ")
  local lnum = (diag.lnum or 0) + 1
  local col = diag.col or 0
  local end_lnum = diag.end_lnum ~= nil and (diag.end_lnum + 1) or nil
  local end_col = diag.end_col
  -- Icon for diagnostics
  local icon = nil
  local ok_cfg, cfg = pcall(require, "nock.config")
  if ok_cfg and cfg.options and cfg.options.icons and cfg.options.icons.enabled then
    local diag_icons = cfg.options.icons.diagnostics or {}
    icon = diag_icons[kind] or diag_icons[sev] or (type(sev)=="number" and diag_icons[tostring(sev)]) or nil
  end

  local path = opts.default_path or ""
  if diag.bufnr and vim.api.nvim_buf_is_valid(diag.bufnr) then
    path = vim.api.nvim_buf_get_name(diag.bufnr)
  end

  local cwd = vim.fn.getcwd()
  local rel_path = path
  if path:sub(1, #cwd) == cwd then
    rel_path = path:sub(#cwd + 2)
  end

  local detail = string.format("%s:%d:%d", rel_path ~= "" and rel_path or "buffer", lnum, col)

  local loc = { path = path, lnum = lnum, col = col }
  if end_lnum and end_col ~= nil then
    loc.end_lnum = end_lnum
    loc.end_col = end_col
  end

  return {
    label = msg,
    filter_text = msg .. " " .. (diag.source or "") .. " " .. rel_path,
    kind = kind,
    icon = icon,
    detail = detail,
    location = loc,
    bufnr = diag.bufnr,
    value = diag,
  }
end

return M
