local M = {}

local _snap_by_cwd = {}
local _cached_gitignore = nil
local _debounce_timer = nil
local _pending_cwds = {}

-- FS adapter seam: injectable for tests, default delegates to vim natives.
-- Async-only (Q6): enumeration runs off the main loop via system_async (vim.system).
local _fs = nil
local function get_fs()
  if _fs then
    -- Backfill system_async for adapters injected before the async cutover.
    if _fs.system_async == nil and vim.system ~= nil then
      _fs.system_async = function(args, opts, on_exit) return vim.system(args, opts, on_exit) end
    end
    return _fs
  end
  return {
    executable = function(cmd) return vim.fn.executable(cmd) end,
    systemlist = function(args) return vim.fn.systemlist(args) end,
    shell_error = function() return vim.v.shell_error end,
    fs_find = function(...) return vim.fs.find(...) end,
    glob = function(pat) return vim.fn.glob(pat, false, true) end,
    isdirectory = function(p) return vim.fn.isdirectory(p) end,
    filereadable = function(p) return vim.fn.filereadable(p) end,
    readfile = function(p) return vim.fn.readfile(p) end,
    getftime = function(p) return vim.fn.getftime(p) end,
    system_async = function(args, opts, on_exit) return vim.system(args, opts, on_exit) end,
  }
end
local function get_gitignore_enabled()
  local cfg = require("nock.config")
  local mode = cfg.options.modes and cfg.options.modes.files and cfg.options.modes.files.gitignore
  if mode ~= nil then return mode == true end
  local top = cfg.options.files and cfg.options.files.gitignore
  if top ~= nil then return top == true end
  return true
end
local function parse_gitignore_lines(lines)
  local out = {}
  for _, raw in ipairs(lines) do
    local line = raw:match("^%s*(.-)%s*$") or ""
    if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "!" then
      if line:sub(-1) == "/" then line = line:sub(1, -2) end
      if line ~= "" then table.insert(out, line) end
    end
  end
  return out
end
local function get_gitignore_patterns()
  if not get_gitignore_enabled() then return {} end
  local cwd = vim.fn.getcwd()
  local path = cwd .. "/.gitignore"
  local fs = get_fs()
  local mtime = -1
  pcall(function() mtime = fs.getftime(path) end)
  if _cached_gitignore and _cached_gitignore.cwd == cwd and _cached_gitignore.mtime == mtime then
    return _cached_gitignore.patterns
  end
  local patterns = {}
  local readable = 0
  pcall(function() readable = fs.filereadable(path) end)
  if readable == 1 then
    local ok, lines = pcall(fs.readfile, path)
    if ok and type(lines) == "table" then patterns = parse_gitignore_lines(lines) end
  end
  _cached_gitignore = { cwd = cwd, mtime = mtime, patterns = patterns }
  return patterns
end
local function get_ignore()
  local cfg = require("nock.config")
  local defaults = { ".git", "node_modules", ".DS_Store" }
  local explicit = nil
  local top = cfg.options.files and cfg.options.files.ignore
  local mode = cfg.options.modes and cfg.options.modes.files and cfg.options.modes.files.ignore
  if mode ~= nil then
    if type(mode) == "table" then explicit = mode end
  elseif top ~= nil then
    if type(top) == "table" then explicit = top end
  else
    explicit = defaults
  end
  if not explicit then explicit = defaults end
  local gi = get_gitignore_patterns()
  if #gi == 0 then return explicit end
  local seen = {}
  local out = {}
  for _, p in ipairs(explicit) do
    if not seen[p] then seen[p] = true; table.insert(out, p) end
  end
  for _, p in ipairs(gi) do
    if not seen[p] then seen[p] = true; table.insert(out, p) end
  end
  return out
end

local function get_fd_cmd()
  local cfg = require("nock.config")
  local files_cfg = cfg.options.files or {}
  local mode_cfg = (cfg.options.modes and cfg.options.modes.files) or {}
  if mode_cfg.fd_cmd ~= nil then
    if mode_cfg.fd_cmd == false then
      return nil
    end
    if type(mode_cfg.fd_cmd) == "string" and mode_cfg.fd_cmd ~= "" then
      return mode_cfg.fd_cmd
    end
    return nil
  end
  if files_cfg.fd_cmd ~= nil then
    if files_cfg.fd_cmd == false then
      return nil
    end
    if type(files_cfg.fd_cmd) == "string" and files_cfg.fd_cmd ~= "" then
      return files_cfg.fd_cmd
    end
  end
  local fs = get_fs()
  if fs.executable("fd") == 1 then
    return "fd"
  end
  if fs.executable("fdfind") == 1 then
    return "fdfind"
  end
  return nil
