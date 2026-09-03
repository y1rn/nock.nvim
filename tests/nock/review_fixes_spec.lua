-- Micro tests for review fixes: dedup, plain search, recency stub
describe("nock review fixes", function()
  local matcher, config

  before_each(function()
    package.loaded["nock.matcher"] = nil
    package.loaded["nock.config"] = nil
    package.loaded["nock.providers.files"] = nil
    config = require("nock.config")
    matcher = require("nock.matcher")
    config.reset()
  end)

  after_each(function()
    config.reset()
  end)

  it("vim_match preserves duplicate labels with distinct Item identity", function()
    local items = {
      { label = "dup.txt", value = "a" },
      { label = "dup.txt", value = "b" },
      { label = "dup.txt", value = "c" },
    }
    local res = matcher._vim_match("dup", items)
    assert.is_not_nil(res)
    assert.are.equal(3, #res)
    local vals = {}
    for _, r in ipairs(res) do vals[r.item.value] = true end
    assert.is_true(vals["a"] and vals["b"] and vals["c"])
    config.options.matcher = "vim.fn"
    local res2 = matcher.filter("dup", items)
    assert.are.equal(3, #res2)
  end)

  it("files is_ignored_path uses plain search (magic chars not expanded)", function()
    local files = require("nock.providers.files")
    local is_ignored = files._is_ignored_path
    assert.is_not_nil(is_ignored)
    assert.is_true(is_ignored("a.lua", { "a.lua" }))
    assert.is_false(is_ignored("aXlua", { "a.lua" }))
    assert.is_false(is_ignored("src/aXlua", { "a.lua" }))
    assert.is_true(is_ignored("foo/.git/bar.txt", { ".git" }))
    assert.is_true(is_ignored(".git/inside.txt", { ".git" }))
    assert.is_false(is_ignored("foo/git/bar.txt", { ".git" }))
    assert.is_true(is_ignored("foo/.DS_Store", { ".DS_Store" }))
    assert.is_true(is_ignored("a/b/.DS_Store/file", { ".DS_Store" }))
    assert.is_false(is_ignored("a", { "[a]" }))
    assert.is_true(is_ignored("[a]", { "[a]" }))
    -- integration via provider
    local tmp = vim.fn.tempname() .. "_nock_review_ignore"
    vim.fn.mkdir(tmp .. "/keep", "p")
    vim.fn.writefile({ "x" }, tmp .. "/keep/file.txt")
    vim.fn.mkdir(tmp .. "/.git", "p")
    vim.fn.writefile({ "x" }, tmp .. "/.git/inside.txt")
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp))
    config.options.files.ignore = { ".git" }
    config.options.modes.files.ignore = nil
    config.options.files.fd_cmd = false
    config.options.modes.files.fd_cmd = false
    local items = files.provider(".")
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    local labels = {}
    for _, it in ipairs(items) do labels[it.label] = true end
    assert.is_nil(labels[".git/inside.txt"])
    assert.is_true(labels["keep/file.txt"] == true)
    vim.fn.delete(tmp, "rf")
    config.reset()
  end)

  it("recency weighting is tie-breaker after score and length", function()
    local items = {
      { label = "aa/bb.txt", value = "old" },
      { label = "aa/cc.txt", value = "recent" },
    }
    config.options.matcher = "lua"
    local res_no = matcher.filter("aa", items, "lua")
    assert.are.equal(2, #res_no)
    config.options.recency = { ["aa/cc.txt"] = 1 }
    local res = matcher.filter("aa", items, "lua")
    assert.are.equal(2, #res)
    assert.are.equal("aa/cc.txt", res[1].item.label)
    assert.are.equal("aa/bb.txt", res[2].item.label)
    config.options.recency = nil
    local res3 = matcher.filter("aa", items, "lua")
    assert.are.equal(2, #res3)
    config.options.recency = { ["aa/bb.txt"] = 10, ["aa/cc.txt"] = 1 }
    config.options.matcher = "vim.fn"
    local res4 = matcher.filter("aa", items, "vim.fn")
    assert.are.equal(2, #res4)
    assert.are.equal("aa/bb.txt", res4[1].item.label)
  end)

  it("cmp is reused and recency absent does not change order", function()
    local items = {
      { label = "a.txt" },
      { label = "aa.txt" },
      { label = "aaa.txt" },
    }
    config.options.recency = nil
    local res = matcher.filter("a", items, "lua")
    assert.are.equal(3, #res)
    assert.are.equal("a.txt", res[1].item.label)
  end)

  it("recency via explicit opts.recency nil|fun|map and score->length->recency preserved", function()
    local items = {
      { label = "aa/bb.txt", value = "bb" },
      { label = "aa/cc.txt", value = "cc" },
    }
    -- nil recency via opts keeps score->length order (both equal, recency 0)
    local res_nil = matcher.filter("aa", items, "lua", { recency = nil })
    assert.are.equal(2, #res_nil)
    -- map recency
    local res_map = matcher.filter("aa", items, "lua", { recency = { ["aa/cc.txt"] = 5 } })
    assert.are.equal("aa/cc.txt", res_map[1].item.label)
    assert.are.equal("aa/bb.txt", res_map[2].item.label)
    -- fun recency
    local fun = function(item) return item.label == "aa/bb.txt" and 10 or 0 end
    local res_fun = matcher.filter("aa", items, "lua", { recency = fun })
    assert.are.equal("aa/bb.txt", res_fun[1].item.label)
    -- direct _recency_score shape trimmed to nil|fun|map
    assert.are.equal(0, matcher._recency_score({ label = "x" }, nil))
    assert.are.equal(5, matcher._recency_score({ label = "a" }, { a = 5 }))
    assert.are.equal(1, matcher._recency_score({ label = "a" }, { a = true }))
    assert.are.equal(0, matcher._recency_score({ label = "b" }, { a = 1 }))
    assert.are.equal(10, matcher._recency_score({ label = "a" }, function() return 10 end))
    -- sort_results helper reused (single cmp definition)
    assert.is_not_nil(matcher._sort_results)
    local t = {
      { item = { label = "bbb" }, score = 10 },
      { item = { label = "a" }, score = 10 },
    }
    matcher._sort_results(t, nil)
    assert.are.equal("a", t[1].item.label)
    local t2 = {
      { item = { label = "aa/bb.txt" }, score = 5 },
      { item = { label = "aa/cc.txt" }, score = 5 },
    }
    matcher._sort_results(t2, { ["aa/cc.txt"] = 1 })
    assert.are.equal("aa/cc.txt", t2[1].item.label)
  end)

  it("filter dispatch map handles handlers and unknown fallback", function()
    local items = {
      { label = "foo.txt" },
      { label = "bar.txt" },
    }
    -- explicit handlers
    assert.are.equal(1, #matcher.filter("foo", items, "lua", { recency = nil }))
    assert.are.equal(1, #matcher.filter("foo", items, "fzy", { recency = nil }))
    local r_auto = matcher.filter("foo", items, "auto", { recency = nil })
    assert.is_not_nil(r_auto)
    local r_vim = matcher.filter("foo", items, "vim.fn", { recency = nil })
    assert.is_not_nil(r_vim)
    local r_native = matcher.filter("foo", items, "native", { recency = nil })
    assert.is_not_nil(r_native)
    -- unknown string fallback behaves like auto (no error)
    local r_unknown = matcher.filter("foo", items, "bogus", { recency = nil })
    assert.is_not_nil(r_unknown)
    -- function matcher path still sorts via sort_results
    local fn = function(q, its)
      return { { item = its[2], score = 1, positions = {} }, { item = its[1], score = 10, positions = {} } }
    end
    local r_fn = matcher.filter("foo", items, fn, { recency = nil })
    assert.are.equal(10, r_fn[1].score)
  end)
end)
