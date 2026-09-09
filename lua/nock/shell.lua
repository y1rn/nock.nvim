local M = {}

local Popup = require("nock.ui.popup")

local geometry = require("nock.geometry")
local preview = require("nock.preview")
local filter = require("nock.filter")
local render_mod = require("nock.render")
local loading = require("nock.loading")
M._popup = nil
M._current_mode = nil
M._ns_id = nil
M._timer = nil
M._in_update = false
local _last_raw = nil
local function _track_raw(raw) _last_raw = raw or "" end
local _dismiss_aug = nil
local _guard_aug = nil
local _in_guard = false

local function teardown_guard()
  if _guard_aug then
    pcall(vim.api.nvim_del_augroup_by_name, "NockInputGuard")
    _guard_aug = nil
  end
  pcall(vim.api.nvim_clear_autocmds, { group = "NockInputGuard" })
end

local function bounce_to_insert()
  if _in_guard then return end
  if not M.is_open() then return end
  local buf = M._popup and M._popup.bufnr or nil
  local win = M._popup and M._popup.winid or nil
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  -- Only act when Popup buffer is current and not already in insert
  local m = vim.api.nvim_get_mode().mode
  if m:find("^[i]") then return end
  _in_guard = true
  vim.schedule(function()
    _in_guard = false
    if not M.is_open() then return end
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    if vim.api.nvim_get_current_buf() ~= buf then return end
    local cur = vim.api.nvim_get_mode().mode
    if not cur:find("^[i]") then
      pcall(vim.cmd, "startinsert!")
    end
  end)
end

local function setup_guard()
  if not M._popup or not M._popup.bufnr or not vim.api.nvim_buf_is_valid(M._popup.bufnr) then return end
  teardown_guard()
  _guard_aug = vim.api.nvim_create_augroup("NockInputGuard", { clear = true })
  local buf = M._popup.bufnr
  -- ModeChanged *:n -> bounce back to insert (hard guarantee, no Visual allowed)
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = _guard_aug,
    buffer = buf,
    callback = function()
      vim.schedule(function() bounce_to_insert() end)
    end,
  })
  -- InsertLeave -> bounce back to insert (Visual deferred, so no exemption)
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = _guard_aug,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not M.is_open() then return end
        if vim.api.nvim_get_current_buf() ~= buf then return end
        bounce_to_insert()
      end)
    end,
  })
  -- WinEnter/BufEnter -> re-assert insert when Popup regains focus
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = _guard_aug,
    callback = function(ev)
      vim.schedule(function()
        if not M.is_open() then return end
        if vim.api.nvim_get_current_buf() ~= buf then return end
        bounce_to_insert()
      end)
    end,
  })
end
-- Ensure mouse is enabled for drag selection (Input row native)
local function ensure_mouse()
  pcall(function()
    local m = vim.o.mouse or ""
    if m == "" then
      vim.o.mouse = "a"
    elseif not m:find("a") then
      -- ensure visual/insert mouse for drag selection; add 'a' without clobbering user setting
      vim.o.mouse = m .. "a"
    end
  end)
end


-- Expr handler for <LeftMouse>: Input row (line 1) native, List rows handle via _handle_click
function M._expr_leftmouse()
  local ok, pos = pcall(vim.fn.getmousepos)
  if ok and pos and M._popup and pos.winid == M._popup.winid and pos.line == 1 then
    return vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true)
  end
  vim.schedule(function() pcall(M._handle_click) end)
  return ""
end

function M._expr_double_click()
  local ok, pos = pcall(vim.fn.getmousepos)
  if ok and pos and M._popup and pos.winid == M._popup.winid and pos.line == 1 then
    return vim.api.nvim_replace_termcodes("<2-LeftMouse>", true, false, true)
  end
  vim.schedule(function()
    if not M.is_open() then return end
    local ok2, p = pcall(vim.fn.getmousepos)
    if ok2 and p and p.winid == M._popup.winid and p.line and p.line > 2 then
      local idx = M._state.filter.offset + (p.line - 2)
      if idx >= 1 and idx <= #M._state.filter.filtered then
        pcall(M._double_click_at, idx)
        return
      end
    end
    if ok2 and p and p.winid ~= 0 and p.winid ~= M._popup.winid then
      pcall(function() M.close({ restore = true }) end)
    else
      pcall(M._commit)
    end
  end)
  return ""
end


local function teardown_dismiss()
  if _dismiss_aug then
    pcall(vim.api.nvim_del_augroup_by_name, "NockDismiss")
    _dismiss_aug = nil
  end
  pcall(vim.api.nvim_clear_autocmds, { group = "NockDismiss" })
end

local function setup_dismiss()
  if not M._popup or not M._popup.bufnr or not vim.api.nvim_buf_is_valid(M._popup.bufnr) then
    return
  end
  teardown_dismiss()
  _dismiss_aug = vim.api.nvim_create_augroup("NockDismiss", { clear = true })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    group = _dismiss_aug,
    buffer = M._popup.bufnr,
    callback = function()
      vim.schedule(function()
        if M.is_open() then
          M.close({ restore = true })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "FocusLost" }, {
    group = _dismiss_aug,
    callback = function()
      vim.schedule(function()
        if M.is_open() then
          M.close({ restore = true })
        end
      end)
    end,
  })
end


