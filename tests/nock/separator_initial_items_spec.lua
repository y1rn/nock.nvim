-- Tests for separator line, initial items with MRU, and completion engine isolation (ADR-0004)
describe("nock separator, initial items and completion isolation", function()
  local nock, config, shell, highlights

  before_each(function()
    package.loaded["nock"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.shell"] = nil
    package.loaded["nock.highlights"] = nil
    package.loaded["nock.providers.files"] = nil

    pcall(function()
      local s = require("nock.shell")
      s.close({ restore = true })
    end)

    vim.o.columns = 120
    vim.o.lines = 40

    nock = require("nock")
    config = require("nock.config")
    shell = require("nock.shell")
    highlights = require("nock.highlights")
    config.reset()
  end)

  after_each(function()
    pcall(function() shell.close({ restore = true }) end)
    config.reset()
  end)

  it("default open shows initial items and physical separator line without triggering preview jump", function()
    local items = {
      { label = "src/app.lua", location = { path = "src/app.lua", lnum = 10, col = 0 } },
      { label = "src/main.lua", location = { path = "src/main.lua", lnum = 20, col = 0 } },
      { label = "README.md", location = { path = "README.md", lnum = 1, col = 0 } },
    }

    nock.setup({
      modes = {
        files = {
          provider = function() return items end,
          preview = true,
          show_on_open = true,
        },
      },
    })

    -- Origin window cursor at (1, 0)
    local cur_win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_cursor, cur_win, { 1, 0 })

    nock.open("files")
    assert.is_true(shell.is_open())

    -- Initial filtered count is 3
    local filtered = shell._get_filtered()
    assert.are.equal(3, #filtered)
    assert.are.equal(1, shell._get_selected_idx())

    -- Height formula: 1(input) + 1(sep) + 3(items) = 5
    local geo = shell.geometry()
    assert.are.equal(5, geo.height)

    local pop = shell._get_popup()
    local buf = pop.bufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(5, #lines)
    assert.are.equal("", vim.trim(lines[1])) -- line 1: empty query
    assert.is_true(lines[2]:find("─") ~= nil) -- line 2: separator
    assert.are.equal("src/app.lua", vim.trim(lines[3])) -- line 3: item 1
    assert.are.equal("src/main.lua", vim.trim(lines[4]))
    assert.are.equal("README.md", vim.trim(lines[5]))

    -- Check NockSeparator highlight on row 1 (0-indexed line 2)
    local marks = vim.api.nvim_buf_get_extmarks(buf, shell._ns_id, 0, -1, { details = true })
    local has_separator = false
    local has_selected = false
    for _, m in ipairs(marks) do
      local row, det = m[2], m[4]
      if det.line_hl_group == "NockSeparator" then
        has_separator = true
        assert.are.equal(1, row)
      end
      if det.line_hl_group == "NockSelected" then
        has_selected = true
        assert.are.equal(2, row) -- item 1 is at row 2
      end
    end
    assert.is_true(has_separator, "NockSeparator extmark should be on line 2")
    assert.is_true(has_selected, "NockSelected extmark should be on line 3 (row 2)")

    -- Preview should NOT have moved origin window cursor on initial open
    local cur_after = vim.api.nvim_win_get_cursor(cur_win)
    assert.are.equal(1, cur_after[1])

    -- Moving selection (<Down>) actively triggers preview
    shell._move_selection(1)
    assert.are.equal(2, shell._get_selected_idx())

    nock.close()
  end)

  it("buffer options and completion engine isolation are set on popup buffer", function()
    nock.setup({})
    nock.open("files")

    local pop = shell._get_popup()
    local buf = pop.bufnr
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    -- buftype and filetype
    assert.are.equal("nofile", vim.bo[buf].buftype)
    assert.are.equal("nock_input", vim.bo[buf].filetype)

    -- completion flags
    assert.is_false(vim.b[buf].blink_cmp_enable)
    assert.is_false(vim.b[buf].completion)
    assert.are.equal("", vim.bo[buf].omnifunc)
    assert.are.equal("", vim.bo[buf].completefunc)

    nock.close()
  end)

  it("NockSeparator highlight is configurable via setup", function()
    nock.setup({
      highlights = {
        separator = "Comment",
      },
    })
    local hl = config.options.highlights
    assert.are.equal("Comment", hl.separator)
  end)

  it("files provider respects MRU prioritization", function()
    local files = require("nock.providers.files")
    -- Create dummy buffers with paths
    local b1 = vim.api.nvim_create_buf(true, false)
    local cwd = vim.fn.getcwd()
    vim.api.nvim_buf_set_name(b1, cwd .. "/lua/nock/shell.lua")
    vim.bo[b1].buflisted = true

    local items = files.provider()
    assert.is_not_nil(items)
    assert.is_true(#items > 0)
    -- First item should be lua/nock/shell.lua due to open buffer MRU priority
    assert.are.equal("lua/nock/shell.lua", items[1].label)

    pcall(vim.api.nvim_buf_delete, b1, { force = true })
  end)

  it("zero matches collapses separator and list to height 1", function()
    nock.setup({
      modes = {
        files = {
          provider = function() return { { label = "foo.txt" } } end,
        },
      },
    })
    nock.open("files")
    assert.are.equal(3, shell.geometry().height) -- 1 input + 1 sep + 1 item

    -- Query matching nothing collapses
    shell._set_query_for_test("nonexistent_query_xyz")
    assert.are.equal(0, #shell._get_filtered())
    local geo = shell.geometry()
    assert.are.equal(1, geo.height)

    local pop = shell._get_popup()
    local lines = vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false)
    assert.are.equal(1, #lines)
    assert.are.equal("nonexistent_query_xyz", vim.trim(lines[1]))

    nock.close()
  end)

  it("scrollbar virt_text uses NockScrollbar highlight instead of NockSelected", function()
    local many = {}
    for i = 1, 20 do table.insert(many, { label = "item" .. i }) end
    nock.setup({
      maxheight = 5,
      highlights = {
        scrollbar = "Comment",
      },
      modes = {
        files = {
          provider = function() return many end,
        },
      },
    })
    nock.open("files")
    local pop = shell._get_popup()
    local buf = pop.bufnr
    local ns = shell._ns_id
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local has_scroll_with_nock_scrollbar = false
    local has_scroll_with_nock_selected = false
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.virt_text and d.virt_text[1] and d.virt_text[1][1] == "▐" then
        if d.virt_text[1][2] == "NockScrollbar" then
          has_scroll_with_nock_scrollbar = true
        elseif d.virt_text[1][2] == "NockSelected" then
          has_scroll_with_nock_selected = true
        end
      end
    end
    assert.is_true(has_scroll_with_nock_scrollbar, "scrollbar should use NockScrollbar")
    assert.is_false(has_scroll_with_nock_selected, "scrollbar should NOT use NockSelected")
    nock.close()
  end)
end)
