local M = {}

function M.clear(state)
  local origin = state.origin
  if origin.preview_ns and origin.preview_buf and vim.api.nvim_buf_is_valid(origin.preview_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, origin.preview_buf, origin.preview_ns, 0, -1)
  end
  if origin.win and vim.api.nvim_win_is_valid(origin.win) and origin.preview_ns then
    local ob = vim.api.nvim_win_get_buf(origin.win)
    if ob and vim.api.nvim_buf_is_valid(ob) and ob ~= origin.preview_buf then
      pcall(vim.api.nvim_buf_clear_namespace, ob, origin.preview_ns, 0, -1)
    end
  end
  origin.preview_buf = nil
end

--- Restore origin view/buf if a preview is active; then clear highlight.
--- Equivalent to canceling preview, reused by Shell mode-switch (single-point).
function M.restore(state)
  local origin = state.origin
  local had_preview = origin.preview_buf ~= nil
  if had_preview and origin.win and vim.api.nvim_win_is_valid(origin.win) and origin.view then
    pcall(function()
      vim.api.nvim_win_call(origin.win, function()
        if origin.buf and vim.api.nvim_buf_is_valid(origin.buf) then
          local cur = vim.api.nvim_win_get_buf(origin.win)
          if cur ~= origin.buf then
            pcall(function()
              vim.cmd("keepjumps keepalt buffer " .. origin.buf)
            end)
            if vim.api.nvim_win_get_buf(origin.win) ~= origin.buf then
              pcall(vim.api.nvim_win_set_buf, origin.win, origin.buf)
            end
          end
        end
        pcall(vim.fn.winrestview, origin.view)
      end)
    end)
  end
  M.clear(state)
end

local function should_preview(item, mode)
  if not item or not item.location or not item.location.path then
    return false
  end
  local cfg = require("nock.config")
  local spec = cfg.options.modes[mode]
  if not spec then
    return false
  end
  local pv = spec.preview
  if pv == nil then
    return false
  end
  if type(pv) == "function" then
    local ok, res = pcall(pv, item)
    if not ok then
      return false
    end
    return res and true or false
  end
  return pv == true
end

function M.do_preview(state, item, mode)
  if not item or not should_preview(item, mode) then
    if state.origin.preview_buf ~= nil then
      M.restore(state)
    else
      M.clear(state)
    end
    return
  end
  M.clear(state)
  local origin = state.origin
  if not origin.win or not vim.api.nvim_win_is_valid(origin.win) then
    return
  end

  local path = item.location.path
  local lnum = item.location.lnum or 1
  local col = item.location.col or 0

  if not origin.preview_ns then
    origin.preview_ns = vim.api.nvim_create_namespace("nock_preview")
  end

  local buf = vim.fn.bufadd(path)
  pcall(vim.fn.bufload, buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  pcall(function()
    if vim.api.nvim_win_get_buf(origin.win) ~= buf then
      vim.api.nvim_win_call(origin.win, function()
        local ok = pcall(function()
          vim.cmd("keepjumps keepalt buffer " .. buf)
        end)
        if not ok or vim.api.nvim_win_get_buf(origin.win) ~= buf then
          pcall(vim.api.nvim_win_set_buf, origin.win, buf)
        end
      end)
    end
  end)
  pcall(vim.api.nvim_win_set_cursor, origin.win, { lnum, col })
  -- centered preview: keep cursor in middle (zz), no jumplist
  pcall(function()
    if vim.api.nvim_win_is_valid(origin.win) then
      vim.api.nvim_win_call(origin.win, function()
        pcall(vim.cmd, "normal! zz")
      end)
    end
  end)
  local end_lnum = item.location.end_lnum
  local end_col = item.location.end_col
  if end_lnum and end_col and end_lnum >= lnum then
    -- highlight the symbol's exact range (selectionRange)
    pcall(vim.api.nvim_buf_set_extmark, buf, origin.preview_ns, lnum - 1, col - 1, {
      end_row = end_lnum - 1,
      end_col = end_col - 1,
      hl_group = "NockPreview",
    })
  else
    pcall(vim.api.nvim_buf_set_extmark, buf, origin.preview_ns, lnum - 1, 0, {
      hl_group = "NockPreview",
      hl_eol = true,
    })
  end
  origin.preview_buf = buf
end

function M.trigger(state, filter, mode)
  local filtered = filter.filtered
  local idx = filter.selected_idx
  if #filtered == 0 or idx == 0 then
    return
  end
  local entry = filtered[idx]
  local item = entry and entry.item or nil
  M.do_preview(state, item, mode)
end

M._should_preview = should_preview

return M