-- Bundled state: origin/preview and filter (deep Filter module owns filter pipeline)
M._state = {
  origin = {
    win = nil,
    buf = nil,
    view = nil,
    preview_ns = nil,
    preview_buf = nil,
  },
  filter = filter.get_state(),
}
-- Proxy _current_mode to Filter (single source of truth)
do
  local mt = getmetatable(M) or {}
  local orig_index = mt.__index
  local orig_newindex = mt.__newindex
  mt.__index = function(tbl, key)
    if key == "_current_mode" then return filter.get_current_mode() end
    -- backward-compat aliases for direct field access
    local field_map = {
      _origin_win = { t = "origin", k = "win" },
      _origin_buf = { t = "origin", k = "buf" },
      _saved_view = { t = "origin", k = "view" },
      _preview_ns = { t = "origin", k = "preview_ns" },
      _preview_buf = { t = "origin", k = "preview_buf" },
      _all_items = { t = "filter", k = "all_items" },
      _filtered = { t = "filter", k = "filtered" },
      _selected_idx = { t = "filter", k = "selected_idx" },
      _offset = { t = "filter", k = "offset" },
      _prev_query = { t = "filter", k = "prev_query" },
      _prev_raw = { t = "filter", k = "prev_raw" },
    }
    local m = field_map[key]
    if m then
      local st = rawget(tbl, "_state")
      if st and st[m.t] then return st[m.t][m.k] end
    end
    if orig_index then
      if type(orig_index) == "function" then return orig_index(tbl, key) end
      if type(orig_index) == "table" then return orig_index[key] end
    end
    return rawget(tbl, key)
  end
  mt.__newindex = function(tbl, key, value)
    if key == "_current_mode" then filter.set_current_mode(value); return end
    local field_map = {
      _origin_win = { t = "origin", k = "win" },
      _origin_buf = { t = "origin", k = "buf" },
      _saved_view = { t = "origin", k = "view" },
      _preview_ns = { t = "origin", k = "preview_ns" },
      _preview_buf = { t = "origin", k = "preview_buf" },
      _all_items = { t = "filter", k = "all_items" },
      _filtered = { t = "filter", k = "filtered" },
      _selected_idx = { t = "filter", k = "selected_idx" },
      _offset = { t = "filter", k = "offset" },
      _prev_query = { t = "filter", k = "prev_query" },
      _prev_raw = { t = "filter", k = "prev_raw" },
    }
    local m = field_map[key]
    if m then
      local st = rawget(tbl, "_state")
      if st and st[m.t] then st[m.t][m.k] = value; return end
    end
    if orig_newindex then
      if type(orig_newindex) == "function" then return orig_newindex(tbl, key, value) end
    end
    rawset(tbl, key, value)
  end
  setmetatable(M, mt)
end
local function map(buf, modes, lhs, fn)
  pcall(vim.keymap.set, modes, lhs, fn, { buffer = buf, silent = true, nowait = true })
end

local function calc_geometry(maxheight, filtered_count, opts)
  return geometry.calc(maxheight, filtered_count, opts or M._open_opts)
end

--- Return current geometry for testing/assertion
function M.geometry()
  local cfg = require("nock.config")
  local mh = cfg.options.maxheight or 10
  local count = M._state.filter.filtered and #M._state.filter.filtered or 0
  return calc_geometry(mh, count, M._open_opts)
end

function M.is_open()
  return M._popup ~= nil and M._popup.winid ~= nil and vim.api.nvim_win_is_valid(M._popup.winid)
end

-- Resolve delegates to deep Filter module (single source, Q2 C)
local function resolve_mode_and_query(raw) return filter.resolve(raw) end

-- Preview helpers (delegated to preview.lua) --------------------------------
local function clear_preview_hl()
  preview.clear(M._state)
end

local function do_preview(item)
  preview.do_preview(M._state, item, M._current_mode)
end

local function trigger_preview()
  preview.trigger(M._state, M._state.filter, M._current_mode)
end

local function render()
  if not M._popup or not M._popup.bufnr or not vim.api.nvim_buf_is_valid(M._popup.bufnr) then
    return
  end
  local buf = M._popup.bufnr
  local win = M._popup.winid
  local cfg = require("nock.config")
  local maxheight = cfg.options.maxheight or 10
  local filt = M._state.filter
  local count = #filt.filtered
  local geo = calc_geometry(maxheight, count)
  if M._popup and M._popup.update_layout then
    pcall(function()
      M._popup:update_layout({ size = { width = geo.width, height = geo.height }, position = { row = geo.row, col = geo.col } })
    end)
  end
  if loading.is_visible() then
    loading.reanchor(geo)
  end
  local ok_lines, cur = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
  local query_line
  if ok_lines and cur and cur[1] then
    query_line = cur[1]
  else
    query_line = filt.prev_raw or ""
  end
  -- Preserve cursor: save before render, restore after (fixes jump to end)
  local saved_col = nil
  if win and vim.api.nvim_win_is_valid(win) then
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
    if ok and pos then saved_col = pos[2] end
  end
  M._in_update = true
  -- List render must not enter undo tree; Input typing (user nvim_buf_set_text) stays undoable
  -- Keep native Insstart: save/restore Insstart via ^ mark
  local saved_mark = nil
  if vim.api.nvim_buf_is_valid(buf) then
    local ok_m, m = pcall(vim.api.nvim_buf_get_mark, buf, "^")
    if ok_m and m then saved_mark = m end
  end
  pcall(function() vim.bo[buf].undolevels = -1 end)
  local res = render_mod.render({
    buf = buf,
    win = win,
    filtered = filt.filtered,
    offset = filt.offset,
    selected_idx = filt.selected_idx,
    query_line = query_line,
    width = geo.width,
    maxheight = maxheight,
    ns_id = M._ns_id,
  })
  if saved_mark and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_set_mark, buf, "^", saved_mark[1], saved_mark[2], {})
  end
  filt.offset = res.offset
  M._ns_id = res.ns_id
  M._in_update = false
  -- Restore cursor, clamped to query length (handles truncation)
  if win and vim.api.nvim_win_is_valid(win) and saved_col ~= nil then
    -- query_line may be truncated for display, but buffer line is truncated version
    -- Use actual buffer line length after render
    local ok2, lines2 = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
    local cur_len = 0
    if ok2 and lines2 and lines2[1] then cur_len = #lines2[1] end
    local col = saved_col
    if col > cur_len then col = cur_len end
    pcall(vim.api.nvim_win_set_cursor, win, { 1, col })
  end