end

local function has_segment(path, pat)
  if path == pat then
    return true
  end
  if path:find("/" .. pat .. "/", 1, true) then
    return true
  end
  if path:sub(1, #pat + 1) == pat .. "/" then
    return true
  end
  if #path >= #pat + 1 and path:sub(-(#pat + 1)) == "/" .. pat then
    return true
  end
  return false
end

local function is_ignored_path(path, ignore)
  for _, pat in ipairs(ignore) do
    if pat:find("%*") or pat:find("%?") then
      local ok, reg = pcall(vim.fn.glob2regpat, pat)
      if ok and reg then
        if vim.fn.match(path, reg) ~= -1 then
          return true
        end
        local base = vim.fn.fnamemodify(path, ":t")
        if vim.fn.match(base, reg) ~= -1 then
          return true
        end
      end
    else
      local basename = vim.fn.fnamemodify(path, ":t")
      if basename == pat then
        return true
      end
      if has_segment(path, pat) then
        return true
      end
      if pat == ".DS_Store" and path:find(pat, 1, true) then
        return true
      end
    end
  end
  return false
end

local function get_open_buffers()
  local cwd = vim.fn.getcwd()
  local items = {}
  local seen = {}
  local cur_buf = vim.api.nvim_get_current_buf()

  local info_list = vim.fn.getbufinfo({ buflisted = 1 })
  local alt_buf = vim.fn.bufnr("#")
  -- Sort by: alternate buffer first, then lastused timestamp descending, then bufnr descending
  table.sort(info_list, function(a, b)
    if alt_buf and alt_buf > 0 then
      if a.bufnr == alt_buf and b.bufnr ~= alt_buf then
        return true
      elseif b.bufnr == alt_buf and a.bufnr ~= alt_buf then
        return false
      end
    end
    local la = a.lastused or 0
    local lb = b.lastused or 0
    if la ~= lb then
      return la > lb
    end
    return (a.bufnr or 0) > (b.bufnr or 0)
  end)

  for _, info in ipairs(info_list) do
    local b = info.bufnr
    -- Exclude current active buffer (ADR-0006 Option C)
    if b ~= cur_buf and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name and name ~= "" then
        local rel = name
        if name:sub(1, #cwd) == cwd then
          rel = name:sub(#cwd + 2)
        end
        if not seen[rel] then
          seen[rel] = true
          table.insert(items, {
            label = rel,
            value = rel,
            detail = rel,
            bufnr = b,
            location = { path = rel, lnum = 1, col = 0 },
          })
        end
      end
    end
  end

  return items
end

local function make_builder(ignore)
  local items = {}
  local seen = {}
  local function add_path(path, bufnr)
    if not path or path == "" then return end
    if is_ignored_path(path, ignore) then return end
    if seen[path] then return end
    seen[path] = true
    table.insert(items, {
      label = path,
      value = path,
      detail = path,
      bufnr = bufnr,
      location = { path = path, lnum = 1, col = 0 },
    })
  end
  return items, add_path
end

local function split_lines(s)
  local out = {}
  if type(s) ~= "string" or s == "" then return out end
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then table.insert(out, line) end
  end
  return out
end

local function to_rel(p, cwd)
  if p:sub(1, 2) == "./" then p = p:sub(3) end
  if p:sub(1, #cwd + 1) == cwd .. "/" then p = p:sub(#cwd + 2) end
  return p
end

local function enumerate_fallback_async(cwd, ignore, buffers, ctx, callback)
  local fs = get_fs()
  local cancelled = function()
    return ctx and ctx.is_cancelled and ctx.is_cancelled()
  end
  local cmd = nil
  if fs.executable("rg") == 1 then
    cmd = { "rg", "--files" }
  else
    cmd = { "find", ".", "-type", "f" }
  end
  local job = fs.system_async(cmd, { cwd = cwd, text = true }, function(obj)
    vim.schedule(function()
      if cancelled() then return end
      if vim.fn.getcwd() ~= cwd then return end
      local items, add_path = make_builder(ignore)
      for _, b in ipairs(buffers) do add_path(b.value, b.bufnr) end
      for _, p in ipairs(split_lines(obj and obj.stdout or "")) do add_path(to_rel(p, cwd)) end
      if #items == 0 then
        for _, b in ipairs(buffers) do table.insert(items, b) end
      else
        _snap_by_cwd[cwd] = items
      end
      callback(items)
    end)
  end)
  return function()
    pcall(function() if job and job.kill then job:kill("TERM") end end)
  end
end

local function enumerate_async(cwd, ignore, fd_cmd, buffers, ctx, callback)
  local fs = get_fs()
  local cancelled = function()
    return ctx and ctx.is_cancelled and ctx.is_cancelled()
  end
  local function finish_with_paths(paths)
    local items, add_path = make_builder(ignore)
    for _, b in ipairs(buffers) do add_path(b.value, b.bufnr) end
    for _, p in ipairs(paths) do add_path(to_rel(p, cwd)) end
    if #items > 0 then _snap_by_cwd[cwd] = items end
    if cancelled() then return end
    if vim.fn.getcwd() ~= cwd then return end
    callback(items)
  end
  if fs.system_async then
    if fd_cmd then
      local fd_args = { fd_cmd, "--type", "f", "--strip-cwd-prefix" }
      for _, pat in ipairs(ignore) do
        table.insert(fd_args, "--exclude")
        table.insert(fd_args, pat)
      end
      local job = nil
      job = fs.system_async(fd_args, { cwd = cwd, text = true }, function(obj)
        vim.schedule(function()
          if cancelled() then return end
          local code = obj and obj.code or 1
          local paths = split_lines(obj and obj.stdout or "")
          if code == 0 and #paths > 0 then
            finish_with_paths(paths)
            return
          end
          enumerate_fallback_async(cwd, ignore, buffers, ctx, callback)
        end)
      end)
      return function()
        pcall(function() if job and job.kill then job:kill("TERM") end end)
      end
    end
    return enumerate_fallback_async(cwd, ignore, buffers, ctx, callback)
  end
  vim.schedule(function()
    if cancelled() then return end
    local items, add_path = make_builder(ignore)
    for _, b in ipairs(buffers) do add_path(b.value, b.bufnr) end
    local ok, found = pcall(fs.fs_find, function(name, _path)
      for _, pat in ipairs(ignore) do if name == pat then return false end end
      return true
    end, { path = cwd, type = "file", limit = math.huge })
    if ok and type(found) == "table" then
      for _, f in ipairs(found) do add_path(to_rel(f, cwd)) end
    else
      local globbed = fs.glob(cwd .. "/**/*")
      for _, f in ipairs(globbed or {}) do
        if fs.isdirectory(f) == 0 then add_path(to_rel(f, cwd)) end
      end
    end
    if #items > 0 then _snap_by_cwd[cwd] = items end
    if cancelled() then return end
    if vim.fn.getcwd() ~= cwd then return end
    callback(items)
  end)
  return function() end
end

function M.provider(query, ctx, callback)
  if type(callback) ~= "function" then return nil end
  ctx = ctx or {}
  local cfg = require("nock.config")
  local show_all = false
  local mode_spec = cfg.options.modes and cfg.options.modes.files or {}
  if mode_spec.show ~= nil then
    show_all = mode_spec.show
  else
    show_all = cfg.options.files.show or false
  end
  local cwd = vim.fn.getcwd()
  local cancelled = function()
    return ctx and ctx.is_cancelled and ctx.is_cancelled()
  end
  if query == nil or query == "" then
    if not show_all then
      local bufs = get_open_buffers()
      vim.schedule(function()
        if cancelled() then return end
        callback(bufs)
      end)
      return nil, function() end
    end
    -- Snapshot hit: deliver immediately as final, no enumeration, no loading.
    -- Freshness comes from autocmd invalidation (BufWritePost/BufNewFile/
    -- BufDelete/BufAdd/DirChanged); reopen with no changes is instant.
    local snap = _snap_by_cwd[cwd]
    if snap then
      vim.schedule(function()
        if cancelled() then return end
        if vim.fn.getcwd() ~= cwd then return end
        callback(snap)
      end)
      return nil, function() end
    end
    local bufs = get_open_buffers()
    vim.schedule(function()
      if cancelled() then return end
      if vim.fn.getcwd() ~= cwd then return end
      -- Non-final: full enumeration still in flight; filter keeps pending
      -- so the Loading Indicator grace timer survives the slow load.
      callback(bufs, { more = true })
    end)
    local ignore = get_ignore()
    local fd_cmd = get_fd_cmd()
    return nil, enumerate_async(cwd, ignore, fd_cmd, bufs, ctx, callback)
  else
    local snap = _snap_by_cwd[cwd]
    if snap then
      vim.schedule(function()
        if cancelled() then return end
        if vim.fn.getcwd() ~= cwd then return end
        callback(snap)
      end)
      return nil, function() end
    end
    local ignore = get_ignore()
    local fd_cmd = get_fd_cmd()
    local bufs = get_open_buffers()
    return nil, enumerate_async(cwd, ignore, fd_cmd, bufs, ctx, callback)
  end
end


function M.action(item, ctx)
  if not item then
    return
  end
  local win = ctx and ctx.win or vim.api.nvim_get_current_win()
  local bufnr = item.bufnr
  local path = (item.location and item.location.path) or item.value or item.label
  local lnum = (item.location and item.location.lnum) or 1
  local col = (item.location and item.location.col) or 0

  if not bufnr and path then
    local cwd = vim.fn.getcwd()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local bname = vim.api.nvim_buf_get_name(b)
        if bname == path or bname == cwd .. "/" .. path then
          bufnr = b
          break
        end
      end
    end
  end

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_cmd, { cmd = "buffer", args = { tostring(bufnr) } }, {})
      elseif path then
        local ok = pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
        if not ok then
          pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
        end
      end
      if lnum and lnum > 1 then
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
      end
    end)
  else
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_cmd, { cmd = "buffer", args = { tostring(bufnr) } }, {})
    elseif path then
      pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
    end
    if lnum and lnum > 1 then
      pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col })
    end
  end
