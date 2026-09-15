local nock = require("nock")
local shell = require("nock.shell")
local actions = require("nock.actions")
local utils = require("nock.utils")
local presets = require("nock.presets")
local assert = require("luassert")

describe("nock extensibility, actions, utils, and presets (12)", function()
  local created_bufs = {}

  before_each(function()
    nock.setup({
      maxheight = 10,
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

  it("provider receives ctx with origin window, buffer, file and is_cancelled", function()
    local test_buf = vim.api.nvim_create_buf(true, false)
    table.insert(created_bufs, test_buf)
    vim.api.nvim_buf_set_name(test_buf, vim.fn.getcwd() .. "/test_ctx.lua")
    vim.api.nvim_set_current_buf(test_buf)

    local captured_ctx = nil
    nock.setup({
      modes = {
        ctx_test = {
          prefix = "@",
          provider = function(query, ctx, cb)
            captured_ctx = ctx
            cb({ { label = "item_1", value = 1 } })
            return nil
          end,
          show_on_open = true,
        },
      },
    })

    nock.open("ctx_test")
    assert.is_true(shell.is_open())
    assert.is_not_nil(captured_ctx)
    assert.are.equal(test_buf, captured_ctx.buf)
    assert.is_true(captured_ctx.file:find("test_ctx.lua") ~= nil)
    assert.is_function(captured_ctx.is_cancelled)
    assert.is_false(captured_ctx.is_cancelled())

    nock.close()
  end)

  it("async provider invokes callback(items) to populate filtered list", function()
    local async_cb_holder = nil
    nock.setup({
      modes = {
        async_mode = {
          prefix = "#",
          provider = function(query, ctx, callback)
            async_cb_holder = callback
            return nil -- async
          end,
          show_on_open = false,
        },
      },
    })

    local popup = nock.open("async_mode")
    assert.is_true(shell.is_open())
    shell._set_query_for_test("#query")
    assert.are.equal(0, #shell._get_filtered())
    -- Deliver async results
    async_cb_holder({
      { label = "query_result_1", value = 1 },
      { label = "query_result_2", value = 2 },
    })

    assert.are.equal(2, #shell._get_filtered())
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 2, -1, false)
    assert.are.equal("query_result_1", vim.trim(lines[1]))

    nock.close()
  end)

  it("generational cancellation drops stale async callbacks", function()
    local callbacks = {}
    nock.setup({
      modes = {
        stale_test = {
          prefix = "#",
          provider = function(query, ctx, callback)
            table.insert(callbacks, { query = query, cb = callback, ctx = ctx })
            return nil
          end,
          show_on_open = false,
        },
      },
    })

    -- New filter makes exactly one provider call per apply: open with
    -- show_on_open=false issues no call (nothing to display), so only the
    -- two explicit queries produce callbacks (old code also cold-filled on
    -- open — pure waste, removed by the async-only cutover).
    nock.open("stale_test")
    shell._set_query_for_test("#first")
    shell._set_query_for_test("#second")

    assert.are.equal(2, #callbacks)
    assert.is_true(callbacks[1].ctx.is_cancelled()) -- from #first
    assert.is_false(callbacks[2].ctx.is_cancelled()) -- from #second

    -- Stale callback delivers after second query was issued
    callbacks[1].cb({ { label = "stale_result" } })
    assert.are.equal(0, #shell._get_filtered())

    -- Fresh callback delivers
    callbacks[2].cb({ { label = "second_match", filter_text = "second" } })
    assert.are.equal(1, #shell._get_filtered())
    assert.are.equal("second_match", shell._get_filtered()[1].item.label)
    nock.close()
  end)

  it("Item with filter_text matches on filter_text and formats [kind] label", function()
    nock.setup({
      -- Pin the [Kind] fallback format: icons render nerd-font glyphs when
      -- enabled (default), which makes this assertion font-dependent.
      icons = { enabled = false },
      modes = {
        kind_test = {
          prefix = "%",
          provider = function(_, _, cb)
            cb({
              { label = "render()", filter_text = "render function", kind = "Function" },
              { label = "ConfigError", filter_text = "error type", kind = "Class" },
            })
            return nil
          end,
          show_on_open = true,
        },
      },
    })

    local popup = nock.open("kind_test")
    assert.are.equal(2, #shell._get_filtered())

    -- Lines in buffer show formatted [kind] label
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 2, -1, false)
    assert.are.equal("[Function] render()", vim.trim(lines[1]))
    assert.are.equal("[Class] ConfigError", vim.trim(lines[2]))

    -- Filtering by filter_text works
    shell._set_query_for_test("%error")
    assert.are.equal(1, #shell._get_filtered())
    assert.are.equal("ConfigError", shell._get_filtered()[1].item.label)

    nock.close()
  end)

  it("nock.presets.commands creates Ex command mode and executes on Enter", function()
    local custom_ran = false
    vim.api.nvim_create_user_command("NockPresetCmdTest", function() custom_ran = true end, {})

    nock.setup({
      modes = {
        cmd_mode = presets.commands({ prefix = ">" }),
      },
    })

    nock.open("cmd_mode")
    assert.is_true(shell.is_open())
    shell._set_query_for_test(">NockPresetCmdTest")
    -- Real preset providers deliver async (vim.schedule tick).
    vim.wait(2000, function() return #shell._get_filtered() == 1 end)
    assert.are.equal(1, #shell._get_filtered())

    shell._commit()
    assert.is_false(shell.is_open())
    assert.is_true(custom_ran)

    pcall(vim.api.nvim_del_user_command, "NockPresetCmdTest")
  end)

  it("nock.presets.diagnostics formats diagnostics into standard Items", function()
    local b = vim.api.nvim_create_buf(true, false)
    table.insert(created_bufs, b)
    vim.api.nvim_buf_set_name(b, vim.fn.getcwd() .. "/diag_file.lua")
    vim.api.nvim_set_current_buf(b)

    -- Set mock diagnostics (WARN/HINT should be filtered per "clear all")
    vim.diagnostic.set(vim.api.nvim_create_namespace("test_diag"), b, {
      { lnum = 2, col = 5, message = "undefined variable foo", severity = vim.diagnostic.severity.ERROR },
      { lnum = 10, col = 0, message = "unused variable bar", severity = vim.diagnostic.severity.WARN },
      { lnum = 15, col = 0, message = "hint message", severity = vim.diagnostic.severity.HINT },
    })

    nock.setup({
      modes = {
        diag = presets.diagnostics({ prefix = "!" }),
      },
    })

    nock.open("diag")
    assert.is_true(shell.is_open())
    -- Real preset providers deliver async (vim.schedule tick).
    vim.wait(2000, function() return #shell._get_filtered() == 1 end)
    local filt = shell._get_filtered()

    -- Only ERROR remains, WARN/HINT cleared
    assert.are.equal("Error", filt[1].item.kind)
    assert.are.equal(3, filt[1].item.location.lnum) -- 1-indexed (lnum 2 + 1)

    nock.close()
  end)
  it("diagnostics empty source notifies instead of a committable placeholder Item", function()
    local b = vim.api.nvim_create_buf(true, false)
    table.insert(created_bufs, b)
    vim.api.nvim_buf_set_name(b, vim.fn.getcwd() .. "/diag_empty.lua")
    vim.api.nvim_set_current_buf(b)
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, ...)
      table.insert(notified, { msg = msg, level = level })
      return nil
    end
    local ok, err = pcall(function()
      nock.setup({ modes = { diag = presets.diagnostics({ prefix = "!" }) } })
      nock.open("diag")
      assert.is_true(shell.is_open())
      vim.wait(2000, function() return #notified > 0 end)
      assert.are.equal(1, #notified)
      assert.are.equal("No diagnostics", notified[1].msg)
      assert.are.equal(vim.log.levels.INFO, notified[1].level)
      assert.are.equal(0, #shell._get_filtered())
      assert.are.equal(0, shell._get_selected_idx())
      local names_before = {}
      for _, existing in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(existing) then
          names_before[vim.api.nvim_buf_get_name(existing)] = true
        end
      end
      shell._commit()
      assert.is_false(shell.is_open())
      for _, existing in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(existing) then
          local name = vim.api.nvim_buf_get_name(existing)
          assert.is_nil(name:find("No diagnostics", 1, true))
          if name ~= "" and not names_before[name] then
            assert.is_true(name:find("diag_empty", 1, true) ~= nil, "unexpected new buffer: " .. name)
          end
        end
      end
    end)
    vim.notify = orig_notify
    pcall(nock.close)
    if not ok then error(err) end
  end)

  it("diagnostics typed query with no matches stays silent with an empty list", function()
    local b = vim.api.nvim_create_buf(true, false)
    table.insert(created_bufs, b)
    vim.api.nvim_buf_set_name(b, vim.fn.getcwd() .. "/diag_typed.lua")
    vim.api.nvim_set_current_buf(b)
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, ...)
      table.insert(notified, { msg = msg, level = level })
      return nil
    end
    local ok, err = pcall(function()
      nock.setup({ modes = { diag = presets.diagnostics({ prefix = "!" }) } })
      nock.open("diag")
      assert.is_true(shell.is_open())
      vim.wait(2000, function() return #notified > 0 end)
      assert.are.equal("No diagnostics", notified[1].msg)
      notified = {}
      shell._set_query_for_test("!zzz_no_match")
      vim.wait(500, function() return #notified > 0 end)
      assert.are.equal(0, #notified)
      assert.are.equal(0, #shell._get_filtered())
    end)
    vim.notify = orig_notify
    pcall(nock.close)
    if not ok then error(err) end
  end)

  it("lsp_document_symbols with no client notifies instead of a placeholder Item", function()
    presets._set_lsp({
      get_clients = function() return {} end,
      make_text_document_params = function() return {} end,
      client_request = function() end,
      buf_request_sync = function() return {} end,
    })
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, ...)
      table.insert(notified, { msg = msg, level = level })
      return nil
    end
    local ok, err = pcall(function()
      nock.setup({ modes = { doc = presets.lsp_document_symbols({ prefix = "@" }) } })
      nock.open("doc")
      assert.is_true(shell.is_open())
      vim.wait(2000, function() return #notified > 0 end)
      assert.are.equal("No LSP client attached", notified[1].msg)
      assert.are.equal(vim.log.levels.INFO, notified[1].level)
      assert.are.equal(0, #shell._get_filtered())
      shell._commit()
      assert.is_false(shell.is_open())
    end)
    vim.notify = orig_notify
    presets._reset_lsp()
    pcall(nock.close)
    if not ok then error(err) end
  end)

  it("lsp_workspace_symbols empty query silent, typed query with no client notifies", function()
    presets._set_lsp({
      get_clients = function() return {} end,
      make_text_document_params = function() return {} end,
      client_request = function() end,
      buf_request_sync = function() return {} end,
    })
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, ...)
      table.insert(notified, { msg = msg, level = level })
      return nil
    end
    local ok, err = pcall(function()
      nock.setup({ modes = { ws = presets.lsp_workspace_symbols({ prefix = "#" }) } })
      nock.open("ws")
      assert.is_true(shell.is_open())
      vim.wait(300, function() return #notified > 0 end)
      assert.are.equal(0, #notified)
      assert.are.equal(0, #shell._get_filtered())
      shell._set_query_for_test("#foo")
      vim.wait(2000, function() return #notified > 0 end)
      assert.are.equal("No workspace client", notified[1].msg)
      assert.are.equal(vim.log.levels.INFO, notified[1].level)
      assert.are.equal(0, #shell._get_filtered())
    end)
    vim.notify = orig_notify
    presets._reset_lsp()
    pcall(nock.close)
    if not ok then error(err) end
  end)


  it("nock.presets.lines indexes buffer lines and jumps cursor on commit", function()
    local b = vim.api.nvim_create_buf(true, false)
    table.insert(created_bufs, b)
    vim.api.nvim_buf_set_name(b, vim.fn.getcwd() .. "/lines_file.lua")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {
      "local M = {}",
      "function M.hello()",
      "  print('hello')",
      "end",
    })
    vim.api.nvim_set_current_buf(b)

    nock.setup({
      modes = {
        goto_line = presets.lines({ prefix = ":" }),
      },
    })
    nock.open("goto_line")
    assert.is_true(shell.is_open())
    vim.wait(2000, function() return #shell._get_filtered() == 4 end)
    assert.are.equal(4, #shell._get_filtered())

    -- Filter line 3
    -- Filter lines containing 'hello' (lines 2 and 3 match)
    shell._set_query_for_test(":hello")
    vim.wait(2000, function() return #shell._get_filtered() == 2 end)
    assert.are.equal(2, #shell._get_filtered())

    -- Commit jumps cursor in origin window to top selected line (line 2)
    shell._commit()
    assert.is_false(shell.is_open())
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.are.equal(2, cursor[1]) -- line 2 (function M.hello())
  end)

  it("nock.actions and nock.utils are exposed on public API", function()
    assert.is_table(nock.actions)
    assert.is_function(nock.actions.edit)
    assert.is_function(nock.actions.cmd)
    assert.is_function(nock.actions.set_cursor)

    assert.is_table(nock.utils)
    assert.is_function(nock.utils.lsp_symbol_to_item)
    assert.is_function(nock.utils.format_diagnostic)

    assert.is_table(nock.presets)
    assert.is_function(nock.presets.commands)
    assert.is_function(nock.presets.lsp_document_symbols)
    assert.is_function(nock.presets.lsp_workspace_symbols)
    assert.is_function(nock.presets.diagnostics)
    assert.is_function(nock.presets.lines)
  end)
end)
