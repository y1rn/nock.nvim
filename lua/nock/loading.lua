local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local GRACE_MS = 150
local SPINNER_MS = 80

M._winid = nil
M._bufnr = nil
---@type uv.uv_timer_t?
M._grace_timer = nil
---@type uv.uv_timer_t?
M._spinner_timer = nil
M._frame_idx = 1
M._ns = vim.api.nvim_create_namespace("nock_loading")
M._seq = 0

local function ensure_hl()
  pcall(vim.api.nvim_set_hl, 0, "NockLoading", { link = "MoreMsg", default = true })
end

local function close_timer(t)
  if t then pcall(function() t:stop() end) pcall(function() t:close() end) end
  return nil
end


local function buf_valid()
  return M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr)
end

local function win_valid()
  return M._winid and vim.api.nvim_win_is_valid(M._winid)
end

local function create_buf()
  if buf_valid() then return M._bufnr end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  M._bufnr = buf
  return buf
end

function M.is_visible()
  return M._visible and win_valid()
end
function M._update_frame()
  if not M.is_visible() then return end
  if not buf_valid() then return end
  local frame = FRAMES[M._frame_idx]
  pcall(vim.api.nvim_buf_set_lines, M._bufnr, 0, -1, false, { frame })
  pcall(vim.api.nvim_buf_clear_namespace, M._bufnr, M._ns, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, M._bufnr, M._ns, 0, 0, { end_col = 3, hl_group = "NockLoading" })
end

function M._tick()
  M._frame_idx = (M._frame_idx % #FRAMES) + 1
  M._update_frame()
end

function M.show(geo)
  if M.is_visible() then
    if geo then M.reanchor(geo) end
    return
  end
  ensure_hl()
  local buf = create_buf()
  geo = geo or M._geo
  if not geo then return end
  M._geo = geo
  local row = (geo.row or 0) + 1
  local col = (geo.col or 0) + (geo.width or 40) - 1
  -- ensure within screen
  local width = 2
  local height = 1
  local ok, winid = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 51,
    noautocmd = true,
  })
  if not ok or not winid then return end
  M._winid = winid
  vim.wo[winid].winblend = 0
  M._visible = true
  M._frame_idx = 1
  M._update_frame()
end

function M.hide()
  -- stop spinner, keep grace stopped by caller; hide idempotent
  if M._spinner_timer then
    M._spinner_timer = close_timer(M._spinner_timer)
  end
  if win_valid() then
    pcall(vim.api.nvim_win_close, M._winid, true)
  end
  M._winid = nil
  M._visible = false
  M._frame_idx = 1
end

function M.stop()
  M._seq = M._seq + 1
  if M._grace_timer then
    M._grace_timer = close_timer(M._grace_timer)
  end
  if M._spinner_timer then
    M._spinner_timer = close_timer(M._spinner_timer)
  end
  M.hide()
end

function M.reanchor(geo)
  if not geo then return end
  M._geo = geo
  if not M.is_visible() then return end
  local row = (geo.row or 0) + 1
  local col = (geo.col or 0) + (geo.width or 40) - 1
  pcall(vim.api.nvim_win_set_config, M._winid, {
    relative = "editor",
    row = row,
    col = col,
    width = 2,
    height = 1,
  })
end
function M.start_pending(geo)
  -- cancel any prior grace/spinner
  if M._grace_timer then M._grace_timer = close_timer(M._grace_timer) end
  if M._spinner_timer then M._spinner_timer = close_timer(M._spinner_timer) end
  M.hide()
  M._geo = geo
  M._seq = M._seq + 1
  local my_seq = M._seq
  local uv = vim.uv
  if not uv then
    -- fallback: show immediately (no grace)
    M.show(geo)
    return
  end
  M._grace_timer = uv.new_timer()
  if not M._grace_timer then
    M.show(geo)
    return
  end
  M._grace_timer:start(GRACE_MS, 0, vim.schedule_wrap(function()
    if my_seq ~= M._seq then return end
    if M._grace_timer then
      M._grace_timer = close_timer(M._grace_timer)
    end
    -- only show if still pending (caller will have stopped if resolved)
    -- seq check ensures stale grace after close does not create ghost window
    if not M.is_visible() then
      M.show(geo)
      -- start spinner tick
      local uv2 = vim.uv
      if uv2 then
        M._spinner_timer = uv2.new_timer()
        if M._spinner_timer then
          M._spinner_timer:start(SPINNER_MS, SPINNER_MS, vim.schedule_wrap(function()
            M._tick()
          end))
        end
      end
    end
  end))
end

return M
