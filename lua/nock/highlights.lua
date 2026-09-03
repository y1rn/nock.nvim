local M = {}

--- Default highlight links: NockMatch -> Search etc.
--- @param hl table|nil highlights table { match, selected, preview, separator, scrollbar, loading } where values are link targets
function M.setup(hl)
  hl = hl or {}
  local match = hl.match or "Search"
  local selected = hl.selected or "CursorLine"
  local preview = hl.preview or "IncSearch"
  local separator = hl.separator or "FloatBorder"
  local scrollbar = hl.scrollbar or "NonText"
  local loading_hl = hl.loading or "MoreMsg"

  -- Use link to allow user colorscheme override; do not set default=true so override wins
  vim.api.nvim_set_hl(0, "NockMatch", { link = match })
  vim.api.nvim_set_hl(0, "NockSelected", { link = selected })
  vim.api.nvim_set_hl(0, "NockPreview", { link = preview })
  vim.api.nvim_set_hl(0, "NockSeparator", { link = separator })
  vim.api.nvim_set_hl(0, "NockScrollbar", { link = scrollbar })
  vim.api.nvim_set_hl(0, "NockLoading", { link = loading_hl })
end

return M