end

local function do_filter(raw_query)
  local origin_win = M._state.origin.win
  local origin_buf = M._state.origin.buf
  local origin_file = (origin_buf and vim.api.nvim_buf_is_valid(origin_buf)) and vim.api.nvim_buf_get_name(origin_buf) or ""
  local ctx = {
    win = origin_win,
    buf = origin_buf,
    file = origin_file,
    is_cancelled = function() return not M.is_open() end,
  }
  local function on_update()
    -- async results arrived: hide loading if no longer pending (cancel grace+spinner)
    if not filter.is_pending() then
      loading.stop()
    end
    render()
    if #filter.get_state().filtered > 0 then
      trigger_preview()
    else
      -- unified with shell switch: empty result also cancels preview (deleting @ -> file, equivalent to directly opening file)
      if M._state.origin.preview_buf ~= nil then
        preview.restore(M._state)
      else
        clear_preview_hl()
      end
    end
  end
  -- cancel previous pending indicator before new request
  loading.stop()
  filter.apply(raw_query, ctx, on_update)
  if filter.is_pending() then
    local geo = M.geometry()
    loading.start_pending(geo)
  else
    loading.hide()
  end
end
local function schedule_filter()
  if not M._popup or not M._popup.bufnr or not vim.api.nvim_buf_is_valid(M._popup.bufnr) then
    return
  end
  if M._timer then
    pcall(function() M._timer:stop() end)
  else
    local uv = vim.uv
    if uv then
      M._timer = uv.new_timer()
    end
  end
  if not M._timer then
    vim.schedule(function()
      if not M._popup or not vim.api.nvim_buf_is_valid(M._popup.bufnr) then return end
      local lines = vim.api.nvim_buf_get_lines(M._popup.bufnr, 0, 1, false)
      local raw = lines[1] or ""
      do_filter(raw)
    end)
    return
  end
  M._timer:start(50, 0, vim.schedule_wrap(function()
    if not M._popup or not M._popup.bufnr or not vim.api.nvim_buf_is_valid(M._popup.bufnr) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(M._popup.bufnr, 0, 1, false)
    local raw = lines[1] or ""
    do_filter(raw)
  end))
end

function M._move_selection(delta)
  local filt = M._state.filter
  if #filt.filtered == 0 then
    return
  end
  local cfg = require("nock.config")
  local maxheight = cfg.options.maxheight or 10
  local n = #filt.filtered
  local visible = math.min(n, maxheight)
  local new_idx = filt.selected_idx + delta
  if new_idx < 1 then
    new_idx = n
  elseif new_idx > n then
    new_idx = 1
  end
  filt.selected_idx = new_idx
  if filt.selected_idx <= filt.offset then
    filt.offset = filt.selected_idx - 1
  elseif filt.selected_idx > filt.offset + visible then
    filt.offset = filt.selected_idx - visible
  end
  if filt.offset < 0 then
    filt.offset = 0
  elseif filt.offset + visible > n then
    filt.offset = math.max(0, n - visible)
  end
  render()
  trigger_preview()
end

function M._scroll_wheel(delta)
  if not M.is_open() then return end
  local filt = M._state.filter
  local count = #filt.filtered
  if count == 0 then return end
  local cfg = require("nock.config")
  local maxheight = cfg.options.maxheight or 10
  local visible = math.min(count, maxheight)
  if count <= visible then return end
  local step = delta or 1
  local max_offset = count - visible
  local new_offset = filt.offset + step
  if new_offset < 0 then
    new_offset = 0
  elseif new_offset > max_offset then
    new_offset = max_offset
  end
  if new_offset ~= filt.offset then
    filt.offset = new_offset
    render()
  end
end

function M._commit()
  if not M.is_open() then
    return
  end
  local filt = M._state.filter
  if #filt.filtered == 0 or filt.selected_idx == 0 then
    M.close({ restore = true })
    return
  end
  local entry = filt.filtered[filt.selected_idx]
  if not entry then
    M.close({ restore = true })
    return
  end
  local item = entry.item
  local mode = M._current_mode
  local cfg = require("nock.config")
  local spec = cfg.options.modes[mode]
  local origin = M._state.origin.win

  local ok, err = pcall(function()
    if spec and type(spec.action) == "function" then
      local ctx = { win = origin, mode = mode, buf = M._state.origin.buf }
      spec.action(item, ctx)
    else
      if item.location and item.location.path then
        local path = item.location.path
        local lnum = item.location.lnum or 1
        local col = item.location.col or 0
        if origin and vim.api.nvim_win_is_valid(origin) then
          vim.api.nvim_win_call(origin, function()
            vim.cmd("edit " .. vim.fn.fnameescape(path))
            if lnum then
              pcall(vim.api.nvim_win_set_cursor, origin, { lnum, col })
            end
          end)
        else
          vim.cmd("edit " .. vim.fn.fnameescape(path))
        end
      elseif item.value then
        pcall(vim.cmd, item.value)
      elseif item.label then
        local cmd = item.label:gsub("^:", "")
        pcall(vim.cmd, cmd)
      end
    end
  end)

  if not ok then
    vim.notify("nock action error: " .. tostring(err), vim.log.levels.ERROR)
  end

  M.close({ restore = false })
end

