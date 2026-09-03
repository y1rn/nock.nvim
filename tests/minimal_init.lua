-- minimal_init for headless plenary tests
vim.cmd("set rtp+=.")
-- ensure nui and plenary from site pack are on rtp (lazy/opt)
local site = vim.fn.stdpath("data") .. "/site"
vim.opt.packpath:prepend(site)
-- Also explicitly add opt packs if not already on rtp
local function add_rtp(pat)
  for _, p in ipairs(vim.fn.glob(pat, false, true)) do
    vim.opt.rtp:append(p)
  end
end
add_rtp(vim.fn.stdpath("data") .. "/site/pack/core/opt/*/")

-- Guarantee columns/lines deterministic for geometry tests
vim.o.columns = 120
vim.o.lines = 40
