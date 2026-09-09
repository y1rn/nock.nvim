local M = {}

local Popup = {}
Popup.__index = Popup

--- Create a new native Popup component.
---@param opts table|nil
---@return table Popup instance
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Popup)
  self.opts = opts
  self.winid = nil
  self.bufnr = nil
  self.position = opts.position or { row = 0, col = 0 }
  self.size = opts.size or { width = 40, height = 1 }
  self.border = opts.border or "rounded"
  self.zindex = opts.zindex or 50
  self.enter = opts.enter ~= false
  self.focusable = opts.focusable ~= false
  return self
end

--- Mount the popup: create unlisted scratch buffer and open native floating window.
function Popup:mount()
  if self:is_valid() then
    return self
  end

  -- Create unlisted scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  self.bufnr = bufnr

  -- Buffer options
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nock_input"
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  -- Window configuration
  local border_style = self.border
  if type(border_style) == "table" and border_style.style then
    border_style = border_style.style
  end

  local win_cfg = {
    relative = "editor",
    style = "minimal",
    row = math.max(0, math.floor(self.position.row or 0)),
    col = math.max(0, math.floor(self.position.col or 0)),
    width = math.max(1, math.floor(self.size.width or 40)),
    height = math.max(1, math.floor(self.size.height or 1)),
    border = border_style or "rounded",
    zindex = self.zindex or 50,
    focusable = self.focusable,
  }

  local winid = vim.api.nvim_open_win(bufnr, self.enter, win_cfg)
  self.winid = winid

  -- Window options
  if winid and vim.api.nvim_win_is_valid(winid) then
    local wo = vim.wo[winid]
    local win_opts = self.opts.win_options or {}
    wo.winblend = win_opts.winblend or (self.opts.winblend or 0)
    wo.cursorline = win_opts.cursorline or false
    local winhl = win_opts.winhighlight or self.opts.winhighlight
    if winhl == nil then
      local transparent = win_opts.transparent
      if transparent == nil then transparent = self.opts.transparent end
      if transparent == nil then transparent = true end
      if transparent then
        winhl = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Normal"
      end
    end
    if winhl then wo.winhighlight = winhl end
    wo.wrap = false
    wo.number = false
    wo.relativenumber = false
    wo.foldenable = false
    wo.spell = false
    wo.signcolumn = "no"
  end

  return self
end

--- Update layout (size and/or position).
---@param layout table { size = { width, height }, position = { row, col } }
function Popup:update_layout(layout)
  if not self:is_valid() then
    return
  end
  layout = layout or {}
  if layout.size then
    self.size = layout.size
  end
  if layout.position then
    self.position = layout.position
  end

  local win_cfg = {
    relative = "editor",
    row = math.max(0, math.floor(self.position.row or 0)),
    col = math.max(0, math.floor(self.position.col or 0)),
    width = math.max(1, math.floor(self.size.width or 40)),
    height = math.max(1, math.floor(self.size.height or 1)),
  }
  pcall(vim.api.nvim_win_set_config, self.winid, win_cfg)
end

--- Check if the popup's window and buffer are valid.
---@return boolean
function Popup:is_valid()
  return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

--- Unmount and close the popup window.
function Popup:unmount()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    pcall(vim.api.nvim_win_close, self.winid, true)
  end
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
  end
  self.winid = nil
  self.bufnr = nil
end

M.Popup = Popup
setmetatable(M, {
  __call = function(_, opts)
    return M.new(opts)
  end,
})

return M
