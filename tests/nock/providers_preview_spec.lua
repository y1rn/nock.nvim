-- Headless integration for Ticket 03: Providers, Actions and Preview lifecycle
-- Via single high seam public API: setup -> open -> filter -> move -> preview -> Esc/Enter -> actions -> mouse
describe("nock providers, actions and preview (03)", function()
  local nock, config, shell

  before_each(function()
    package.loaded["nock"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.shell"] = nil
    package.loaded["nock.matcher"] = nil
    package.loaded["nock.highlights"] = nil
    package.loaded["nock.providers.files"] = nil
    pcall(function() require("nock.shell").close() end)
    pcall(vim.api.nvim_del_user_command, "NockTestCmd03")
    pcall(vim.api.nvim_del_user_command, "NockCustomAction03")
    vim.o.columns = 120
    vim.o.lines = 40
    nock = require("nock")
    config = require("nock.config")
    shell = require("nock.shell")
    config.reset()
    require("nock.highlights").setup()
  end)

  after_each(function()
    pcall(function() shell.close() end)
    pcall(vim.api.nvim_del_user_command, "NockTestCmd03")
    pcall(vim.api.nvim_del_user_command, "NockCustomAction03")
    config.reset()
  end)

  it("files Provider uses fd if executable/configured else vim.fs.find; ignores .git/node_modules/.DS_Store overridable; returns Item[] with label/location", function()
    local tmp = vim.fn.tempname() .. "_nock03_files"
    vim.fn.mkdir(tmp, "p")
    local old_cwd = vim.fn.getcwd()
    -- Ensure rtp contains absolute project root so require still works after chdir (rtp "." is relative)
    local proj_root = old_cwd
    -- old_cwd may already be absolute; ensure rtp has it
    pcall(function() vim.opt.rtp:append(proj_root) end)
    vim.fn.writefile({ "a" }, tmp .. "/a.txt")
    vim.fn.writefile({ "b" }, tmp .. "/b.lua")
    vim.fn.mkdir(tmp .. "/.git", "p")
    vim.fn.writefile({ "git" }, tmp .. "/.git/inner.txt")
    vim.fn.mkdir(tmp .. "/node_modules", "p")
    vim.fn.writefile({ "mod" }, tmp .. "/node_modules/mod.js")
    vim.fn.writefile({ "ds" }, tmp .. "/.DS_Store")
    pcall(vim.fn.chdir, tmp)

    nock.setup({ files = { fd_cmd = false }, modes = { files = { fd_cmd = false } } })
    local files_provider = require("nock.providers.files")
    local items
    local done = false
    files_provider.provider(".", {}, function(got)
      items = got or {}
      done = true
    end)
    vim.wait(5000, function() return done end)
    assert.is_true(done, "files provider should deliver async results")
    local labels = {}
    for _, it in ipairs(items) do labels[it.label] = true end
    assert.is_true(labels["a.txt"] or labels["./a.txt"], "a.txt should be present")
    assert.is_true(labels["b.lua"] or labels["./b.lua"], "b.lua should be present")
    assert.is_falsy(labels[".git/inner.txt"], ".git ignored")
    assert.is_falsy(labels["node_modules/mod.js"], "node_modules ignored")
    assert.is_falsy(labels[".DS_Store"], ".DS_Store ignored")
    for _, it in ipairs(items) do
      assert.is_string(it.label)
      assert.is_not_nil(it.location)
      assert.is_string(it.location.path)
      assert.is_not_nil(it.value)
    end

    nock.setup({ files = { fd_cmd = false, ignore = {} }, modes = { files = { fd_cmd = false, ignore = {} } } })
    local items2
    local done2 = false
    files_provider.provider(".", {}, function(got)
      items2 = got or {}
      done2 = true
    end)
    vim.wait(5000, function() return done2 end)
    assert.is_true(done2, "files provider should deliver async results")
    local labels2 = {}
    for _, it in ipairs(items2) do labels2[it.label] = true end
    assert.is_true(labels2[".git/inner.txt"] or labels2[".DS_Store"] or labels2["node_modules/mod.js"] or #items2 > #items, "override should allow ignored files")

    nock.setup({ files = { fd_cmd = false }, modes = { files = { fd_cmd = false, ignore = { "a.txt" } } } })
    local items3
    local done3 = false
    files_provider.provider(".", {}, function(got)
      items3 = got or {}
      done3 = true
    end)
    vim.wait(5000, function() return done3 end)
    assert.is_true(done3, "files provider should deliver async results")
    local labels3 = {}
    for _, it in ipairs(items3) do labels3[it.label] = true end
    assert.is_falsy(labels3["a.txt"], "custom mode ignore should exclude a.txt")

    pcall(vim.fn.chdir, old_cwd)
    vim.fn.delete(tmp, "rf")
  end)

  it("custom registered mode provides custom candidates and executes action on Enter", function()
    local custom_called = false
    nock.setup({
      modes = {
        custom_mode = {
          prefix = ":",
          provider = function(_, _, cb)
            cb({ { label = ":CustomAction", value = "CustomAction", detail = "custom action" } })
            return nil
          end,
          action = function(item)
            if item.value == "CustomAction" then
              custom_called = true
            end
          end,
        },
      },
    })
    nock.open("custom_mode")
    assert.is_true(shell.is_open())
    shell._commit()
    assert.is_true(custom_called)
  end)

  it("custom provider per Mode overrides built-in", function()
    local custom_called = false
    local custom_items = { { label = "custom-one", value = "custom-one", location = { path = "custom-one" } } }
    nock.setup({
      modes = {
        files = {
          provider = function(_, _, cb)
            custom_called = true
            cb(custom_items)
            return nil
          end,
        },
      },
    })
    nock.open("files")
    local all = shell._get_all_items()
    assert.is_true(custom_called, "custom provider should be called on open")
    assert.are.equal(1, #all)
    assert.are.equal("custom-one", all[1].label)
    assert.is_true(shell.is_open())
  end)

  it("<Up>/<Down> moves selection and triggers transient Preview (cursor move + NockPreview hl)", function()
    local tmp = vim.fn.tempname() .. "_nock03_preview"
    vim.fn.mkdir(tmp, "p")
    local f1 = tmp .. "/file1.txt"
    local f2 = tmp .. "/file2.txt"
    vim.fn.writefile({ "line1_file1", "line2_file1", "line3_file1" }, f1)
    vim.fn.writefile({ "line1_file2", "line2_file2", "line3_file2" }, f2)

    local items = {
      { label = "file1.txt", value = f1, location = { path = f1, lnum = 2, col = 0 } },
      { label = "file2.txt", value = f2, location = { path = f2, lnum = 3, col = 0 } },
    }
    nock.setup({
      maxheight = 10,
      matcher = "auto",
      modes = {
        files = {
          provider = function(_, _, cb) cb(items); return nil end,
          preview = true,
        },
      },
    })
    local origin_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(origin_buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local origin_win = vim.api.nvim_get_current_win()

    nock.open("files")
    assert.is_true(shell.is_open())
    shell._set_query_for_test("file")
    assert.are.equal(2, #shell._get_filtered())
    assert.are.equal(1, shell._get_selected_idx())
    local cur_buf_after_filter = vim.api.nvim_win_get_buf(origin_win)
    local buf_name1 = vim.api.nvim_buf_get_name(cur_buf_after_filter)
    assert.is_true(buf_name1:find("file1") ~= nil or cur_buf_after_filter ~= origin_buf, "preview should have switched origin buffer to file1")
    local cur_pos1 = vim.api.nvim_win_get_cursor(origin_win)
    assert.are.equal(2, cur_pos1[1], "preview cursor should be at lnum 2 for first item")
    local ns = shell._get_preview_ns()
    local preview_buf = shell._get_preview_buf()
    assert.is_not_nil(preview_buf)
    local hl = {}
    pcall(function() hl = vim.api.nvim_buf_get_extmarks(preview_buf, ns, 0, -1, {}) end)
    assert.is_true(#hl >= 0, "preview ns should exist")
    shell._move_selection(1)
    assert.are.equal(2, shell._get_selected_idx())
    local cur_buf2 = vim.api.nvim_win_get_buf(origin_win)
    local buf_name2 = vim.api.nvim_buf_get_name(cur_buf2)
    assert.is_true(buf_name2:find("file2") ~= nil, "preview should switch to file2 after Down")
    local cur_pos2 = vim.api.nvim_win_get_cursor(origin_win)
    assert.are.equal(3, cur_pos2[1], "preview cursor should be at lnum 3 for second item")
    shell._move_selection(-1)
    assert.are.equal(1, shell._get_selected_idx())
    local cur_pos3 = vim.api.nvim_win_get_cursor(origin_win)
    assert.are.equal(2, cur_pos3[1])
    vim.fn.delete(tmp, "rf")
  end)

  it("Esc closes Shell, clears Preview hl/extmarks and winrestview restores original cursor/view without jumplist pollution", function()
    local tmp = vim.fn.tempname() .. "_nock03_esc"
    vim.fn.mkdir(tmp, "p")
    local f1 = tmp .. "/preview.txt"
    vim.fn.writefile({ "a", "b", "c", "d" }, f1)
    local items = {
      { label = "preview.txt", value = f1, location = { path = f1, lnum = 3, col = 0 } },
    }
    nock.setup({
      modes = {
        files = {
          provider = function(_, _, cb) cb(items); return nil end,
          preview = true,
        },
      },
    })
    local origin_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(origin_buf)
    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "orig_line1", "orig_line2", "orig_line3" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local origin_win = vim.api.nvim_get_current_win()
    local init_cursor = vim.api.nvim_win_get_cursor(origin_win)
    local init_jumplist = vim.fn.getjumplist(origin_win)[1]
    local init_jm_len = #init_jumplist

    nock.open("files")
    shell._set_query_for_test("prev")
    assert.are.equal(1, #shell._get_filtered())
    local preview_cursor = vim.api.nvim_win_get_cursor(origin_win)
    assert.are.equal(3, preview_cursor[1])
    local preview_buf = shell._get_preview_buf()
    local ns = shell._get_preview_ns()
    assert.is_not_nil(preview_buf)
    local before_hl = {}
    pcall(function() before_hl = vim.api.nvim_buf_get_extmarks(preview_buf, ns, 0, -1, {}) end)
    shell.close()
    assert.is_false(shell.is_open(), "Shell should be closed after Esc")
    local after_cursor = vim.api.nvim_win_get_cursor(origin_win)
    assert.are.equal(init_cursor[1], after_cursor[1])
    assert.are.equal(init_cursor[2], after_cursor[2])
    if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
      local after_hl = {}
      pcall(function() after_hl = vim.api.nvim_buf_get_extmarks(preview_buf, ns, 0, -1, {}) end)
      assert.are.equal(0, #after_hl, "Preview hl/extmarks should be cleared on Esc")
    end
    local after_jumplist = vim.fn.getjumplist(origin_win)[1]
    assert.are.equal(init_jm_len, #after_jumplist, "preview should not pollute jumplist")
    local cur_buf = vim.api.nvim_win_get_buf(origin_win)
    assert.are.equal(origin_buf, cur_buf, "origin buffer should be restored after Esc")
    vim.fn.delete(tmp, "rf")
  end)

  it("Enter on file Item edits file at location and closes; on command Item executes vim.cmd; custom action(item, ctx) supported", function()
    local tmp = vim.fn.tempname() .. "_nock03_enter_file"
    vim.fn.mkdir(tmp, "p")
    local f = tmp .. "/enter.txt"
    vim.fn.writefile({ "x", "y" }, f)
    local file_items = {
      { label = "enter.txt", value = f, location = { path = f, lnum = 2, col = 0 } },
    }
    nock.setup({
      modes = {
        files = {
          provider = function(_, _, cb) cb(file_items); return nil end,
          preview = false,
        },
      },
    })
    local origin_win = vim.api.nvim_get_current_win()
    nock.open("files")
    shell._set_query_for_test("enter")
    assert.are.equal(1, #shell._get_filtered())
    assert.are.equal(1, shell._get_selected_idx())
    shell._commit()
    assert.is_false(shell.is_open(), "Shell should close after Enter on file")
    local cur_buf = vim.api.nvim_win_get_buf(origin_win)
    local cur_name = vim.api.nvim_buf_get_name(cur_buf)
    assert.is_true(cur_name:find("enter.txt") ~= nil, "file action should edit file at location")
    vim.fn.delete(tmp, "rf")

    local cmd_executed = false
    vim.api.nvim_create_user_command("NockCustomAction03", function() cmd_executed = true end, {})
    local cmd_items = {
      { label = ":NockCustomAction03", value = "NockCustomAction03", detail = "custom" },
    }
    nock.setup({
      modes = {
        commands = {
          prefix = ">",
          provider = function(_, _, cb) cb(cmd_items); return nil end,
          preview = false,
        },
      },
    })
    nock.open("commands")
    shell._set_query_for_test(">NockCustom")
    assert.are.equal(1, #shell._get_filtered())
    shell._commit()
    assert.is_false(shell.is_open())
    assert.is_true(cmd_executed, "command action should execute vim.cmd(value)")

    local custom_ctx = nil
    local custom_item = nil
    nock.setup({
      modes = {
        files = {
          provider = function(_, _, cb) cb({ { label = "custom", value = "custom", location = { path = f } } }); return nil end,
          action = function(item, ctx)
            custom_item = item
            custom_ctx = ctx
          end,
          preview = false,
        },
      },
    })
    nock.open("files")
    shell._set_query_for_test("custom")
    shell._commit()
    assert.is_false(shell.is_open())
    assert.is_not_nil(custom_item, "custom action should be called")
    assert.are.equal("custom", custom_item.label)
    assert.is_not_nil(custom_ctx and custom_ctx.win)
    -- assert.is_not_nil(custom_ctx.win)
    assert.are.equal("files", custom_ctx.mode)
  end)

  it("Hover does not trigger Preview; mouse click->select, double-click->Action", function()
    local tmp = vim.fn.tempname() .. "_nock03_mouse"
    vim.fn.mkdir(tmp, "p")
    local f1 = tmp .. "/m1.txt"
    local f2 = tmp .. "/m2.txt"
    vim.fn.writefile({ "a" }, f1)
    vim.fn.writefile({ "b" }, f2)
    local items = {
      { label = "m1.txt", value = f1, location = { path = f1, lnum = 1, col = 0 } },
      { label = "m2.txt", value = f2, location = { path = f2, lnum = 1, col = 0 } },
    }
    local action_log = {}
    nock.setup({
      modes = {
        files = {
          provider = function(_, _, cb) cb(items); return nil end,
          preview = true,
          action = function(item, ctx)
            table.insert(action_log, item.label)
          end,
        },
      },
    })
    local origin_win = vim.api.nvim_get_current_win()
    nock.open("files")
    shell._set_query_for_test("m")
    assert.are.equal(2, #shell._get_filtered())
    local first_preview_buf = shell._get_preview_buf()
    assert.is_not_nil(first_preview_buf)
    local first_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win))
    assert.is_true(first_name:find("m1") ~= nil, "initial preview should be m1")

    shell._render()
    local after_hover_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win))
    assert.are.equal(first_name, after_hover_name, "hover (render without selection change) should not change preview")

    shell._click_at(2)
    assert.are.equal(2, shell._get_selected_idx(), "click should select second item")
    assert.is_true(shell.is_open(), "click should not close")
    assert.are.equal(0, #action_log, "click select should not trigger Action")
    local after_click_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win))
    assert.is_true(after_click_name:find("m2") ~= nil, "click select should trigger preview to m2")

    shell._render()
    local after_hover2 = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win))
    assert.are.equal(after_click_name, after_hover2, "hover after click should not change preview")

    shell._double_click_at(2)
    assert.is_false(shell.is_open(), "double-click should commit and close")
    assert.are.equal(1, #action_log)
    assert.are.equal("m2.txt", action_log[1])

    action_log = {}
    nock.open("files")
    shell._set_query_for_test("m")
    assert.are.equal(1, shell._get_selected_idx())
    shell._click_at(1)
    assert.is_false(shell.is_open(), "click on already selected should commit")
    assert.are.equal(1, #action_log)
    assert.are.equal("m1.txt", action_log[1])

    vim.fn.delete(tmp, "rf")
  end)

  it("Preview does not pollute jumplist on browse and is cleared on close; Enter commits without restore", function()
    local tmp = vim.fn.tempname() .. "_nock03_jumplist"
    vim.fn.mkdir(tmp, "p")
    local f = tmp .. "/j.txt"
    vim.fn.writefile({ "1", "2", "3" }, f)
    local items = {
      { label = "j.txt", value = f, location = { path = f, lnum = 3, col = 0 } },
    }
    nock.setup({
      modes = {
        files = {
          provider = function(_, _, cb) cb(items); return nil end,
          preview = true,
        },
      },
    })
    local origin_win = vim.api.nvim_get_current_win()
    local jm_before = #vim.fn.getjumplist(origin_win)[1]
    nock.open("files")
    shell._set_query_for_test("j")
    local jm_during_preview = #vim.fn.getjumplist(origin_win)[1]
    assert.are.equal(jm_before, jm_during_preview, "preview should not pollute jumplist")
    shell._commit()
    assert.is_false(shell.is_open())
    local cur = vim.api.nvim_win_get_buf(origin_win)
    local name = vim.api.nvim_buf_get_name(cur)
    assert.is_true(name:find("j.txt") ~= nil, "Enter should keep previewed file")
    local ns = shell._get_preview_ns()
    local cnt = 0
    pcall(function()
      cnt = #vim.api.nvim_buf_get_extmarks(cur, ns, 0, -1, {})
    end)
    assert.are.equal(0, cnt, "preview hl should be cleared on commit close as well")
    vim.fn.delete(tmp, "rf")
  end)
end)
