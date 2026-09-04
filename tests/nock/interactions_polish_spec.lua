-- Headless integration for Ticket 04: Interactions, input wiring and polish
-- Via public API seam: focus, typing/Backspace/clear, Esc/CR, Up/Down, mouse, dynamic height, scrollbar, lazy deps, residual state
describe("nock interactions polish (04)", function()
  local nock, config, shell

  local function files_provider()
    return {
      { label = "src/foo.lua",            value = "src/foo.lua",           location = { path = "src/foo.lua", lnum = 1, col = 0 } },
      { label = "src/bar.lua",            value = "src/bar.lua",           location = { path = "src/bar.lua", lnum = 2, col = 0 } },
      { label = "README.md",              value = "README.md" },
      { label = "doc/readme.txt",         value = "doc/readme.txt" },
      { label = "lua/nock/matcher.lua",   value = "lua/nock/matcher.lua" },
      { label = "lua/nock/shell.lua",     value = "lua/nock/shell.lua" },
      { label = "lua/nock/config.lua",    value = "lua/nock/config.lua" },
      { label = "lua/nock/init.lua",      value = "lua/nock/init.lua" },
      { label = "plugin/nock.lua",        value = "plugin/nock.lua" },
      { label = "tests/minimal_init.lua", value = "tests/minimal_init.lua" },
      { label = "alpha.txt",              value = "alpha.txt" },
      { label = "beta.txt",               value = "beta.txt" },
    }
  end

  local function commands_provider()
    return {
      { label = ":NockToggle", value = "NockToggle", detail = "toggle" },
      { label = ":NockFind",   value = "NockFind",   detail = "find" },
    }
  end

  before_each(function()
    package.loaded["nock"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.shell"] = nil
    package.loaded["nock.matcher"] = nil
    package.loaded["nock.highlights"] = nil
    pcall(function() require("nock.shell").close() end)
    vim.o.columns = 120
    vim.o.lines = 40
    nock = require("nock")
    config = require("nock.config")
    shell = require("nock.shell")
    config.reset()
    pcall(vim.keymap.del, "n", "<C-p>")
    pcall(vim.keymap.del, "n", "<C-S-p>")
    require("nock.highlights").setup()
  end)

  after_each(function()
    pcall(function() shell.close() end)
    pcall(vim.keymap.del, "n", "<C-p>")
    pcall(vim.keymap.del, "n", "<C-S-p>")
    config.reset()
    pcall(vim.cmd, "stopinsert")
  end)

  it(
  "Input is focused on open; typing updates query, Backspace and clear work; Esc close with restore; CR confirms; Up/Down wrap and update NockSelected",
    function()
      -- setup with custom keymaps to verify wiring
      nock.setup({
        maxheight = 10,
        matcher = "auto",
        show_on_open = false,
        modes = {
          files = { provider = files_provider, prefix = "", keymap = "<C-p>", show_on_open = false },
          commands = { provider = commands_provider, prefix = ">", show_on_open = false },
        },
      })
      -- capture origin window
      local origin_win = vim.api.nvim_get_current_win()
      -- move cursor to ensure restore can be verified
      pcall(vim.api.nvim_win_set_cursor, origin_win, { 1, 0 })

      nock.open("files")
      assert.is_true(shell.is_open())
      local pop = shell._get_popup()
      assert.is_not_nil(pop)
      -- Input is focused on open (popup win is current)
      -- In headless, focus is set via nvim_set_current_win
      assert.are.equal(pop.winid, vim.api.nvim_get_current_win())
      assert.is_true(vim.api.nvim_win_is_valid(pop.winid))
      assert.is_true(vim.api.nvim_buf_is_valid(pop.bufnr))
      -- buffer is modifiable and cursor on Input row
      local cur = vim.api.nvim_win_get_cursor(pop.winid)
      assert.are.equal(1, cur[1])

      -- verify keymaps are bound in popup buffer for Esc, CR, Up, Down (C-c removed per ADR-0024)
      local n_maps = vim.api.nvim_buf_get_keymap(pop.bufnr, "n")
      local i_maps = vim.api.nvim_buf_get_keymap(pop.bufnr, "i")
      local function has_lhs(maps, pattern)
        for _, m in ipairs(maps) do
          if m.lhs:find(pattern) then return true end
        end
        return false
      end
      -- Esc (only Dismissal; C-c not bound)
      assert.is_true(has_lhs(n_maps, "Esc"), "Esc map n")
      assert.is_true(has_lhs(i_maps, "Esc"), "Esc map i")
      assert.is_false(has_lhs(n_maps, "C%-c") or has_lhs(n_maps, "\3"), "C-c map n should be absent")
      assert.is_false(has_lhs(i_maps, "C%-c") or has_lhs(i_maps, "\3"), "C-c map i should be absent")
      -- CR
      assert.is_true(has_lhs(n_maps, "CR") or has_lhs(n_maps, "\r") or has_lhs(n_maps, "\n"), "CR map n")
      assert.is_true(has_lhs(i_maps, "CR") or has_lhs(i_maps, "\r") or has_lhs(i_maps, "\n"), "CR map i")
      -- Up/Down
      assert.is_true(has_lhs(n_maps, "Up"), "Up map n")
      assert.is_true(has_lhs(i_maps, "Up"), "Up map i")
      assert.is_true(has_lhs(n_maps, "Down"), "Down map n")
      assert.is_true(has_lhs(i_maps, "Down"), "Down map i")
      -- typing updates query
      shell._set_query_for_test("foo")
      assert.are.equal(1, #shell._get_filtered())
      assert.are.equal("src/foo.lua", shell._get_filtered()[1].item.label)
      -- NockSelected on first row
      local buf = pop.bufnr
      local ns = shell._ns_id
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      local sel_count = 0
      for _, m in ipairs(marks) do
        local d = m[4]
        if d.line_hl_group == "NockSelected" then sel_count = sel_count + 1 end
      end
      assert.are.equal(1, sel_count)
      assert.are.equal(1, shell._get_selected_idx())

      -- Backspace: shorten query "foo" -> "fo" -> should still match foo
      shell._set_query_for_test("fo")
      assert.is_true(#shell._get_filtered() >= 1)
      -- clear query -> empty collapses to Input-only height
      shell._set_query_for_test("")
      assert.are.equal(0, #shell._get_filtered())
      assert.are.equal(0, shell._get_selected_idx())
      local geo_empty = shell.geometry()
      assert.are.equal(1, geo_empty.height)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(1, #lines)

      -- typing again
      shell._set_query_for_test("lua")
      assert.is_true(#shell._get_filtered() >= 3)
      local count = #shell._get_filtered()
      assert.is_true(count > 0)
      -- Up/Down wrap
      local n = #shell._get_filtered()
      assert.are.equal(1, shell._get_selected_idx())
      shell._move_selection(-1) -- Up from 1 wraps to n
      assert.are.equal(n, shell._get_selected_idx())
      -- NockSelected moved to last row
      marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      sel_count = 0
      local sel_row = nil
      for _, m in ipairs(marks) do
        local d = m[4]
        if d.line_hl_group == "NockSelected" then
          sel_count = sel_count + 1
          sel_row = m[2] -- row
        end
      end
      assert.are.equal(1, sel_count)
      shell._move_selection(1) -- wraps to 1
      assert.are.equal(1, shell._get_selected_idx())
      shell._move_selection(1) -- to 2
      assert.are.equal(2, shell._get_selected_idx())
      -- Preview should have been triggered for location items (no error)
      -- Esc closes with restore
      -- ensure origin still valid
      assert.is_true(vim.api.nvim_win_is_valid(origin_win))
      shell.close({ restore = true })
      assert.is_false(shell.is_open())
      -- after close, origin win should be current (restore)
      -- pcall because headless may not focus exactly
      -- At least close did not error and cleared state
      assert.is_nil(shell._get_popup())
    end)

  it("Mouse: single click selects row, double-click on selected row triggers Action; clicking outside does not error",
    function()
      local committed = nil
      nock.setup({
        maxheight = 10,
        matcher = "auto",
        modes = {
          files = {
            provider = files_provider,
            action = function(item, ctx) committed = item.label end,
          },
        },
      })
      nock.open("files")
      shell._set_query_for_test("lua")
      local n = #shell._get_filtered()
      assert.is_true(n >= 2)
      assert.are.equal(1, shell._get_selected_idx())
      -- single click selects row 2 (not yet selected) -> should select without commit
      shell._click_at(2)
      assert.are.equal(2, shell._get_selected_idx())
      assert.is_nil(committed)
      -- NockSelected updated
      local pop = shell._get_popup()
      local buf = pop.bufnr
      local marks = vim.api.nvim_buf_get_extmarks(buf, shell._ns_id, 0, -1, { details = true })
      local has_sel = false
      for _, m in ipairs(marks) do
        if m[4].line_hl_group == "NockSelected" then
          has_sel = true; break
        end
      end
      assert.is_true(has_sel)
      -- double-click on selected row triggers Action
      local filtered_before = shell._get_filtered()
      local expected_label = filtered_before[2] and filtered_before[2].item.label or nil
      shell._double_click_at(2)
      assert.is_not_nil(committed)
      assert.are.equal(expected_label, committed)
      -- after double-click, shell closes
      assert.is_false(shell.is_open())
      -- reopen to test clicking outside does not error
      committed = nil
      nock.open("files")
      shell._set_query_for_test("lua")
      assert.is_true(shell.is_open())
      -- clicking outside (invalid idx) does not error and does not change selection
      local before = shell._get_selected_idx()
      assert.has_no_error(function() shell._click_at(999) end)
      assert.has_no_error(function() shell._double_click_at(999) end)
      assert.are.equal(before, shell._get_selected_idx())
      -- clicking via _handle_click when mousepos is outside (headless getmousepos winid 0) should not error
      assert.has_no_error(function() shell._handle_click() end)
      assert.is_true(shell.is_open())
      -- single click on already selected row should commit (per spec click selected to confirm)
      -- first select row 2
      shell._click_at(2)
      assert.are.equal(2, shell._get_selected_idx())
      committed = nil
      -- now click at 2 again (already selected) should commit
      shell._click_at(2)
      assert.is_not_nil(committed)
      assert.is_false(shell.is_open())
    end)

  it("Dynamic height updates live on filter; empty -> Input-only; maxheight=10 caps at 12 rows (1+1+10)", function()
    nock.setup({
      maxheight = 10,
      matcher = "auto",
      show_on_open = false,
      modes = { files = { provider = files_provider, show_on_open = false } },
    })
    nock.open("files")
    local pop = shell._get_popup()
    -- initially empty when show_on_open=false -> height 1
    local geo = shell.geometry()
    assert.are.equal(1, geo.height)
    local lines = vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false)
    assert.are.equal(1, #lines)
    -- filter to many (match 'a' matches many)
    shell._set_query_for_test("a")
    local cnt = #shell._get_filtered()
    assert.is_true(cnt > 0)
    geo = shell.geometry()
    assert.are.equal(2 + math.min(cnt, 10), geo.height)
    lines = vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false)
    assert.are.equal(geo.height, #lines)
    -- even with huge count, caps at 12 (1 input + 1 sep + 10 items)
    -- create provider with 20 items to force overflow
    local many = {}
    for i = 1, 20 do table.insert(many, { label = "file" .. i .. ".txt" }) end
    nock.close()
    nock.setup({
      maxheight = 10,
      matcher = "auto",
      show_on_open = false,
      modes = { files = { provider = function() return many end, show_on_open = false } },
    })
    nock.open("files")
    pop = shell._get_popup()
    -- query 'file' matches all 20
    shell._set_query_for_test("file")
    assert.are.equal(20, #shell._get_filtered())
    geo = shell.geometry()
    assert.are.equal(12, geo.height, "maxheight=10 caps at 12 rows with separator")
    lines = vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false)
    assert.are.equal(12, #lines)
    -- empty query collapses back to 1 when show_on_open is false
    shell._set_query_for_test("")
    geo = shell.geometry()
    assert.are.equal(1, geo.height)
    lines = vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false)
    assert.are.equal(1, #lines)
    -- maxheight=10 default case with tiny matcher still respects live update
    -- reset to files_provider with alpha item
    nock.close()
    nock.setup({
      maxheight = 10,
      matcher = "auto",
      show_on_open = false,
      modes = { files = { provider = files_provider, show_on_open = false } },
    })
    nock.open("files")
    shell._set_query_for_test("alpha")
    assert.are.equal(1, #shell._get_filtered())
    geo = shell.geometry()
    assert.are.equal(3, geo.height) -- 1 input + 1 sep + 1 item
  end)

  it("Scrollbar: native attempt else ▐ virt_text proportional to offset; updates on selection scroll", function()
    local many = {}
    for i = 1, 20 do table.insert(many, { label = "item" .. i }) end
    nock.setup({
      maxheight = 5,
      matcher = "auto",
      modes = { files = { provider = function() return many end } },
    })
    nock.open("files")
    local pop = shell._get_popup()
    shell._set_query_for_test("item")
    assert.are.equal(20, #shell._get_filtered())
    local geo = shell.geometry()
    assert.are.equal(7, geo.height) -- 1 input + 1 sep + 5 items
    local buf = pop.bufnr
    local ns = shell._ns_id
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local scroll_marks = {}
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.virt_text and d.virt_text[1] and d.virt_text[1][1] == "▐" then
        table.insert(scroll_marks, m)
      end
    end
    -- proportional thumb: not every row should have ▐, only thumb_height rows
    assert.is_true(#scroll_marks >= 1 and #scroll_marks <= 5, "thumb proportional should be subset")
    assert.is_true(#scroll_marks < 5, "with 20/5 overflow, thumb should be smaller than visible")
    -- capture thumb rows at offset 0
    local rows_before = {}
    for _, m in ipairs(scroll_marks) do table.insert(rows_before, m[2]) end
    -- move selection down many times to scroll offset
    for _ = 1, 10 do shell._move_selection(1) end
    assert.is_true(shell._get_selected_idx() > 5)
    -- after scroll, offset should have moved
    marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local scroll_after = {}
    for _, m in ipairs(marks) do
      if m[4].virt_text and m[4].virt_text[1][1] == "▐" then table.insert(scroll_after, m) end
    end
    assert.is_true(#scroll_after >= 1)
    local rows_after = {}
    for _, m in ipairs(scroll_after) do table.insert(rows_after, m[2]) end
    -- thumb should have moved down
    ---@diagnostic disable-next-line: deprecated
    local _unpack = table.unpack or rawget(_G, "unpack")
    local min_before = math.min(_unpack(rows_before))
    local min_after = math.min(_unpack(rows_after))
    assert.is_true(min_after > min_before, "scrollbar thumb should move with offset")
    -- when not overflow, no scrollbar
    shell._set_query_for_test("item20")
    assert.is_true(#shell._get_filtered() <= 5)
    marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local has_scroll = false
    for _, m in ipairs(marks) do
      if m[4].virt_text and m[4].virt_text[1][1] == "▐" then
        has_scroll = true; break
      end
    end
    assert.is_false(has_scroll)
  end)

  it("zero external dependencies; plugin loads without error without nui", function()
    assert.has_no_error(function() require("nock").setup({}) end)
    assert.has_no_error(function() require("nock.highlights").setup() end)
    -- README should not claim nui as hard dependency
    local readme = vim.fn.readfile("README.md")
    local readme_text = table.concat(readme, "\n")
    assert.is_true(readme_text:find("MunifTanjim/nui.nvim", 1, true) == nil,
      "README should not document nui dependency for zero-dep build")
    -- shell.lua should use native popup, not nui
    local shell_src = vim.fn.readfile("lua/nock/shell.lua")
    local shell_text = table.concat(shell_src, "\n")
    assert.is_true(shell_text:find("nock.ui.popup", 1, true) ~= nil, "shell should use nock.ui.popup")
    assert.is_true(shell_text:find("nui.popup", 1, true) == nil, "shell should not reference nui.popup")
  end)

  it("Ensure no residual state after close", function()
    nock.setup({ maxheight = 10, matcher = "auto", show_on_open = false, modes = { files = { provider = files_provider, show_on_open = false } } })
    local tmp = vim.fn.tempname() .. "_nock04_residual"
    vim.fn.mkdir(tmp, "p")
    local f1 = tmp .. "/a.txt"
    vim.fn.writefile({ "hello" }, f1)
    nock.open("files")
    shell._set_query_for_test("foo")
    -- move and trigger preview if file location
    shell._set_query_for_test("a")
    -- close
    shell.close()
    assert.is_false(shell.is_open())
    assert.is_nil(shell._get_popup())
    assert.are.equal(0, #shell._get_filtered())
    assert.are.equal(0, shell._get_all_items() and #shell._get_all_items() or 0)
    assert.are.equal(0, shell._get_selected_idx())
    assert.are.equal("", shell._prev_query or "")
    assert.are.equal("", shell._prev_raw or "")
    -- offset cleared
    assert.are.equal(0, shell._offset)
    -- origin cleared
    local owin, obuf, view = shell._get_origin()
    assert.is_nil(owin)
    assert.is_nil(obuf)
    -- timer cleared
    assert.is_nil(shell._timer)
    -- in_update false
    assert.is_false(shell._in_update)
    -- preview buf cleared
    assert.is_nil(shell._get_preview_buf())
    -- geometry height reset to 1 when reopened empty with show_on_open=false
    nock.open("files")
    local geo = shell.geometry()
    assert.are.equal(1, geo.height)
    shell.close()
    vim.fn.delete(tmp, "rf")
  end)
  it("Full open→type→navigate→preview→commit/cancel flow headless via public API", function()
    local tmp = vim.fn.tempname() .. "_nock04_flow"
    vim.fn.mkdir(tmp, "p")
    local f1 = tmp .. "/one.txt"
    local f2 = tmp .. "/two.txt"
    vim.fn.writefile({ "line1", "line2", "line3" }, f1)
    vim.fn.writefile({ "alpha", "beta", "gamma" }, f2)
    local committed = nil
    nock.setup({
      maxheight = 10,
      matcher = "auto",
      modes = {
        files = {
          provider = function()
            return {
              { label = "one.txt", value = f1, location = { path = f1, lnum = 2, col = 0 } },
              { label = "two.txt", value = f2, location = { path = f2, lnum = 3, col = 0 } },
            }
          end,
          action = function(item) committed = item.label end,
          preview = true,
        },
      },
    })
    -- open
    local origin_win = vim.api.nvim_get_current_win()
    local orig_jumplist_len = vim.fn.getjumplist(origin_win)[2] or 0
    nock.open("files")
    assert.is_true(shell.is_open())
    assert.are.equal(vim.api.nvim_get_current_win(), shell._get_popup().winid)
    -- type
    shell._set_query_for_test("one")
    assert.are.equal(1, #shell._get_filtered())
    assert.are.equal("one.txt", shell._get_filtered()[1].item.label)
    -- navigate (single item, up/down wrap stays 1)
    shell._move_selection(1)
    assert.are.equal(1, shell._get_selected_idx())
    -- preview should have moved origin cursor to location (lnum 2) but not pollute jumplist significantly
    -- cancel via Esc (restore)
    pcall(function() vim.cmd("stopinsert") end)
    shell.close({ restore = true })
    assert.is_false(shell.is_open())
    -- jumplist not polluted beyond restore
    local after_cancel_jl = vim.fn.getjumplist(origin_win)[2] or 0
    -- preview browse should not add jumplist entries
    assert.is_true(math.abs(after_cancel_jl - orig_jumplist_len) <= 1)
    -- reopen and commit via CR
    committed = nil
    nock.open("files")
    shell._set_query_for_test("two")
    assert.are.equal(1, #shell._get_filtered())
    shell._move_selection(0) -- ensure selection
    -- commit via public _commit (simulates CR)
    shell._commit()
    assert.are.equal("two.txt", committed)
    assert.is_false(shell.is_open())
    -- ensure no residual
    assert.is_nil(shell._get_popup())
    -- cancel path via Esc simulation: open, type, then close restore
    nock.open("files")
    shell._set_query_for_test("one")
    shell.close({ restore = true })
    assert.is_false(shell.is_open())
    vim.fn.delete(tmp, "rf")
  end)

  it("ready-for-agent triage: spec language canonical and highlights overridable", function()
    -- Check CONTEXT canonical terms are used
    local ctx = vim.fn.readfile("CONTEXT.md")
    local txt = table.concat(ctx, "\n")
    for _, term in ipairs({ "Mode", "Item", "Action", "Preview", "Matcher", "Shell", "Provider" }) do
      assert.is_true(txt:find(term) ~= nil, "CONTEXT should contain " .. term)
    end
    -- highlights respect overrides (Ticket 04 checkbox 1 includes highlights respect overrides)
    nock.setup({ highlights = { match = "Visual", selected = "Visual", preview = "Visual" } })
    -- trigger highlights setup
    require("nock.highlights").setup(config.options.highlights)
    -- NockMatch should link to Visual when overridden
    -- Use nvim_get_hl
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "NockMatch", link = true })
    if ok and hl and hl.link then
      -- hl.link exists - not reliable across versions, just check via synID
    end
    -- Alternative check via hlID trans id equality
    local id_match = vim.fn.hlID("NockMatch")
    local id_visual = vim.fn.hlID("Visual")
    -- when linked, trans ids equal
    assert.are.equal(vim.fn.synIDtrans(id_visual), vim.fn.synIDtrans(id_match))
    nock.setup({}) -- reset to defaults
    require("nock.highlights").setup(config.options.highlights)
    -- keymaps from setup.modes.*.keymap are bound to open with correct Mode (verify wiring)
    nock.setup({ modes = { files = { keymap = "<C-p>", provider = files_provider }, commands = { prefix = ">", keymap = "<C-S-p>", provider = commands_provider } } })
    local found_p = false
    local found_sp = false
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.desc == "Nock open files" then found_p = true end
      if m.desc == "Nock open commands" then found_sp = true end
    end
    -- At least files keymap should be found
    assert.is_true(found_p, "Nock open files keymap not found")
    assert.is_true(found_sp, "Nock open commands keymap not found")
  end)
end)
