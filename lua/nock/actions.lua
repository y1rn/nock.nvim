local M = {}

--- Edit file or switch to buffer at item location (default action).
---@param item table
---@param ctx table { win: number, buf: number, file: string }
function M.edit(item, ctx)
  if not item then return end
  local win = ctx and ctx.win or vim.api.nvim_get_current_win()
  local bufnr = item.bufnr
  local path = (item.location and item.location.path) or item.value or item.label
  local lnum = (item.location and item.location.lnum) or 1
  local col = (item.location and item.location.col) or 0

  if not bufnr and path then
    local target = vim.fn.fnamemodify(path, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local bname = vim.api.nvim_buf_get_name(b)
        if bname ~= "" and vim.fn.fnamemodify(bname, ":p") == target then
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
      if lnum then
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
      end
    end)
  else
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_cmd, { cmd = "buffer", args = { tostring(bufnr) } }, {})
    elseif path then
      pcall(vim.api.nvim_cmd, { cmd = "edit", args = { path } }, {})
    end
    if lnum then
      pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col })
    end
  end
end

---@param item table
---@param _ctx table
---@diagnostic disable-next-line: unused-local
function M.cmd(item, _ctx)
  local cmd_str = item.value or item.label
  if type(cmd_str) == "string" then
    cmd_str = cmd_str:gsub("^:", "")
    -- pcall(vim.cmd, cmd_str)
    pcall(vim.api.nvim_cmd, { cmd = cmd_str, args = {} }, {})
  end
end

--- Set cursor to line/col in origin window without reopening file.
---@param item table
---@param ctx table
function M.set_cursor(item, ctx)
  if not item then return end
  local win = ctx and ctx.win or vim.api.nvim_get_current_win()
  local lnum = (item.location and item.location.lnum) or item.value or item.lnum or 1
  local col = (item.location and item.location.col) or item.col or 0
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
  end
end

return M
