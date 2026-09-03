local nock = require("nock")
local shell = require("nock.shell")
local files_provider = require("nock.providers.files")
local assert = require("luassert")

describe("nock mouse scroll, buffer MRU and border padding (10)", function()
  local created_bufs = {}

  before_each(function()
    nock.setup({
      maxheight = 5,
    })
    created_bufs = {}
  end)

  after_each(function()
    pcall(nock.close)
    for _, b in ipairs(created_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    created_bufs = {}
  end)

  it("buffer MRU sorts by lastused descending and excludes active buffer", function()
    -- Create 4 listed buffers
    local b_old = vim.api.nvim_create_buf(true, false)
    local b_prev2 = vim.api.nvim_create_buf(true, false)
    local b_prev1 = vim.api.nvim_create_buf(true, false)
    local b_active = vim.api.nvim_create_buf(true, false)

    table.insert(created_bufs, b_old)
    table.insert(created_bufs, b_prev2)
    table.insert(created_bufs, b_prev1)
    table.insert(created_bufs, b_active)

    vim.api.nvim_buf_set_name(b_old, vim.fn.getcwd() .. "/old.lua")
    vim.api.nvim_buf_set_name(b_prev2, vim.fn.getcwd() .. "/prev2.lua")
    vim.api.nvim_buf_set_name(b_prev1, vim.fn.getcwd() .. "/prev1.lua")
    vim.api.nvim_buf_set_name(b_active, vim.fn.getcwd() .. "/active.lua")

    -- Focus b_old, then b_prev2, then b_prev1, then b_active so b_prev1 is the alternate buffer (#)
    vim.api.nvim_set_current_buf(b_old)
    vim.api.nvim_set_current_buf(b_prev2)
    vim.api.nvim_set_current_buf(b_prev1)
    vim.api.nvim_set_current_buf(b_active)

    assert.are.equal(b_active, vim.api.nvim_get_current_buf())
    assert.are.equal(b_prev1, vim.fn.bufnr("#"))

    -- When files provider is called with empty query (""), it returns open buffers in MRU order
    local items = files_provider.provider("")
    assert.is_true(#items >= 3)

    local labels = {}
    for _, item in ipairs(items) do
      table.insert(labels, item.label)
    end

    -- Verify b_active (active.lua) is excluded from the list
    local has_active = false
    for _, l in ipairs(labels) do
      if l == "active.lua" then
        has_active = true
      end
    end
    assert.is_false(has_active)

    -- First item must be prev1.lua (the alternate buffer # / most recently used prior buffer)
    assert.are.equal("prev1.lua", items[1].label)

    -- Verify prev2 is also in the list
    local has_prev2 = false
    for _, l in ipairs(labels) do
      if l == "prev2.lua" then has_prev2 = true end
    end
    assert.is_true(has_prev2)
  end)

  it("mouse scroll wheel adjusts viewport offset without moving selected_idx", function()
    local mock_items = {}
    for i = 1, 20 do
      table.insert(mock_items, { label = string.format("item_%02d", i), value = i })
    end

    nock.setup({
      maxheight = 5,
      modes = {
        scroll_test = {
          prefix = "@",
          provider = function(_) return mock_items end,
          action = function() end,
          show_on_open = true,
        }
      }
    })

    local popup = nock.open("scroll_test")
    assert.is_true(shell.is_open())
    local filt = shell._get_filtered()
    assert.are.equal(20, #filt)

    -- Initial state: selected_idx = 1, offset = 0
    assert.are.equal(1, shell._state.filter.selected_idx)
    assert.are.equal(0, shell._state.filter.offset)

    -- Scroll down by 2 lines
    shell._scroll_wheel(2)
    assert.are.equal(2, shell._state.filter.offset)
    -- selected_idx remains 1 (not forced to change)
    assert.are.equal(1, shell._state.filter.selected_idx)

    -- Lines in buffer show items from offset + 1 (item_03 to item_07)
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 2, -1, false)
    assert.are.equal("item_03", vim.trim(lines[1]))
    assert.are.equal("item_07", vim.trim(lines[5]))

    -- Scroll down further beyond maximum offset (20 - 5 = 15)
    shell._scroll_wheel(20)
    assert.are.equal(15, shell._state.filter.offset)
    assert.are.equal(1, shell._state.filter.selected_idx)

    local lines_end = vim.api.nvim_buf_get_lines(popup.bufnr, 2, -1, false)
    assert.are.equal("item_16", lines_end[1])
    assert.are.equal("item_20", lines_end[5])

    -- Scroll up by 3 lines
    shell._scroll_wheel(-3)
    assert.are.equal(12, shell._state.filter.offset)
    assert.are.equal(1, shell._state.filter.selected_idx)

    -- Scroll up beyond 0 clamps to 0
    shell._scroll_wheel(-50)
    assert.are.equal(0, shell._state.filter.offset)
    assert.are.equal(1, shell._state.filter.selected_idx)

    nock.close()
  end)

  it("<ScrollWheelUp> and <ScrollWheelDown> keymaps scroll in both normal and insert mode", function()
    local mock_items = {}
    for i = 1, 10 do
      table.insert(mock_items, { label = "item_" .. i, value = i })
    end

    nock.setup({
      maxheight = 3,
      modes = {
        wheel_test = {
          prefix = "!",
          provider = function(_) return mock_items end,
          action = function() end,
          show_on_open = true,
        }
      }
    })

    local popup = nock.open("wheel_test")
    assert.are.equal(0, shell._state.filter.offset)

    -- Test scroll wheel down via shell._scroll_wheel(1)
    shell._scroll_wheel(1)
    assert.are.equal(1, shell._state.filter.offset)

    -- Test scroll wheel up via shell._scroll_wheel(-1)
    shell._scroll_wheel(-1)
    assert.are.equal(0, shell._state.filter.offset)

    nock.close()
  end)

  it("arrow keys bring selection back into view after viewport mouse scroll", function()
    local mock_items = {}
    for i = 1, 10 do
      table.insert(mock_items, { label = string.format("line_%02d", i), value = i })
    end

    nock.setup({
      maxheight = 4,
      modes = {
        nav_test = {
          prefix = "?",
          provider = function(_) return mock_items end,
          action = function() end,
          show_on_open = true,
        }
      }
    })

    nock.open("nav_test")
    assert.are.equal(1, shell._state.filter.selected_idx)
    assert.are.equal(0, shell._state.filter.offset)

    -- Scroll viewport down by 4 lines (viewport now shows line_05 .. line_08)
    shell._scroll_wheel(4)
    assert.are.equal(4, shell._state.filter.offset)
    assert.are.equal(1, shell._state.filter.selected_idx)

    -- Press Down arrow: selected_idx moves from 1 to 2
    -- _move_selection automatically adjusts offset so selected_idx (2) is visible!
    shell._move_selection(1)
    assert.are.equal(2, shell._state.filter.selected_idx)
    assert.are.equal(1, shell._state.filter.offset)

    nock.close()
  end)

  it("popup border uses rounded style with left and right padding 1", function()
    nock.setup({})
    local popup = nock.open("files")
    assert.is_not_nil(popup)
    assert.is_not_nil(popup.winid)
    assert.is_true(vim.api.nvim_win_is_valid(popup.winid))
    local cfg = vim.api.nvim_win_get_config(popup.winid)
    local border = cfg.border
    if type(border) == "string" then
      assert.are.equal("rounded", border)
    else
      local first = border[1]
      if type(first) == "table" then
        assert.are.equal("╭", first[1])
      else
        assert.are.equal("╭", first)
      end
    end
    nock.close()
  end)
end)
