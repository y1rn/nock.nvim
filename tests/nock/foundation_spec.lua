-- Headless integration test for Ticket 01: foundation Shell, setup and Mode registry
-- Drives public API seam: setup -> open/close -> register_mode -> highlights -> keymaps -> geometry

describe("nock foundation (01)", function()
  local nock, config, shell

  before_each(function()
    -- Ensure clean state
    package.loaded["nock"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.shell"] = nil
    package.loaded["nock.highlights"] = nil

    -- Close any lingering Shell
    pcall(function()
      local s = require("nock.shell")
      s.close()
    end)

    -- Reset columns/lines for deterministic geometry
    vim.o.columns = 120
    vim.o.lines = 40

    nock = require("nock")
    config = require("nock.config")
    shell = require("nock.shell")

    config.reset()
    -- Clear keymaps we will test (all modes)
    for _, m in ipairs({ "n", "i", "v", "x", "c", "t" }) do
      pcall(vim.keymap.del, m, "<C-p>")
      pcall(vim.keymap.del, m, "<C-S-p>")
      pcall(vim.keymap.del, m, "<leader>tt")
    end
  end)

  after_each(function()
    -- Teardown: close Shell and reset
    pcall(function()
      shell.close()
    end)
    pcall(vim.keymap.del, "n", "<C-p>")
    pcall(vim.keymap.del, "n", "<C-S-p>")
    pcall(vim.keymap.del, "n", "<leader>tt")
    config.reset()
  end)

  it("setup deep-merges maxheight, matcher, highlights and modes over built-ins", function()
    -- default state
    assert.are.equal(10, config.options.maxheight)
    assert.are.equal("auto", config.options.matcher)
    assert.are.equal("Search", config.options.highlights.match)

    -- Setup with partial overrides: maxheight and one mode keymap, matcher custom
    nock.setup({
      maxheight = 15,
      matcher = "vim.fn",
      highlights = { match = "ErrorMsg" },
      modes = {
        files = { keymap = "<leader>ff" },
      },
    })

    assert.are.equal(15, config.options.maxheight)
    assert.are.equal("vim.fn", config.options.matcher)
    -- highlights partial merge: match overridden, others preserved
    assert.are.equal("ErrorMsg", config.options.highlights.match)
    assert.are.equal("CursorLine", config.options.highlights.selected)
    assert.are.equal("IncSearch", config.options.highlights.preview)

    -- modes.files keymap overridden, provider/action preserved
    assert.are.equal("<leader>ff", config.options.modes.files.keymap)
    assert.is_not_nil(config.options.modes.files.provider)
    assert.is_not_nil(config.options.modes.files.action)
    -- commands mode is no longer a built-in default
    assert.is_nil(config.options.modes.commands)
  end)

  it("register_mode hot-plugs and duplicate name overwrites", function()
    nock.setup({})

    nock.register_mode("buffers", {
      prefix = ";",
      keymap = "<leader>tt",
      provider = function(_, _, cb)
        cb({ { label = "a", value = "a" } })
        return nil
      end,
    })

    assert.is_not_nil(config.options.modes.buffers)
    assert.are.equal(";", config.options.modes.buffers.prefix)

    -- open the newly registered mode
    nock.open("buffers")
    assert.is_true(shell.is_open())
    assert.are.equal("buffers", shell._get_current_mode())
    nock.close()
    assert.is_false(shell.is_open())

    -- duplicate overwrites
    nock.register_mode("buffers", { prefix = "," })
    assert.are.equal(",", config.options.modes.buffers.prefix)
    -- provider should still be present (deep_extend preserved)
    assert.is_not_nil(config.options.modes.buffers.provider)
  end)

  it("open()/open('files')/open('commands') opens one nui.popup with correct geometry; close() tears down", function()
    nock.setup({})
    -- open() defaults to files
    local popup = nock.open()
    assert.is_not_nil(popup)
    assert.is_true(shell.is_open())
    assert.are.equal("files", shell._get_current_mode())

    -- Geometry checks: 30% width clamped 40-80, row 0 (pinned top), col centered
    local cols = vim.o.columns -- 120
    local expected_width = math.floor(cols * 0.3)
    expected_width = math.max(40, math.min(80, expected_width)) -- 40
    local expected_row = 0 -- pinned top
    local expected_col = math.floor((cols - expected_width) / 2) -- 40
    local count = #shell._get_filtered()
    local expected_height = count > 0 and (2 + math.min(count, 10)) or 1
    -- Win config via nvim_win_get_config
    local winid = popup.winid
    assert.is_true(vim.api.nvim_win_is_valid(winid))
    local win_cfg = vim.api.nvim_win_get_config(winid)
    assert.are.equal(expected_width, win_cfg.width)
    assert.are.equal(expected_height, win_cfg.height)
    assert.are.equal(expected_row, win_cfg.row)
    assert.are.equal(expected_col, win_cfg.col)
    -- native border rounded style (nvim returns 8-string array)
    local border_style = win_cfg.border
    if type(border_style) == "string" then
      assert.are.equal("rounded", border_style)
    else
      assert.are.equal("table", type(border_style))
      local first = border_style[1]
      if type(first) == "table" then
        assert.are.equal("╭", first[1])
      else
        assert.are.equal("╭", first)
      end
    end
    -- Input row 1: buffer has query on line 1
    local bufnr = popup.bufnr
    local lines_buf = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
    assert.are.equal("", lines_buf[1])

    -- open custom mode while already open switches in-place (same single popup)
    nock.register_mode("custom", { prefix = ">", provider = function(_, _, cb) cb({}); return nil end })
    local prev_win = winid
    local popup2 = nock.open("custom")
    assert.are.equal(prev_win, popup2.winid)
    assert.is_true(shell.is_open())
    assert.are.equal("custom", shell._get_current_mode())
    local lines_buf2 = vim.api.nvim_buf_get_lines(popup2.bufnr, 0, 1, false)
    assert.are.equal(">", lines_buf2[1])
    -- still correct geometry/border
    local cfg2 = vim.api.nvim_win_get_config(popup2.winid)
    assert.are.equal(expected_width, cfg2.width)
    do
      local b2_style = cfg2.border
      if type(b2_style) == "string" then
        assert.are.equal("rounded", b2_style)
      else
        local first = b2_style[1]
        if type(first) == "table" then
          assert.are.equal("╭", first[1])
        else
          assert.are.equal("╭", first)
        end
      end
    end
    -- open("files") explicitly
    nock.open("files")
    assert.are.equal("files", shell._get_current_mode())
    assert.is_true(shell.is_open())
    local is_open_valid = shell.is_open() and popup.winid and vim.api.nvim_win_is_valid(popup.winid)
    assert.is_true(is_open_valid)

    -- close() tears down without error, idempotent
    nock.close()
    assert.is_false(shell.is_open())
    assert.has_no.errors(function()
      nock.close()
    end)
    -- popup reference cleared
    assert.is_nil(shell._get_popup())
  end)

  it("width clamp 40-80: narrow, mid and wide editors, plus custom width/row override", function()
    nock.setup({})

    -- Narrow: columns 80 -> 24 -> clamp 40
    vim.o.columns = 80
    local p1 = nock.open()
    local c1 = vim.api.nvim_win_get_config(p1.winid)
    assert.are.equal(40, c1.width)
    assert.are.equal(0, c1.row) -- pinned top
    nock.close()

    -- Mid: 200 -> 60 stays 60
    vim.o.columns = 200
    local p2 = nock.open()
    local c2 = vim.api.nvim_win_get_config(p2.winid)
    assert.are.equal(60, c2.width)
    assert.are.equal(0, c2.row)
    nock.close()

    -- Wide: 300 -> 90 -> clamp 80
    vim.o.columns = 300
    local p3 = nock.open()
    local c3 = vim.api.nvim_win_get_config(p3.winid)
    assert.are.equal(80, c3.width)
    assert.are.equal(0, c3.row)
    nock.close()

    -- Custom width/row via setup
    nock.setup({ width = 0.5, row = 4 })
    vim.o.columns = 120
    local p4 = nock.open()
    local c4 = vim.api.nvim_win_get_config(p4.winid)
    assert.are.equal(60, c4.width) -- 120 * 0.5 = 60
    assert.are.equal(4, c4.row)
    -- restore
    vim.o.columns = 120
  end)

  it("keymaps from setup.modes.*.keymap are bound to open with correct Mode", function()
    nock.setup({
      modes = {
        files = { keymap = "<C-p>" },
        custom = { prefix = ">", keymap = "<C-S-p>", provider = function(_, _, cb) cb({}); return nil end },
      },
    })

    -- For <C-p> mapping: exists as <C-p> or <C-P>
    local found_cp = false
    local found_csp = false
    for _, mode in ipairs({ "n", "i", "v", "x", "c", "t" }) do
      for _, km in ipairs(vim.api.nvim_get_keymap(mode)) do
        if km.desc == "Nock open files" then found_cp = true end
        if km.desc == "Nock open custom" then found_csp = true end
      end
    end
    -- at least n must have it (backward compat), and at least one of i/v/x/c/t should also have it (all-mode)
    assert.is_true(found_cp, "Nock open files keymap not found in all modes")
    assert.is_true(found_csp, "Nock open custom keymap not found in all modes")
    -- ensure n specifically still bound (old expectation)
    local found_n = false
    for _, km in ipairs(vim.api.nvim_get_keymap("n")) do
      if km.desc == "Nock open files" then found_n = true end
    end
    assert.is_true(found_n)
    -- Custom mode keymap via register_mode also bound (all modes)
    nock.register_mode("custom", { keymap = "<leader>tt", provider = function(_, _, cb) cb({}); return nil end })
    local found_custom = false
    local has_tt = false
    for _, mode in ipairs({ "n", "i", "v", "x", "c", "t" }) do
      for _, km in ipairs(vim.api.nvim_get_keymap(mode)) do
        if km.desc == "Nock open custom" then found_custom = true end
        if km.lhs:find("tt") then has_tt = true end
      end
    end
    assert.is_true(found_custom, "custom mode keymap not bound in all modes")
    assert.is_true(has_tt)
  end)

  it("highlights NockMatch->Search etc default links created, overridable", function()
    -- Default after setup
    nock.setup({})
    -- nvim_get_hl returns {link="Search"} or similar; fallback check via hlexists
    assert.is_true(vim.fn.hlexists("NockMatch") == 1)
    assert.is_true(vim.fn.hlexists("NockSelected") == 1)
    assert.is_true(vim.fn.hlexists("NockPreview") == 1)

    -- Verify link target is Search/CursorLine/IncSearch by inspecting hl definition
    -- Use nvim_get_hl with link=true
    -- When linked, nvim_get_hl without link flag resolves; we check via synIDtrans
    -- Simpler: check that highlight link exists via vim.api.nvim_get_hl(0,{name="NockMatch",link=true}).link
    -- Some nvim versions return empty if not linked? Fall back to hlID
    -- Use vim.fn.synIDattr to get link?
    -- We'll assert hlID translation: hlID("NockMatch") trans to Search
    local id_match = vim.fn.hlID("NockMatch")
    local trans_match = vim.fn.synIDtrans(id_match)
    local trans_search = vim.fn.synIDtrans(vim.fn.hlID("Search"))
    assert.are.equal(trans_search, trans_match)

    local id_sel = vim.fn.hlID("NockSelected")
    assert.are.equal(vim.fn.synIDtrans(vim.fn.hlID("CursorLine")), vim.fn.synIDtrans(id_sel))

    local id_prev = vim.fn.hlID("NockPreview")
    assert.are.equal(vim.fn.synIDtrans(vim.fn.hlID("IncSearch")), vim.fn.synIDtrans(id_prev))

    -- Overridable via setup(highlights)
    nock.setup({
      highlights = { match = "ErrorMsg", selected = "Visual", preview = "Search" },
    })
    local id_match2 = vim.fn.hlID("NockMatch")
    assert.are.equal(vim.fn.synIDtrans(vim.fn.hlID("ErrorMsg")), vim.fn.synIDtrans(id_match2))
    local id_sel2 = vim.fn.hlID("NockSelected")
    assert.are.equal(vim.fn.synIDtrans(vim.fn.hlID("Visual")), vim.fn.synIDtrans(id_sel2))
  end)

  it("matcher/provider stubs retained for later tickets", function()
    nock.setup({})
    -- config matcher default
    assert.are.equal("auto", config.options.matcher)
    -- modes have provider stubs returning Item[]
    local got, done
    config.options.modes.files.provider("", {}, function(items) got = items; done = true end)
    vim.wait(2000, function() return done end)
    assert.is_not_nil(got)
    assert.are.equal("table", type(got))
    -- action is callable
    assert.are.equal("function", type(config.options.modes.files.action))
  end)
end)
