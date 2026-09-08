-- Headless integration for Ticket 02: matcher chain and incremental filter
-- Via public API seam: setup -> open -> type query -> assert labels, extmarks, debounce, prefix, maxheight, collapse

describe("nock matcher chain and filter (02)", function()
  local nock, config, shell, matcher

  local files_items = {
    { label = "src/foo.lua" },
    { label = "src/bar.lua" },
    { label = "README.md" },
    { label = "doc/readme.txt" },
    { label = "lua/nock/matcher.lua" },
    { label = "lua/nock/shell.lua" },
    { label = "lua/nock/config.lua" },
  }
  -- Async-only contract (ADR-0028): sync delivery inside pcall keeps the
  -- shell-integration asserts below deterministic (no tick wait needed).
  local function files_provider(_, _, cb)
    cb(files_items)
    return nil
  end

  local commands_items = {
    { label = "NockToggle" },
    { label = "NockFind" },
    { label = "NockTest" },
    { label = "Edit" },
  }
  local function commands_provider(_, _, cb)
    cb(commands_items)
    return nil
  end

  before_each(function()
    package.loaded["nock"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.shell"] = nil
    package.loaded["nock.matcher"] = nil
    package.loaded["nock.highlights"] = nil
    pcall(function()
      require("nock.shell").close()
    end)
    vim.o.columns = 120
    vim.o.lines = 40
    nock = require("nock")
    config = require("nock.config")
    shell = require("nock.shell")
    matcher = require("nock.matcher")
    config.reset()
    pcall(vim.keymap.del, "n", "<C-p>")
    pcall(vim.keymap.del, "n", "<C-S-p>")
  end)

  after_each(function()
    pcall(function() shell.close() end)
    pcall(vim.keymap.del, "n", "<C-p>")
    pcall(vim.keymap.del, "n", "<C-S-p>")
    config.reset()
  end)

  it("matcher='auto' uses vim.fn.matchfuzzypos; matcher=function and matcher='vim.fn'/'native' paths work; fallback Lua fzy", function()
    local items = files_items
    -- auto should use vim.fn on 0.12.5
    local r_auto = matcher.filter("foo", items, "auto")
    assert.is_true(#r_auto >= 1)
    assert.are.equal("src/foo.lua", r_auto[1].item.label)
    assert.is_true(type(r_auto[1].score) == "number")
    assert.is_true(type(r_auto[1].positions) == "table")
    assert.is_true(#r_auto[1].positions > 0)
    -- positions are 0-indexed
    for _, p in ipairs(r_auto[1].positions) do
      assert.is_true(type(p) == "number" and p >= 0)
    end
    -- vim.fn path
    local r_vim = matcher.filter("foo", items, "vim.fn")
    assert.is_true(#r_vim >= 1)
    assert.are.equal("src/foo.lua", r_vim[1].item.label)
    -- native path fallback to lua when no native module
    local r_native = matcher.filter("foo", items, "native")
    assert.is_true(#r_native >= 1)
    -- lua path
    local r_lua = matcher.filter("foo", items, "lua")
    assert.is_true(#r_lua >= 1)
    assert.are.equal("src/foo.lua", r_lua[1].item.label)
    -- function injection
    local called = false
    local fn = function(q, it)
      called = true
      assert.are.equal("foo", q)
      return { { item = it[1], score = 99, positions = { 0 } } }
    end
    local r_fn = matcher.filter("foo", items, fn)
    assert.is_true(called)
    assert.are.equal(1, #r_fn)
    assert.are.equal(99, r_fn[1].score)
    assert.are.same({ 0 }, r_fn[1].positions)
    -- fallback when vim.fn unavailable: simulate by forcing lua
    local r_fallback = matcher._lua_fzy("foo", items)
    assert.is_true(#r_fallback >= 1)
    -- sorted score desc -> length asc: inject two items with same score manually via lua_fzy equality check
    local items2 = { { label = "aafoo" }, { label = "aafoo_longer_label" } }
    -- same query should rank shorter first if scores equal; we can test sort stability
    local r2 = matcher._lua_fzy("foo", items2)
    if #r2 == 2 and r2[1].score == r2[2].score then
      assert.is_true(#r2[1].item.label <= #r2[2].item.label)
    end
    -- via shell integration: setup matcher as function
    nock.setup({ matcher = fn, modes = { files = { provider = files_provider }, commands = { prefix = ">", provider = commands_provider } } })
    nock.open("files")
    shell._set_query_for_test("foo")
    local f = shell._get_filtered()
    assert.are.equal(1, #f)
    assert.are.equal("src/foo.lua", f[1].item.label)
    assert.are.equal(99, f[1].score)
  end)

  it("typing filters List in real time; empty query collapses List to Input-only when show_on_open=false", function()
    nock.setup({ maxheight = 10, matcher = "auto", show_on_open = false, modes = { files = { provider = files_provider, prefix = "", show_on_open = false }, commands = { provider = commands_provider, prefix = ">", show_on_open = false } } })
    nock.open("files")
    local pop = shell._get_popup()
    assert.is_not_nil(pop)
    assert.is_true(shell.is_open())
    -- empty -> height 1, no list lines beyond input
    shell._set_query_for_test("")
    assert.are.equal(0, #shell._get_filtered())
    local geo = shell.geometry()
    assert.are.equal(1, geo.height)
    local buf = pop.bufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(1, #lines)
    assert.are.equal("", vim.trim(lines[1]))
    -- typing foo filters
    shell._set_query_for_test("foo")
    assert.are.equal(1, #shell._get_filtered())
    assert.are.equal("src/foo.lua", shell._get_filtered()[1].item.label)
    geo = shell.geometry()
    assert.are.equal(3, geo.height) -- 1 input + 1 sep + 1 item
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(3, #lines)
    assert.are.equal("foo", vim.trim(lines[1]))
    assert.are.equal("src/foo.lua", vim.trim(lines[3]))
    -- clearing again collapses when show_on_open is false
    shell._set_query_for_test("")
    assert.are.equal(0, #shell._get_filtered())
    geo = shell.geometry()
    assert.are.equal(1, geo.height)
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(1, #lines)
  end)

  it("maxheight caps visible rows and scrollbar virt_text appears when overflow", function()
    nock.setup({ maxheight = 2, matcher = "auto", modes = { files = { provider = files_provider }, commands = { prefix = ">", provider = commands_provider } } })
    nock.open("files")
    local pop = shell._get_popup()
    -- query 'l' matches many (4) > maxheight 2
    shell._set_query_for_test("l")
    local filtered = shell._get_filtered()
    assert.is_true(#filtered > 2)
    local geo = shell.geometry()
    assert.are.equal(4, geo.height) -- 1 input + 1 sep + min(4,2)=4
    local buf = pop.bufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(4, #lines) -- query + sep + 2 visible
    -- scrollbar virt_text present
    local ns = shell._ns_id
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local has_scroll = false
    for _, m in ipairs(marks) do
      local det = m[4]
      if det.virt_text and det.virt_text[1] and det.virt_text[1][1] == "▐" then
        has_scroll = true
        break
      end
    end
    assert.is_true(has_scroll, "scrollbar ▐ should appear when overflow")
    -- narrow case: filtered <= maxheight no scrollbar
    shell._set_query_for_test("foo")
    assert.are.equal(1, #shell._get_filtered())
    geo = shell.geometry()
    assert.are.equal(3, geo.height) -- 1 input + 1 sep + 1 item
    marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local has_scroll2 = false
    for _, m in ipairs(marks) do
      local det = m[4]
      if det.virt_text and det.virt_text[1] and det.virt_text[1][1] == "▐" then
        has_scroll2 = true
        break
      end
    end
    assert.is_false(has_scroll2)
    -- width clamp 40-80
    assert.is_true(geo.width >= 40 and geo.width <= 80)
  end)

  it("50ms debounce and incremental re-filter do not drop keystrokes", function()
    nock.setup({ maxheight = 10, matcher = "auto", modes = { files = { provider = files_provider }, commands = { prefix = ">", provider = commands_provider } } })
    nock.open("files")
    local pop = shell._get_popup()
    local buf = pop.bufnr
    -- Use async debounce path: set buffer lines and schedule_filter
    -- simulate rapid typing: set to 'l', then quickly to 'lu', then to 'lua'
    -- Each schedule should debounce to 50ms and final should win
    -- Test incremental correctness via sync (lengthen filters previous set, shorten full set)
    shell._set_query_for_test("lua")
    assert.are.equal(5, #shell._get_filtered())
    shell._set_query_for_test("lua/")
    assert.are.equal(3, #shell._get_filtered())
    -- lengthen should have filtered subset (previous filtered size 5 -> now 3)
    shell._set_query_for_test("lu")
    assert.are.equal(5, #shell._get_filtered()) -- shorten goes back to full set => 5 again
    -- Now test debounce timer actually exists and fires
    -- Force async path: set buffer line then wait
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "foo" })
    -- on_lines schedules via vim.schedule -> schedule_filter, which starts 50ms timer
    vim.wait(80, function() return false end)
    -- after debounce interval, filtered should reflect "foo"
    -- Because on_lines is async, we wait a bit more and ensure filtered updated
    -- Use vim.wait with condition
    local ok = vim.wait(200, function()
      return #shell._get_filtered() == 1 and shell._get_filtered()[1].item.label == "src/foo.lua"
    end)
    assert.is_true(ok, "debounce should process final keystrokes without drop")
    -- rapid keystroke simulation: set quickly 3 times within debounce window, final should win
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "l" })
    vim.wait(10)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "lu" })
    vim.wait(10)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "lua" })
    vim.wait(80)
    ok = vim.wait(200, function() return #shell._get_filtered() == 5 end)
    assert.is_true(ok, "rapid typing should not drop final query")
    assert.are.equal(5, #shell._get_filtered())
  end)

  it("prefix > switches Mode within same Shell without close; clearing returns to prior", function()
    nock.setup({ maxheight = 10, matcher = "auto", show_on_open = false, modes = { files = { provider = files_provider, prefix = "", show_on_open = false }, commands = { provider = commands_provider, prefix = ">", show_on_open = false } } })
    nock.open("files")
    local pop_before = shell._get_popup()
    local win_before = pop_before.winid
    assert.are.equal("files", shell._get_current_mode())
    -- switch via prefix
    shell._set_query_for_test(">Nock")
    assert.are.equal("commands", shell._get_current_mode())
    -- same Shell instance (popup object identity / winid unchanged, is_open true, not closed)
    assert.is_true(shell.is_open())
    local pop_after = shell._get_popup()
    assert.are.equal(win_before, pop_after.winid)
    assert.are.equal(pop_before.bufnr, pop_after.bufnr)
    local filtered = shell._get_filtered()
    assert.is_true(#filtered >= 1)
    for _, e in ipairs(filtered) do
      assert.is_true(e.item.label:lower():find("nock", 1, true) ~= nil)
    end
    -- height reflects commands filtered (1 input + 1 sep + min(#filtered, 10))
    local geo = shell.geometry()
    assert.are.equal(2 + math.min(#filtered, 10), geo.height)
    -- clearing prefix returns to prior (files) with empty collapse handling when show_on_open is false
    shell._set_query_for_test(">") -- still commands but empty effective query collapses
    assert.are.equal("commands", shell._get_current_mode())
    assert.are.equal(0, #shell._get_filtered())
    shell._set_query_for_test("")
    assert.are.equal("files", shell._get_current_mode())
    assert.are.equal(0, #shell._get_filtered())
    assert.are.equal(1, shell.geometry().height)
    -- reopening commands via open('commands') also works but prefix path kept same Shell
    shell._set_query_for_test(">Test")
    assert.are.equal("commands", shell._get_current_mode())
    local f2 = shell._get_filtered()
    local found = false
    for _, e in ipairs(f2) do if e.item.label == "NockTest" then found = true end end
    assert.is_true(found)
  end)

  it("matched char positions highlighted via NockMatch extmarks; NockSelected on current row", function()
    nock.setup({ maxheight = 10, matcher = "auto", modes = { files = { provider = files_provider }, commands = { prefix = ">", provider = commands_provider } } })
    nock.open("files")
    shell._set_query_for_test("foo")
    local pop = shell._get_popup()
    local buf = pop.bufnr
    local ns = shell._ns_id
    local filtered = shell._get_filtered()
    assert.are.equal(1, #filtered)
    local expected_positions = filtered[1].positions
    assert.is_true(#expected_positions > 0)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local match_cols = {}
    local has_selected = false
    local selected_row = nil
    local has_separator = false
    for _, m in ipairs(marks) do
      local id, row, col, det = m[1], m[2], m[3], m[4]
      if det.line_hl_group == "NockSeparator" then
        has_separator = true
        assert.are.equal(1, row) -- row 1 is separator line
      end
      if det.hl_group == "NockMatch" then
        table.insert(match_cols, col)
        -- NockMatch should be on row 2 (first item row after separator)
        assert.are.equal(2, row)
      end
      if det.line_hl_group == "NockSelected" then
        has_selected = true
        selected_row = row
      end
    end
    assert.is_true(has_separator, "NockSeparator should be present")
    assert.is_true(has_selected, "NockSelected should be present")
    assert.are.equal(2, selected_row) -- item 1 is at row 2
    -- match cols should equal positions
    table.sort(match_cols)
    table.sort(expected_positions)
    assert.are.same(expected_positions, match_cols)
    shell._set_query_for_test("lua")
    assert.is_true(#shell._get_filtered() >= 2)
    marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local sel_count = 0
    for _, m in ipairs(marks) do if m[4].line_hl_group == "NockSelected" then sel_count = sel_count + 1 end end
    assert.are.equal(1, sel_count, "exactly one NockSelected row")
  end)

  it("headless test via public API seam asserts filtered labels and extmarks end-to-end", function()
    nock.setup({ maxheight = 5, matcher = "auto", modes = { files = { provider = files_provider }, commands = { prefix = ">", provider = commands_provider } } })
    -- public API open -> set query -> check filtered labels
    nock.open("files")
    assert.is_true(shell.is_open())
    shell._set_query_for_test("shell")
    local f = shell._get_filtered()
    assert.is_true(#f >= 1)
    assert.are.equal("lua/nock/shell.lua", f[1].item.label)
    -- extmarks via public shell ns
    local buf = shell._get_popup().bufnr
    local marks = vim.api.nvim_buf_get_extmarks(buf, shell._ns_id, 0, -1, { details = true })
    local hasMatch = false
    for _, m in ipairs(marks) do if m[4].hl_group == "NockMatch" then hasMatch = true end end
    assert.is_true(hasMatch)
    -- geometry clamp
    local geo = shell.geometry()
    assert.is_true(geo.width >= 40 and geo.width <= 80)
    assert.are.equal(2 + math.min(#f, 5), geo.height)
    -- close via public API
    nock.close()
    assert.is_false(shell.is_open())
  end)
end)