end
M._is_ignored_path = is_ignored_path
M._has_segment = has_segment
local function _do_invalidate(cwd)
  if cwd and type(cwd) == "string" and cwd ~= "" then
    _snap_by_cwd[cwd] = nil
  else
    _snap_by_cwd = {}
  end
  _cached_gitignore = nil
end
function M.invalidate(cwd)
  if cwd and type(cwd) == "string" and cwd ~= "" then
    _do_invalidate(cwd)
  else
    _do_invalidate(nil)
  end
  if _debounce_timer then
    pcall(function() _debounce_timer:stop() end)
    pcall(function() _debounce_timer:close() end)
    _debounce_timer = nil
    _pending_cwds = {}
  end
end
M._reset_cache = M.invalidate
-- Debounced schedule for autocmd (150ms, ignore-filtered)
function M._schedule_invalidate(fname)
  local cwd = vim.fn.getcwd()
  if fname and fname ~= "" then
    -- filter ignored paths (Q2)
    local ok, ignore = pcall(get_ignore)
    if ok and type(ignore) == "table" and #ignore > 0 then
      local rel = fname
      if fname:sub(1, #cwd) == cwd then
        rel = fname:sub(#cwd + 2)
      end
      if is_ignored_path(fname, ignore) or is_ignored_path(rel, ignore) then
        return
      end
    end
    _pending_cwds[cwd] = true
  else
    _pending_cwds[cwd] = true
  end
  if _debounce_timer then return end
  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    for c in pairs(_pending_cwds) do _do_invalidate(c) end
    _pending_cwds = {}
    return
  end
  _debounce_timer = uv.new_timer()
  _debounce_timer:start(150, 0, vim.schedule_wrap(function()
    local timer = _debounce_timer
    _debounce_timer = nil
    local pending = _pending_cwds
    _pending_cwds = {}
    if timer then pcall(function() timer:stop() end); pcall(function() timer:close() end) end
    local has_any = false
    for c in pairs(pending) do has_any = true; _do_invalidate(c) end
    if not has_any then _do_invalidate(nil) end
  end))
end
M._set_fs = function(adapter) _fs = adapter; _snap_by_cwd = {}; _cached_gitignore = nil
  if _debounce_timer then pcall(function() _debounce_timer:stop() end); pcall(function() _debounce_timer:close() end); _debounce_timer = nil; _pending_cwds = {} end
end
M._get_fs = get_fs
M._get_snap_by_cwd = function() return _snap_by_cwd end

return M
