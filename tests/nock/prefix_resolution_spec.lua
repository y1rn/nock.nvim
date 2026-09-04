-- Integration tests for Ticket 08: Prefix Resolution (ADR-0005)
-- Covers: no-prefix→files mode, ">"-prefix→commands mode, open("commands") pre-fills ">",
-- deleting prefix returns to files mode, custom mode with "#" prefix via register_mode.
describe("nock prefix resolution (08)", function()
  local nock, config, shell

  local function files_items()
    return {
      { label = "src/foo.lua", value = "src/foo.lua" },
      { label = "src/bar.lua", value = "src/bar.lua" },
      { label = "README.md", value = "README.md" },
    }
  end

  local function commands_items()
    return {
      { label = ":NockToggle", value = "NockToggle" },
      { label = ":NockFind", value = "NockFind" },
    }
  end

  local function lsp_items()
    return {
      { label = "MyClass", value = "MyClass" },
      { label = "my_function", value = "my_function" },
    }
  end

  local function files_provider(q)
    -- empty/nil → open buffers proxy; non-empty → project files proxy
    return files_items()
  end

  local function commands_provider(_)
    return commands_items()
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

    nock.setup({
      maxheight = 10,
      matcher = "auto",
      show_on_open = true,
      modes = {
        files    = { prefix = "",  provider = files_provider,    show_on_open = true,  keymap = "" },
        commands = { prefix = ">", provider = commands_provider, show_on_open = true,  keymap = "" },
      },
    })
  end)

  after_each(function()
    pcall(function() shell.close() end)
    config.reset()
    pcall(vim.cmd, "stopinsert")
  end)

  it("no prefix in input → resolves to files mode", function()
    nock.open("files")
    assert.is_true(shell.is_open())
    -- Mode starts as files
    assert.are.equal("files", shell._get_current_mode())
    -- Input buf contains empty prefix (files prefix is "")
    local buf = shell._get_popup().bufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    assert.are.equal("", vim.trim(lines[1]))
    shell.close()
  end)

  it("'>' prefix in input → resolves to commands mode", function()
    nock.open("files")
    assert.is_true(shell.is_open())
    -- Simulate typing ">"
    shell._set_query_for_test(">")
    assert.are.equal("commands", shell._get_current_mode())
    shell.close()
  end)

  it("open('commands') pre-fills '>' in input buffer", function()
    nock.open("commands")
    assert.is_true(shell.is_open())
    local buf = shell._get_popup().bufnr
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    assert.are.equal(">", vim.trim(lines[1]))
    assert.are.equal("commands", shell._get_current_mode())
    shell.close()
  end)

  it("deleting prefix '>' from input returns to files mode", function()
    nock.open("commands")
    assert.is_true(shell.is_open())
    assert.are.equal("commands", shell._get_current_mode())
    -- Remove the prefix: empty input → files mode
    shell._set_query_for_test("")
    assert.are.equal("files", shell._get_current_mode())
    shell.close()
  end)

  it("query with '#' prefix → custom '#' mode after register_mode", function()
    nock.register_mode("lsp", {
      prefix = "#",
      provider = function(_) return lsp_items() end,
      show_on_open = true,
    })
    nock.open("files")
    assert.is_true(shell.is_open())
    -- Type "#" to trigger lsp mode
    shell._set_query_for_test("#")
    assert.are.equal("lsp", shell._get_current_mode())
    shell.close()
  end)

  it("custom '#' mode items appear after register_mode and '#' prefix", function()
    nock.register_mode("lsp", {
      prefix = "#",
      provider = function(_) return lsp_items() end,
      show_on_open = true,
    })
    nock.open("files")
    shell._set_query_for_test("#")
    assert.are.equal("lsp", shell._get_current_mode())
    -- All items should be lsp_items (show_on_open=true, empty eff_query after stripping "#")
    local all = shell._get_all_items()
    assert.is_true(#all >= 1)
    assert.are.equal("MyClass", all[1].label)
    shell.close()
  end)

  it("open('commands') while shell already open switches in-place", function()
    -- Open files first
    nock.open("files")
    assert.is_true(shell.is_open())
    local pop1 = shell._get_popup()
    assert.are.equal("files", shell._get_current_mode())

    -- Call open("commands") while already open → in-place switch, same popup
    nock.open("commands")
    assert.is_true(shell.is_open())
    local pop2 = shell._get_popup()
    -- Same popup object (in-place switch)
    assert.are.equal(pop1.bufnr, pop2.bufnr)
    assert.are.equal("commands", shell._get_current_mode())
    -- Input pre-filled with ">"
    local lines = vim.api.nvim_buf_get_lines(pop2.bufnr, 0, 1, false)
    assert.are.equal(">", vim.trim(lines[1]))
    shell.close()
  end)

  it("resolve_mode_and_query fallback uses prefix='' mode not hardcoded 'files'", function()
    -- Single-fallback rule (ADR-0027): remove files first, then register custom fallback
    config.options.modes.files = nil
    nock.register_mode("custom_default", {
      prefix = "",
      provider = function(_) return { { label = "custom", value = "custom" } } end,
      show_on_open = true,
    })
    nock.open("custom_default")
    assert.is_true(shell.is_open())
    -- Typing bare text (no known prefix) should resolve to custom_default
    shell._set_query_for_test("")
    assert.are.equal("custom_default", shell._get_current_mode())
    shell.close()
  end)

  it("unconfigured/provider-less modes in setup do not hijack default files mode fallback", function()
    nock.setup({
      modes = {
        files = { keymap = "<C-p>" },
        commands = { keymap = "<C-S-p>" },
      }
    })

    nock.open()
    assert.is_true(shell.is_open())
    assert.are.equal("files", shell._get_current_mode())

    shell._set_query_for_test("init")
    assert.are.equal("files", shell._get_current_mode())
    assert.is_true(#shell._get_filtered() > 0)
    shell.close()
  end)
end)
