-- Canonical test invocation (PlenaryBustedFile cannot pass init to the
-- harness child process — test_file() drops opts — so run via test_directory):
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "lua require('plenary.test_harness').test_directory('tests/nock/', {minimal_init='tests/minimal_init.lua'})"
-- Single file (in-process, same init):
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "lua require('plenary.busted').run('tests/nock/<name>_spec.lua')"

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

-- The harness (PlenaryBustedFile) reorders rtp so the installed copy at
-- site/pack/core/opt/nock.nvim would shadow the working tree (ADR-0028:
-- specs must exercise repo code). Pin the repo root first, absolutely.
-- NOTE: `:p` is required — `-u` sources this file by relative path, so a
-- bare `:h:h` yields "." and the prepend becomes a duplicate no-op.
vim.opt.rtp:remove(".")
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
-- Marker: proves to specs which init the (possibly spawned) nvim actually ran.
vim.g.nock_minimal_init = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")

-- Guarantee columns/lines deterministic for geometry tests
vim.o.columns = 120
vim.o.lines = 40
