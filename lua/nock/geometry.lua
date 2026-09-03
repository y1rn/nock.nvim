local M = {}

function M.calc(maxheight, filtered_count, opts)
  local cfg_opts
  pcall(function()
    cfg_opts = require("nock.config").options
  end)
  opts = opts or cfg_opts or {}

  local columns = vim.o.columns
  local lines = vim.o.lines

  local width_cfg = opts.width ~= nil and opts.width or 0.3
  local width
  if type(width_cfg) == "number" then
    if width_cfg <= 1.0 then
      width = math.floor(columns * width_cfg)
      width = math.max(40, math.min(80, width))
    else
      width = math.floor(width_cfg)
    end
  else
    width = math.floor(columns * 0.3)
    width = math.max(40, math.min(80, width))
  end
  width = math.max(10, math.min(columns, width))

  local height = 1
  if filtered_count ~= nil and filtered_count > 0 then
    height = 2 + math.min(filtered_count, maxheight or 10)
  else
    height = 1
  end

  local row_cfg = opts.row ~= nil and opts.row or 0
  local row = 0
  if type(row_cfg) == "number" then
    if row_cfg > 0 and row_cfg < 1.0 then
      row = math.floor(lines * row_cfg)
    else
      row = math.floor(row_cfg)
    end
  end
  row = math.max(0, math.min(lines - 1, row))

  local col = math.floor((columns - width) / 2)
  col = math.max(0, col)

  return { width = width, height = height, row = row, col = col }
end

return M
