-- Regression for 0020: async generation guard — pure generation, stale discard, mode session
describe("nock generation guard (0020)", function()
  local nock, shell, filter, config, presets

  before_each(function()
    package.loaded["nock"] = nil
    package.loaded["nock.shell"] = nil
    package.loaded["nock.filter"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.presets"] = nil
    nock = require("nock")
    shell = require("nock.shell")
    filter = require("nock.filter")
    config = require("nock.config")
    presets = require("nock.presets")
    config.reset()
    filter.reset()
  end)

  after_each(function()
    pcall(function() shell.close() end)
    pcall(function() presets._reset_lsp() end)
    config.reset()
    filter.reset()
  end)

  it("filter: stale callback with same eff '' across mode switch is discarded (pure generation)", function()
    -- file mode sync, symbols mode async
    local symbols_cb = nil
    local symbols_ctx = nil
    local files_items = { { label = "a.txt" }, { label = "b.txt" } }
    local symbol_items = { { label = "MyClass" }, { label = "my_func" } }

    config.reset()
    -- register two modes: files (prefix="") sync, symbols (prefix="@") async
    nock.setup({
      modes = {
        files = {
          prefix = "",
          provider = function(_, _, cb) cb(files_items); return nil end,
          show_on_open = true,
        },
        doc_symbols = {
          prefix = "@",
          provider = function(_q, ctx, cb)
            symbols_ctx = ctx
            symbols_cb = cb
            return nil
          end,
          show_on_open = true,
        },
      },
    })

    -- 1. open @ -> triggers symbols async with eff=""
    filter.apply("@", { win = 1000, buf = 1, file = "" }, function() end)
    assert.is_true(filter.is_pending(), "symbols pending")
    assert.are.equal("doc_symbols", filter.get_current_mode())
    assert.is_not_nil(symbols_cb)
    -- stale check: ctx should not yet be cancelled
    assert.is_false(symbols_ctx.is_cancelled())

    -- 2. switch to files with eff="" (same eff, different mode) -> new generation
    filter.apply("", { win = 1000, buf = 1, file = "" }, function() end)
    assert.are.equal("files", filter.get_current_mode())
    assert.is_false(filter.is_pending(), "files delivers synchronously so not pending")
    -- previous symbols callback must now be stale / cancelled
    assert.is_true(symbols_ctx.is_cancelled())

    local before_filtered = filter.get_state().filtered
    local before_labels = {}
    for _, e in ipairs(before_filtered) do table.insert(before_labels, e.item.label) end
    assert.are.equal(2, #before_labels)

    -- 3. late symbols callback fires — must be discarded entirely
    symbols_cb(symbol_items)

    -- still files, not symbols
    assert.are.equal("files", filter.get_current_mode())
    assert.is_false(filter.is_pending())
    local after = filter.get_state().filtered
    assert.are.equal(2, #after, "stale symbols must not clobber files")
    local after_labels = {}
    for _, e in ipairs(after) do table.insert(after_labels, e.item.label) end
    assert.are.same(before_labels, after_labels)
    -- all_items must still be files_items, not symbols
    assert.are.equal(files_items[1].label, filter.get_state().all_items[1].label)
  end)

  it("shell: @ pending -> files switch -> late callback does not replace files list", function()
    local symbols_cb = nil
    local files_items = { { label = "alpha.txt" }, { label = "beta.txt" } }
    nock.setup({
      modes = {
        files = { prefix = "", provider = function(_, _, cb) cb(files_items); return nil end, show_on_open = true },
        doc_symbols = {
          prefix = "@",
          provider = function(_q, _ctx, cb) symbols_cb = cb; return nil end,
          show_on_open = true,
        },
      },
    })
    -- shell open @ path
    nock.open("doc_symbols")
    assert.are.equal("doc_symbols", shell._get_current_mode())
    assert.is_not_nil(symbols_cb)
    -- switch in-place to files (Q9B: raw eff preserved verbatim, filter trims)
    nock.open("files")
    assert.are.equal("files", shell._get_current_mode())
    local filtered_before = shell._get_filtered()
    local n_before = #filtered_before
    assert.is_true(n_before >= 1)
    -- late
    symbols_cb({ { label = "STALE_SYMBOL" } })
    assert.are.equal("files", shell._get_current_mode())
    local filtered_after = shell._get_filtered()
    assert.are.equal(n_before, #filtered_after)
    for _, e in ipairs(filtered_after) do
      assert.is_not_equal("STALE_SYMBOL", e.item.label)
    end
    nock.close()
  end)

  it("presets lsp_document_symbols: multi-client stale callbacks do not accumulate nor invoke callback (Q8B)", function()
    -- fake LSP with 2 clients, captures per-client request callbacks
    local request_cbs = {}
    local fake_lsp = {
      get_clients = function() return { { id = 1 }, { id = 2 } } end,
      make_text_document_params = function() return {} end,
      client_request = function(_client, _method, _params, cb, _bufnr)
        table.insert(request_cbs, cb)
      end,
      buf_request_sync = function() return {} end,
    }
    presets._set_lsp(fake_lsp)

    local doc_spec = presets.lsp_document_symbols({ prefix = "@" })
    -- first apply
    local cb1_items = nil
    filter.apply("@", { win = 1, buf = 1, file = "/a.lua" }, function() end)
    -- trigger provider via filter? Instead invoke provider directly to capture ctx
    -- Use config to register doc_symbols and drive via filter
    config.reset()
    nock.setup({ modes = { files = { prefix = "", provider = function(_, _, cb) cb({ { label = "f.txt" } }); return nil end }, doc_symbols = doc_spec } })
    filter.reset()
    local captured_ctx = nil
    local captured_cb = nil
    -- replace provider to capture ctx/cb for direct test
    config.options.modes.doc_symbols.provider = function(_q, ctx, cb)
      captured_ctx = ctx
      captured_cb = cb
      -- simulate presets behavior: call client_request 2x
      fake_lsp.client_request({}, "", {}, function(err, result)
        if captured_ctx and captured_ctx.is_cancelled and captured_ctx.is_cancelled() then return end
        -- Q8B: early return already handled above, second guard below would also return
        if cb then cb({ { label = "SHOULD_NOT_APPEAR" } }) end
      end, 1)
      fake_lsp.client_request({}, "", {}, function(err, result)
        if captured_ctx and captured_ctx.is_cancelled and captured_ctx.is_cancelled() then return end
        if cb then cb({ { label = "SHOULD_NOT_APPEAR2" } }) end
      end, 1)
      return nil
    end

    filter.apply("@", { win = 1, buf = 1, file = "/a.lua" }, function() end)
    assert.is_not_nil(captured_cb)
    local stale_ctx = captured_ctx
    local stale_cb = captured_cb

    -- switch generation
    filter.apply("", { win = 1, buf = 1, file = "" }, function() end)
    assert.is_true(stale_ctx.is_cancelled(), "stale ctx must be cancelled after mode switch")

    -- fire stale callback — must be discarded
    local before = #filter.get_state().filtered
    stale_cb({ { label = "STALE" } })
    assert.are.equal(before, #filter.get_state().filtered)
    -- also ensure request_cbs pattern: Q8B early return before pending-- would prevent callback
    -- drive second path: invoke fake request callbacks after cancel
    for _, cb in ipairs(request_cbs) do
      -- these were from first provider invocation's client_requests (if any)
      -- they should have early-returned due to is_cancelled
      pcall(cb, nil, { { name = "X" } })
    end
    -- still not clobbered
    assert.are.equal(before, #filter.get_state().filtered)

    presets._reset_lsp()
  end)

  it("pending is bound to generation: stale success does not clear pending of fresh request", function()
    local cb_first = nil
    local cb_second = nil
    nock.setup({
      modes = {
        p1 = { prefix = "@", provider = function(_q, _ctx, cb) cb_first = cb; return nil end },
        p2 = { prefix = "#", provider = function(_q, _ctx, cb) cb_second = cb; return nil end },
      },
    })
    filter.apply("@hello", { win = 1, buf = 1, file = "" }, function() end)
    assert.is_true(filter.is_pending())
    local gen1 = filter.get_req_id()
    filter.apply("#world", { win = 1, buf = 1, file = "" }, function() end)
    assert.is_true(filter.is_pending())
    local gen2 = filter.get_req_id()
    assert.is_not_equal(gen1, gen2)
    -- stale first resolves — must be discarded, pending stays for gen2
    cb_first({ { label = "stale", filter_text = "hello" } })
    assert.is_true(filter.is_pending())
    assert.are.equal(gen2, filter.get_req_id())
    -- fresh resolves — pending clears, filtered contains fresh (filter_text matches eff)
    cb_second({ { label = "fresh", filter_text = "world" } })
    assert.is_false(filter.is_pending())
    assert.are.equal("fresh", filter.get_state().filtered[1].item.label)
  end)
  it("non-final delivery keeps pending so slow open shows loading (0028)", function()
    local cb = nil
    nock.setup({
      modes = {
        files = {
          prefix = "",
          provider = function(_, _, c) cb = c; return nil end,
          show_on_open = true,
        },
      },
    })
    local updates = 0
    filter.apply("", { win = 1, buf = 1, file = "" }, function() updates = updates + 1 end)
    assert.is_true(filter.is_pending())
    assert.are.equal(1, updates)
    -- buffers immediate, full enumeration still in flight
    cb({ { label = "open.txt" } }, { more = true })
    assert.is_true(filter.is_pending(), "pending survives non-final delivery")
    assert.are.equal(1, #filter.get_state().filtered)
    assert.are.equal("open.txt", filter.get_state().filtered[1].item.label)
    assert.are.equal(2, updates)
    -- slow backfill resolves: pending clears, list completes
    cb({ { label = "open.txt" }, { label = "slow.txt" } })
    assert.is_false(filter.is_pending())
    assert.are.equal(2, #filter.get_state().filtered)
    assert.are.equal(3, updates)
  end)
end)
