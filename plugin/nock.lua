-- nock.nvim plugin entry
-- Dependencies: requires MunifTanjim/nui.nvim
-- lazy.nvim spec: dependencies = { "MunifTanjim/nui.nvim" }
if vim.g.loaded_nock then
  return
end
vim.g.loaded_nock = 1

-- Plugin entry: ensure highlights exist even before setup() is called.
-- Users are expected to call require("nock").setup() in their config.
pcall(function()
  require("nock.highlights").setup()
end)

-- Optional user command for manual open (useful without keymaps)
pcall(vim.api.nvim_create_user_command, "Nock", function(opts)
  local mode = opts.args ~= "" and opts.args or nil
  require("nock").open(mode)
end, { nargs = "?", desc = "Open Nock Shell", complete = function()
  local cfg = require("nock.config")
  local modes = {}
  for name, _ in pairs(cfg.options.modes) do
    table.insert(modes, name)
  end
  return modes
end })
