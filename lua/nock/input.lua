local M = {}

-- Centralizes Input raw/eff handling so manual prefix and keymap prefix are unified.
-- Raw is sole source for prefix resolution; eff is raw without prefix.
-- Manual input and keymap-generated prefix share the same raw path, so native
-- <C-u> two-stage (clear eff -> clear prefix) is handled by the shell's
-- on_lines interception without a dedicated line-editing helper.

function M.get_prefix(mode)
  local ok, cfg = pcall(require, "nock.config")
  if not ok or not cfg or not cfg.options or not cfg.options.modes then return "" end
  local spec = cfg.options.modes[mode]
  return spec and spec.prefix or ""
end

function M.resolve(raw)
  local ok, cfg = pcall(require, "nock.config")
  if not ok then return "files", raw or "" end
  return cfg.resolve(raw)
end

function M.get_raw(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return "" end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
  return lines[1] or ""
end

-- Set raw via API with _in_update guard; caller must provide shell's _in_update flag handling
-- We expose a helper that shell can use with its own guard.
---@diagnostic disable-next-line: unused-local
function M.set_raw(buf, raw, _in_update_ref)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { raw or "" })
end

-- Eff helpers: eff = raw without prefix
function M.get_eff(raw)
  local mode, eff = M.resolve(raw)
  return eff or "", mode
end

function M.set_eff(buf, eff, win)
  local raw = M.get_raw(buf)
  local mode = M.resolve(raw)
  local prefix = M.get_prefix(mode)
  -- If raw currently has a different valid prefix (mode switch via typing), use that prefix
  -- Otherwise use current mode's prefix
  -- For set_eff we preserve the prefix of the current mode (caller's mode)
  local new_raw = prefix .. (eff or "")
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { new_raw })
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, #new_raw })
  end
  return new_raw
end

return M