function M._handle_click()
  if not M.is_open() then return end
  local ok, pos = pcall(vim.fn.getmousepos)
  if not ok or not pos then
    return
  end
  if pos.winid ~= 0 and pos.winid ~= M._popup.winid then
    M.close({ restore = true })
    return
  end
  if pos.winid ~= M._popup.winid then
    return
  end
  local line = pos.line
  if not line or line <= 2 then
    return
  end
  local filt = M._state.filter
  local idx = filt.offset + (line - 2)
  if idx < 1 or idx > #filt.filtered then
    return
  end
  local was_selected = (idx == filt.selected_idx)
  if was_selected then
    M._commit()
  else
    filt.selected_idx = idx
    render()
    trigger_preview()
  end
end

function M._click_at(target)
  if not M.is_open() then return end
  if type(target) ~= "number" then return end
  local filt = M._state.filter
  local idx = target
  if idx < 1 or idx > #filt.filtered then return end
  local was_selected = (idx == filt.selected_idx)
  if was_selected then
    M._commit()
  else
    filt.selected_idx = idx
    render()
    trigger_preview()
  end
end

function M._double_click_at(target)
  if not M.is_open() then return end
  if type(target) ~= "number" then return end
  local filt = M._state.filter
  local idx = target
  if idx < 1 or idx > #filt.filtered then return end
  filt.selected_idx = idx
  render()
  trigger_preview()
  M._commit()
end

--- Open Shell for given mode (or default "files" if nil).
---@param mode_name string|nil
---@param opts table|nil optional { maxheight }
function M.open(mode_name, opts)
  local config = require("nock.config")
  opts = opts or {}
  M._open_opts = opts
  local maxheight = opts.maxheight or config.options.maxheight or 10
  local mode = mode_name
  if mode == nil then
    mode = resolve_mode_and_query("")
  end

  local prefix = (config.options.modes[mode] or {}).prefix or ""

  -- If already open: switch in-place without close/reopen (Q6 in-place switch, equivalent to deleting prefix and re-entering; Q2 preserve eff and re-filter)
  if M.is_open() then
    if mode == M._current_mode then
      return M._popup
    end
    -- Preserve effective query from current raw
    local cur_raw = ""
    local cur_eff = ""
    local old_prefix = ""
    local eff_col = nil
    if M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
      local lines = vim.api.nvim_buf_get_lines(M._popup.bufnr, 0, 1, false)
      cur_raw = lines[1] or ""
      local old_mode, eff = resolve_mode_and_query(cur_raw)
      cur_eff = eff or ""
      old_prefix = (config.options.modes[old_mode] or {}).prefix or ""
      -- Q3 no jump: preserve cursor offset within eff, not absolute column
      if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) then
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, M._popup.winid)
        if ok and pos then
          local col = pos[2] -- 0-indexed byte col
          -- col within eff = absolute col - old_prefix length
          eff_col = col - #old_prefix
          if eff_col < 0 then eff_col = 0 end
          if eff_col > #cur_eff then eff_col = #cur_eff end
        end
      end
    end
    M._current_mode = mode
    local filt = M._state.filter
    -- Reset filter state
    filt.all_items = {}
    filt.filtered = {}
    filt.selected_idx = 0
    filt.prev_query = ""
    filt.prev_raw = ""
    filt.offset = 0
    -- Single-point fix (Q1=C, Q2'=A, Q3=immediate): equivalent to cancel preview when leaving preview mode
    -- Immediate restore if a preview is active; else just clear highlight. Q5=A treats switch as cancel.
    if M._state.origin.preview_buf ~= nil then
      preview.restore(M._state)
    else
      clear_preview_hl()
    end
    local new_raw = prefix .. cur_eff
    if M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
      M._in_update = true
      -- Do not break insert: replace in place via buf_set_lines, keep insert
      vim.api.nvim_buf_set_lines(M._popup.bufnr, 0, -1, false, { new_raw })
      M._in_update = false
      _track_raw(new_raw)
    end
    do_filter(new_raw)
    -- render() pushes cursor to end of line, need to correct to eff offset without exiting insert
    if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) and eff_col ~= nil then
      local new_col = #prefix + eff_col
      if new_col > #new_raw then new_col = #new_raw end
      pcall(vim.api.nvim_win_set_cursor, M._popup.winid, { 1, new_col })
    elseif M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) then
      pcall(vim.api.nvim_win_set_cursor, M._popup.winid, { 1, #new_raw })
    end
    return M._popup
  end

  local cur_win = vim.api.nvim_get_current_win()
  M._state.origin.win = cur_win
  if vim.api.nvim_win_is_valid(cur_win) then
    M._state.origin.buf = vim.api.nvim_win_get_buf(cur_win)
    local ok, view = pcall(function()
      return vim.api.nvim_win_call(cur_win, function()
        return vim.fn.winsaveview()
      end)
    end)
    if ok and view then
      M._state.origin.view = view
    else
      M._state.origin.view = nil
    end
  else
    M._state.origin.buf = nil
    M._state.origin.view = nil
  end
  if not M._state.origin.preview_ns then
    M._state.origin.preview_ns = vim.api.nvim_create_namespace("nock_preview")
  end

  local geo = calc_geometry(maxheight, 0)

  local win_cfg = config.options.window or {}
  M._popup = Popup({
    position = { row = geo.row, col = geo.col },
    size = { width = geo.width, height = geo.height },
    border = win_cfg.border or "rounded",
    enter = true,
    focusable = true,
    zindex = 50,
    transparent = win_cfg.transparent,
    winhighlight = win_cfg.winhighlight,
    win_options = {
      winblend = win_cfg.winblend or 0,
      cursorline = false,
      transparent = win_cfg.transparent,
      winhighlight = win_cfg.winhighlight,
    },
  })

  M._popup:mount()

  pcall(function()
    if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) then
      vim.api.nvim_set_current_win(M._popup.winid)
    end
    if M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
      local b = M._popup.bufnr
      vim.b[b].blink_cmp_enable = false
      vim.b[b].completion = false
      vim.bo[b].omnifunc = ""
      vim.bo[b].completefunc = ""
      local ok_cmp, cmp = pcall(require, "cmp")
      if ok_cmp and cmp and cmp.setup and cmp.setup.buffer then
        cmp.setup.buffer({ enabled = false })
      end
    end
  end)

  if M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
    -- Pre-fill the mode's prefix in the input buffer
    vim.api.nvim_buf_set_lines(M._popup.bufnr, 0, -1, false, { prefix })
    pcall(vim.api.nvim_win_set_cursor, M._popup.winid, { 1, #prefix })
    _track_raw(prefix)
    pcall(function()
      if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) and vim.api.nvim_get_current_win() == M._popup.winid then
        vim.cmd("startinsert!")
      end
    end)
  end

  -- Delegate initial population to Filter (deep module)
  -- Filter owns mode, provider, matcher, and initial list via apply(prefix)
  if M._popup.bufnr then
    -- Hard insert-only: Esc -> Dismissal (insert-only, no Visual)
    map(M._popup.bufnr, "n", "<Esc>", function() M.close({ restore = true }) end)
    map(M._popup.bufnr, "i", "<Esc>", function() M.close({ restore = true }) end)
    -- Block transitions to Normal: <C-\><C-n> and <C-o> in insert only
    map(M._popup.bufnr, "i", "<C-\\><C-n>", function() end)
    map(M._popup.bufnr, "i", "<C-o>", function() end)
    -- Navigation: Up/Down in insert/normal
    map(M._popup.bufnr, "n", "<Up>", function() M._move_selection(-1) end)
    map(M._popup.bufnr, "i", "<Up>", function() M._move_selection(-1) end)
    map(M._popup.bufnr, "n", "<Down>", function() M._move_selection(1) end)
    map(M._popup.bufnr, "i", "<Down>", function() M._move_selection(1) end)
    map(M._popup.bufnr, "n", "<CR>", function() M._commit() end)
    map(M._popup.bufnr, "i", "<CR>", function() M._commit() end)
    -- Mouse: List rows via _handle_click, Input row not selectable (deferred)
    map(M._popup.bufnr, "n", "<LeftMouse>", function() pcall(M._handle_click) end)
    map(M._popup.bufnr, "i", "<LeftMouse>", function() pcall(M._handle_click) end)
    map(M._popup.bufnr, "n", "<2-LeftMouse>", function()
      local ok, pos = pcall(vim.fn.getmousepos)
      if ok and pos and pos.winid == M._popup.winid and pos.line and pos.line > 2 then
        local idx = M._state.filter.offset + (pos.line - 2)
        if idx >= 1 and idx <= #M._state.filter.filtered then
          pcall(M._double_click_at, idx)
          return
        end
      end
      if ok and pos and pos.winid ~= 0 and pos.winid ~= M._popup.winid then
        pcall(function() M.close({ restore = true }) end)
      else
        pcall(M._commit)
      end
    end)
    map(M._popup.bufnr, "i", "<2-LeftMouse>", function()
      local ok, pos = pcall(vim.fn.getmousepos)
      if ok and pos and pos.winid == M._popup.winid and pos.line and pos.line > 2 then
        local idx = M._state.filter.offset + (pos.line - 2)
        if idx >= 1 and idx <= #M._state.filter.filtered then
          pcall(M._double_click_at, idx)
          return
        end
      end
      if ok and pos and pos.winid ~= 0 and pos.winid ~= M._popup.winid then
        pcall(function() M.close({ restore = true }) end)
      else
        pcall(M._commit)
      end
    end)
    for mname, mspec in pairs(config.options.modes) do
      if mspec.keymap and mspec.keymap ~= "" then
        local target = mname
        map(M._popup.bufnr, "i", mspec.keymap, function() M.open(target) end)
      end
    end
    map(M._popup.bufnr, "n", "<ScrollWheelUp>", function() end)
    map(M._popup.bufnr, "i", "<ScrollWheelUp>", function() pcall(M._scroll_wheel, -1) end)
    map(M._popup.bufnr, "n", "<ScrollWheelDown>", function() pcall(M._scroll_wheel, 1) end)
    map(M._popup.bufnr, "i", "<ScrollWheelDown>", function() pcall(M._scroll_wheel, 1) end)

    pcall(vim.api.nvim_buf_attach, M._popup.bufnr, false, {
      on_lines = function(_, buf, _, _, _, _)
        if M._in_update then return false end
        local new_raw = ""
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
        if ok and lines and lines[1] then new_raw = lines[1] end
        local old_raw = _last_raw or ""
        if old_raw ~= new_raw then
          local old_mode, _ = filter.resolve(old_raw)
          local old_prefix = (require("nock.config").options.modes[old_mode] or {}).prefix or ""
          _track_raw(new_raw)
          -- Manual prefix: move insert start to after prefix so native <C-u> becomes two-stage
          -- (keymap already has start after prefix via startinsert! in open())
          local new_mode, _ = filter.resolve(new_raw)
          local new_prefix = (require("nock.config").options.modes[new_mode] or {}).prefix or ""
          if new_prefix ~= "" and new_prefix ~= old_prefix and new_raw:sub(1, #new_prefix) == new_prefix then
            local target_col = #new_prefix
            local capture_raw = new_raw
            vim.schedule(function()
              if not M.is_open() then return end
              if not vim.api.nvim_buf_is_valid(buf) then return end
              if not M._popup.winid or not vim.api.nvim_win_is_valid(M._popup.winid) then return end
              local cur = ""
              local ok2, l2 = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
              if ok2 and l2 and l2[1] then cur = l2[1] end
              if cur ~= capture_raw then return end
              pcall(vim.api.nvim_win_set_cursor, M._popup.winid, { 1, target_col })
              pcall(vim.cmd, "stopinsert")
              vim.schedule(function()
                if not M.is_open() then return end
                if not M._popup.winid or not vim.api.nvim_win_is_valid(M._popup.winid) then return end
                local cur2 = ""
                local ok3, l3 = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
                if ok3 and l3 and l3[1] then cur2 = l3[1] end
                if cur2 ~= capture_raw then return end
                pcall(vim.cmd, "startinsert!")
              end)
            end)
          end
        end
        vim.schedule(function() schedule_filter() end)
        return false
      end,
      on_detach = function()
        loading.stop()
        pcall(function() require("nock.filter").cancel_pending() end)
        teardown_guard()
        teardown_dismiss()
        if M._timer then
          pcall(function() M._timer:stop() end)
          pcall(function() M._timer:close() end)
          M._timer = nil
        end
      end,
    })
  end

  ensure_mouse()
  setup_guard()
  setup_dismiss()

  do_filter(prefix)

  return M._popup
end


function M.close(opts)
  opts = opts or {}
  local restore = opts.restore
  if restore == nil then
    restore = true
  end
  -- loading must follow nock lifecycle: stop grace/spinner and hide window immediately on close
  pcall(function() require("nock.loading").stop() end)
  -- True kill (Q7): close kills the in-flight enumeration immediately, before teardown.
  pcall(function() require("nock.filter").cancel_pending() end)
  teardown_guard()
  teardown_dismiss()
  if M._timer then
    pcall(function() M._timer:stop() end)
    pcall(function() M._timer:close() end)
    M._timer = nil
  end
  M._open_opts = nil
  clear_preview_hl()
  if restore and M._state.origin.win and vim.api.nvim_win_is_valid(M._state.origin.win) and M._state.origin.view then
    pcall(function()
      vim.api.nvim_win_call(M._state.origin.win, function()
        if M._state.origin.buf and vim.api.nvim_buf_is_valid(M._state.origin.buf) then
          local cur = vim.api.nvim_win_get_buf(M._state.origin.win)
          if cur ~= M._state.origin.buf then
            pcall(function()
              vim.cmd("keepjumps keepalt buffer " .. M._state.origin.buf)
            end)
            if vim.api.nvim_win_get_buf(M._state.origin.win) ~= M._state.origin.buf then
              pcall(vim.api.nvim_win_set_buf, M._state.origin.win, M._state.origin.buf)
            end
          end
        end
        pcall(vim.fn.winrestview, M._state.origin.view)
      end)
    end)
  end

  if M._popup then
    if M._ns_id and M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, M._popup.bufnr, M._ns_id, 0, -1)
    end
    pcall(function()
      M._popup:unmount()
    end)
    if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) then
      pcall(vim.api.nvim_win_close, M._popup.winid, true)
    end
    M._popup = nil
  end
  M._current_mode = nil
  -- cleanup transient pick mode if present
  pcall(function()
    local cfg = require("nock.config")
    if cfg.options.modes and cfg.options.modes["__pick__"] then
      cfg.options.modes["__pick__"] = nil
    end
  end)
  filter.reset()
  M._in_update = false
  M._state.origin.win = nil
  M._state.origin.buf = nil
  M._state.origin.view = nil
  M._state.origin.preview_buf = nil
  pcall(vim.cmd, "stopinsert")
end

--- Selector: unified vim.ui.select replacement (ADR-0021). No prefix/provider.
--- Signature matches vim.ui.select: pick(items, opts, on_choice)
--- items: any[] (string or table), opts: {prompt, kind, format_item, preview?, maxheight?, width?, row?, auto_jump_single?}, on_choice: fun(item, idx)
function M.pick(items, opts, on_choice)
  -- overload: pick(items, opts) with opts.action legacy not needed after refactor, but keep thin fallback for internal use
  if type(opts) == "function" and on_choice == nil then on_choice, opts = opts, {} end
  opts = opts or {}
  if type(items) ~= "table" then items = {} end
  if #items == 0 then
    vim.schedule(function()
      vim.notify(opts.prompt or "No items", vim.log.levels.INFO)
      if type(on_choice) == "function" then pcall(on_choice, nil, nil) end
    end)
    return nil
  end
  local auto_jump = opts.auto_jump_single
  if auto_jump == nil then auto_jump = true end
  if auto_jump and #items == 1 and type(on_choice) == "function" then
    vim.schedule(function() pcall(on_choice, items[1], 1) end)
    return nil
  end
  if #items == 1 and type(on_choice) ~= "function" and opts.action then
    -- legacy single without callback: still open picker
  end
  if M.is_open() then M.close({ restore = true }) end

  -- coerce any[] -> Item[] for Shell rendering, keep raw mapping
  local format_item = opts.format_item
  local kind_opt = opts.kind
  local coerced = {}
  local function to_label(raw)
    if type(format_item) == "function" then
      local ok, res = pcall(format_item, raw)
      if ok and type(res) == "string" and res ~= "" then return res end
    end
    if type(raw) == "string" then return raw end
    if type(raw) == "table" then
      if type(raw.label) == "string" and raw.label ~= "" then return raw.label end
      if type(raw.title) == "string" and raw.title ~= "" then return raw.title end
      if type(raw.name) == "string" and raw.name ~= "" then return raw.name end
      if type(raw.text) == "string" and raw.text ~= "" then return raw.text end
    end
    return tostring(raw)
  end
  for _, raw in ipairs(items) do
    local label = to_label(raw)
    local kind = nil
    if type(raw) == "table" and type(raw.kind) == "string" then kind = raw.kind
    elseif type(kind_opt) == "string" and kind_opt ~= "" then
      -- normalize kind: "codeaction" -> "CodeAction"
      kind = kind_opt:sub(1,1):upper() .. kind_opt:sub(2)
    end
    local detail = nil
    if type(raw) == "table" and type(raw.detail) == "string" then detail = raw.detail end
    local location = nil
    if type(raw) == "table" and type(raw.location) == "table" then location = raw.location end
    table.insert(coerced, {
      label = label,
      kind = kind,
      detail = detail,
      location = location,
      value = raw,
      -- keep raw reference for on_choice
      _raw = raw,
    })
  end

  local cur_win = vim.api.nvim_get_current_win()
  M._state.origin.win = cur_win
  if vim.api.nvim_win_is_valid(cur_win) then
    M._state.origin.buf = vim.api.nvim_win_get_buf(cur_win)
    local ok, view = pcall(function()
      return vim.api.nvim_win_call(cur_win, function() return vim.fn.winsaveview() end)
    end)
    M._state.origin.view = (ok and view) or nil
  else
    M._state.origin.buf = nil
    M._state.origin.view = nil
  end
  if not M._state.origin.preview_ns then
    M._state.origin.preview_ns = vim.api.nvim_create_namespace("nock_preview")
  end

  local cfg = require("nock.config")
  local maxheight = opts.maxheight or cfg.options.maxheight or 10
  M._open_opts = opts
  local prompt = opts.prompt or opts.title or ""

  -- preview auto: enable only if any coerced has location (Q9=A)
  local has_loc = false
  for _, it in ipairs(coerced) do if it.location and it.location.path then has_loc = true break end end
  local use_preview = opts.preview
  if use_preview == nil then use_preview = has_loc end

  local pick_mode = "__pick__"
  -- action wrapper calls on_choice with original raw + idx
  local function pick_action(coerced_item, _ctx)
    if type(on_choice) ~= "function" then return end
    for idx, raw in ipairs(items) do
      if coerced[idx] == coerced_item or coerced[idx]._raw == coerced_item._raw then
        pcall(on_choice, raw, idx)
        return
      end
      -- fallback by label+value identity
      if coerced_item.value == raw then pcall(on_choice, raw, idx) return end
    end
    -- fallback: pass coerced value
    pcall(on_choice, coerced_item.value or coerced_item, nil)
  end
  cfg.options.modes[pick_mode] = {
    prefix = "",
    provider = function(_q, ctx, cb)
      if type(cb) ~= "function" then return nil end
      local snapshot = coerced
      vim.schedule(function()
        if ctx and ctx.is_cancelled and ctx.is_cancelled() then return end
        cb(snapshot)
      end)
      return nil, function() end
    end,
    action = pick_action,
    preview = use_preview and true or false,
  }
  filter.set_current_mode(pick_mode)

  local filt = M._state.filter
  filt.all_items = coerced
  filt.filtered = {}
  for _, it in ipairs(coerced) do table.insert(filt.filtered, { item = it, score = 0, positions = {} }) end
  filt.selected_idx = #filt.filtered > 0 and 1 or 0
  filt.offset = 0
  filt.prev_query = ""
  filt.prev_raw = ""

  local geo = calc_geometry(maxheight, #filt.filtered, opts)
  local win_cfg = cfg.options.window or {}
  M._popup = Popup({
    position = { row = geo.row, col = geo.col },
    size = { width = geo.width, height = geo.height },
    border = win_cfg.border or "rounded",
    enter = true, focusable = true, zindex = 50,
    transparent = win_cfg.transparent,
    winhighlight = win_cfg.winhighlight,
    win_options = { winblend = win_cfg.winblend or 0, cursorline = false, transparent = win_cfg.transparent, winhighlight = win_cfg.winhighlight },
  })
  M._popup:mount()
  pcall(function()
    if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) then vim.api.nvim_set_current_win(M._popup.winid) end
    if M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
      local b = M._popup.bufnr
      vim.b[b].blink_cmp_enable = false; vim.b[b].completion = false
      vim.bo[b].omnifunc = ""; vim.bo[b].completefunc = ""
      local ok_cmp, cmp = pcall(require, "cmp"); if ok_cmp and cmp and cmp.setup and cmp.setup.buffer then cmp.setup.buffer({ enabled = false }) end
    end
  end)

  if M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) then
    vim.api.nvim_buf_set_lines(M._popup.bufnr, 0, -1, false, { "" })
    pcall(vim.api.nvim_win_set_cursor, M._popup.winid, { 1, 0 })
    _track_raw("")
    pcall(function()
      if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) and vim.api.nvim_get_current_win() == M._popup.winid then vim.cmd("startinsert!") end
    end)
  end

  local function do_pick_filter(raw_query)
    raw_query = raw_query or ""
    local q = raw_query:match("^%s*(.-)%s*$") or raw_query
    filt.prev_raw = raw_query
    if q == "" then
      filt.filtered = {}
      for _, it in ipairs(coerced) do table.insert(filt.filtered, { item = it, score = 0, positions = {} }) end
      filt.selected_idx = #filt.filtered > 0 and 1 or 0
      filt.prev_query = ""
      filt.offset = 0
      render()
      -- placeholder for prompt (Q5=A, Q1A/Q3A: BS to "" immediately recovers)
      if prompt ~= "" and q == "" and M._popup and M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) and M._ns_id then
        pcall(vim.api.nvim_buf_set_extmark, M._popup.bufnr, M._ns_id, 0, 0, { virt_text = { { prompt, "Comment" } }, virt_text_pos = "overlay", hl_mode = "combine" })
      end
      if #filt.filtered > 0 then trigger_preview() else clear_preview_hl() end
      return
    end
    local matcher = require("nock.matcher")
    local recencyFn = cfg.options._recencyFn or cfg.options.recency
    local results = matcher.filter(q, coerced, cfg.options.matcher, { recency = recencyFn })
    filt.filtered = results or {}
    filt.prev_query = q
    filt.selected_idx = #filt.filtered > 0 and 1 or 0
    filt.offset = 0
    render()
    if #filt.filtered > 0 then trigger_preview() else clear_preview_hl() end
  end

  local function cancel_pick()
    M.close({ restore = true })
    if type(on_choice) == "function" then vim.schedule(function() pcall(on_choice, nil, nil) end) end
  end
  if M._popup.bufnr then
    map(M._popup.bufnr, "n", "<Esc>", cancel_pick)
    map(M._popup.bufnr, "i", "<Esc>", cancel_pick)
    map(M._popup.bufnr, "i", "<C-\\><C-n>", function() end)
    map(M._popup.bufnr, "i", "<C-o>", function() end)
    map(M._popup.bufnr, "n", "<Up>", function() M._move_selection(-1) end)
    map(M._popup.bufnr, "i", "<Up>", function() M._move_selection(-1) end)
    map(M._popup.bufnr, "n", "<Down>", function() M._move_selection(1) end)
    map(M._popup.bufnr, "i", "<Down>", function() M._move_selection(1) end)
    map(M._popup.bufnr, "n", "<CR>", function() M._commit() end)
    map(M._popup.bufnr, "i", "<CR>", function() M._commit() end)
    map(M._popup.bufnr, "n", "<LeftMouse>", function() pcall(M._handle_click) end)
    map(M._popup.bufnr, "i", "<LeftMouse>", function() pcall(M._handle_click) end)
    map(M._popup.bufnr, "n", "<2-LeftMouse>", function()
      local ok, pos = pcall(vim.fn.getmousepos)
      if ok and pos and pos.winid == M._popup.winid and pos.line and pos.line > 2 then
        local idx = filt.offset + (pos.line - 2)
        if idx >= 1 and idx <= #filt.filtered then pcall(M._double_click_at, idx); return end
      end
      if ok and pos and pos.winid ~= 0 and pos.winid ~= M._popup.winid then pcall(cancel_pick) else pcall(M._commit) end
    end)
    map(M._popup.bufnr, "i", "<2-LeftMouse>", function()
      local ok, pos = pcall(vim.fn.getmousepos)
      if ok and pos and pos.winid == M._popup.winid and pos.line and pos.line > 2 then
        local idx = filt.offset + (pos.line - 2)
        if idx >= 1 and idx <= #filt.filtered then pcall(M._double_click_at, idx); return end
      end
      if ok and pos and pos.winid ~= 0 and pos.winid ~= M._popup.winid then pcall(cancel_pick) else pcall(M._commit) end
    end)
    map(M._popup.bufnr, "n", "<ScrollWheelUp>", function() end)
    map(M._popup.bufnr, "i", "<ScrollWheelUp>", function() pcall(M._scroll_wheel, -1) end)
    map(M._popup.bufnr, "n", "<ScrollWheelDown>", function() pcall(M._scroll_wheel, 1) end)
    map(M._popup.bufnr, "i", "<ScrollWheelDown>", function() pcall(M._scroll_wheel, 1) end)

    pcall(vim.api.nvim_buf_attach, M._popup.bufnr, false, {
      on_lines = function(_, buf, _, _, _, _)
        if M._in_update then return false end
        local new_raw = ""
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
        if ok and lines and lines[1] then new_raw = lines[1] end
        if (_last_raw or "") ~= new_raw then
          _track_raw(new_raw)
          vim.schedule(function() do_pick_filter(new_raw) end)
        end
        return false
      end,
      on_detach = function()
        loading.stop(); pcall(function() require("nock.filter").cancel_pending() end); teardown_guard(); teardown_dismiss()
        if M._timer then pcall(function() M._timer:stop() end); pcall(function() M._timer:close() end); M._timer=nil end
        -- if detached without commit/cancel, treat as cancel (vim.ui.select semantics Q10)
        if M._current_mode == "__pick__" and type(on_choice) == "function" then
          -- avoid double-call if already closed via cancel_pick: filter.current_mode already nil
        end
      end,
    })
  end

  ensure_mouse()
  setup_guard()
  setup_dismiss()
  render()
  if prompt ~= "" and M._popup and M._popup.bufnr and vim.api.nvim_buf_is_valid(M._popup.bufnr) and M._ns_id then
    pcall(vim.api.nvim_buf_set_extmark, M._popup.bufnr, M._ns_id, 0, 0, { virt_text = { { prompt, "Comment" } }, virt_text_pos = "overlay", hl_mode = "combine" })
  end
  if #filt.filtered > 0 then trigger_preview() end
  return M._popup
end
--- For tests: expose popup directly
function M._get_popup()
  return M._popup
end

function M._get_current_mode()
  return M._current_mode
end

function M._get_filtered()
  return M._state.filter.filtered
end

function M._get_all_items()
  return M._state.filter.all_items
end

function M._get_selected_idx()
  return M._state.filter.selected_idx
end

function M._set_query_for_test(raw)
  if not M.is_open() then
    return
  end
  M._in_update = true
  pcall(vim.api.nvim_buf_set_lines, M._popup.bufnr, 0, 1, false, { raw or "" })
  -- Programmatic set should place cursor at end, so render's preservation keeps it there
  if M._popup.winid and vim.api.nvim_win_is_valid(M._popup.winid) then
    pcall(vim.api.nvim_win_set_cursor, M._popup.winid, { 1, #(raw or "") })
  end
  M._in_update = false
  _track_raw(raw or "")
  do_filter(raw or "")
end

function M._get_origin()
  return M._state.origin.win, M._state.origin.buf, M._state.origin.view
end

function M._is_loading_visible()
  return loading.is_visible()
end

function M._get_loading_win()
  return loading._winid
end

function M._get_preview_ns()
  return M._state.origin.preview_ns
end

function M._get_preview_buf()
  return M._state.origin.preview_buf
end

-- expose internal for tests
M._do_filter = do_filter
M._render = render
M._do_preview = do_preview
M._trigger_preview = trigger_preview
M._clear_preview = clear_preview_hl

return M
