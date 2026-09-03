local M = {}

-- Recency weighting stub (spec story 25: score -> length -> recency)
-- Single shape via filter opts: nil|fun|map passed explicitly.
--   nil -> 0, fun(item)->number, map { [label]=score, [path]=score }
-- When absent, returns 0 so original score->length order is preserved.
-- No pcall(require) hot path; caller (M.filter) resolves config once.
---@param recency table|fun(item:table):number|nil
local function recency_score(item, recency)
  if recency == nil then
    return 0
  end
  if type(recency) == "function" then
    local ok, v = pcall(recency, item)
    if ok and type(v) == "number" then
      return v
    end
    if ok and v then
      return 1
    end
    return 0
  end
  if type(recency) == "table" then
    local label = item.label or item.value or ""
    local v = recency[label]
    if v ~= nil then
      if type(v) == "number" then
        return v
      end
      if v then
        return 1
      end
      return 0
    end
    local path = item.location and item.location.path or nil
    if path then
      v = recency[path]
      if v ~= nil then
        if type(v) == "number" then
          return v
        end
        if v then
          return 1
        end
        return 0
      end
    end
    return 0
  end
  return 0
end
---@param recency table|fun(item:table):number|nil
-- Single comparator factory reused across all sort sites: score desc -> label length asc -> recency desc
local function make_cmp(recency)
  return function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    local la = #(a.item.filter_text or a.item.label or "")
    local lb = #(b.item.filter_text or b.item.label or "")
    if la ~= lb then
      return la < lb
    end
    local ra = recency_score(a.item, recency)
    local rb = recency_score(b.item, recency)
    if ra ~= rb then
      return ra > rb
    end
    return false
  end
end

-- Default cmp without recency (preserves score->length order when recency absent)
local function cmp(a, b)
  if a.score ~= b.score then
    return a.score > b.score
  end
  local la = #(a.item.filter_text or a.item.label or "")
  local lb = #(b.item.filter_text or b.item.label or "")
  if la ~= lb then
    return la < lb
  end
  return false
end

---@param recency table|fun(item:table):number|nil
local function sort_results(t, recency)
  table.sort(t, make_cmp(recency))
  return t
end

-- Pure Lua fzy fallback ----------------------------------------------------
---@param recency table|fun(item:table):number|nil
local function lua_fzy(query, items, recency)
  if query == "" or query == nil then
    return {}
  end
  local q = query:lower()
  local qlen = #q
  local results = {}
  for _, item in ipairs(items) do
    local label = item.filter_text or item.label or ""
    local lower = label:lower()
    local positions = {} -- 0-indexed byte positions for extmarks
    local idx = 1
    local ok = true
    for i = 1, qlen do
      local qc = q:sub(i, i)
      local found = nil
      for j = idx, #lower do
        if lower:sub(j, j) == qc then
          table.insert(positions, j - 1) -- 0-index
          found = j
          idx = j + 1
          break
        end
      end
      if not found then
        ok = false
        break
      end
    end
    if ok then
      -- scoring: higher is better
      local score = 100
      -- penalize first char distance
      if #positions > 0 then
        score = score - positions[1]
        if positions[1] == 0 then
          score = score + 10
        end
        for k = 2, #positions do
          if positions[k] == positions[k - 1] + 1 then
            score = score + 5
          else
            score = score - (positions[k] - positions[k - 1] - 1)
          end
        end
        -- bonus for separator boundaries
        for _, pos in ipairs(positions) do
          if pos > 0 then
            local prev = label:sub(pos, pos)
            if prev:match("[/_%-%s%.]") then
              score = score + 3
            end
          end
        end
      end
      table.insert(results, { item = item, score = score, positions = positions })
    end
  end
  sort_results(results, recency)
  return results
end

-- vim.fn.matchfuzzypos path -----------------------------------------------
---@param recency table|fun(item:table):number|nil
local function vim_match(query, items, recency)
  if query == "" or query == nil then
    return {}
  end
  if vim.fn.exists("*matchfuzzypos") == 0 then
    return nil
  end
  local labels = {}
  local label_to_idx = {}
  local has_dup = false
  for i, it in ipairs(items) do
    local lab = it.filter_text or it.label or ""
    if label_to_idx[lab] then
      has_dup = true
    else
      label_to_idx[lab] = i
    end
    labels[i] = lab
  end
  -- If duplicate labels exist, delegate to lua_fzy to preserve exact scores and item identities
  if has_dup then
    return lua_fzy(query, items, recency)
  end

  local ok, res = pcall(vim.fn.matchfuzzypos, labels, query)
  if not ok or type(res) ~= "table" or #res < 3 then
    return nil
  end
  local matched = res[1]
  local pos_list = res[2]
  local scores = res[3]
  if type(matched) ~= "table" or #matched == 0 then
    return {}
  end
  local results = {}
  for i, mstr in ipairs(matched) do
    local item_idx = label_to_idx[mstr]
    if item_idx and items[item_idx] then
      local item = items[item_idx]
      local positions = pos_list[i] or {}
      local score = scores[i] or 0
      table.insert(results, { item = item, score = score, positions = positions })
    end
  end
  sort_results(results, recency)
  return results
end

-- native attempt -----------------------------------------------------------
---@param recency table|fun(item:table):number|nil
local function native_match(query, items, recency)
  local ok, mod = pcall(require, "nock.native")
  if not ok or not mod then
    -- also try fzy native module name variant
    ok, mod = pcall(require, "nock_native")
    if not ok or not mod then
      return nil
    end
  end
  -- native module may expose match or filter
  local fn = mod.match or mod.filter or mod.fuzzy
  if type(fn) ~= "function" then
    return nil
  end
  local ok2, res = pcall(fn, query, items)
  if not ok2 or type(res) ~= "table" then
    return nil
  end
  -- normalize if already {item,score,positions}
  if #res > 0 and res[1].item then
    sort_results(res, recency)
    return res
  end
  -- if native returned plain Item[] without scores, wrap
  if #res > 0 and res[1].label then
    local out = {}
    for _, it in ipairs(res) do
      table.insert(out, { item = it, score = 0, positions = {} })
    end
    return out
  end
  return res
end

--- Main filter: resolves chain per matcher option, normalizes to {item,score,positions} sorted.
---@param query string
---@param items table Item[]
---@param matcher_opt string|function|nil
---@param opts table|nil optional { recency?: table|fun(item:table):number|nil } or recency directly
---@return table results sorted score desc -> label length asc -> recency
function M.filter(query, items, matcher_opt, opts)
  query = query or ""
  items = items or {}

  -- Resolve recency from explicit opts (single shape). No hot pcall here per-item.
  local recency
  if opts ~= nil then
    if type(opts) == "table" and opts.recency ~= nil then
      recency = opts.recency
    elseif type(opts) == "function" then
      recency = opts
    end
  end

  -- Resolve matcher_opt and fallback recency from config exactly once (non-hot) for backward compat when opts not provided
  if matcher_opt == nil then
    local cfg_ok, cfg = pcall(require, "nock.config")
    if cfg_ok and cfg and cfg.options then
      matcher_opt = cfg.options.matcher
      if recency == nil then
        recency = cfg.options.recency
      end
    else
      matcher_opt = "auto"
    end
  else
    if recency == nil then
      local cfg_ok, cfg = pcall(require, "nock.config")
      if cfg_ok and cfg and cfg.options and cfg.options.recency ~= nil then
        recency = cfg.options.recency
      end
    end
  end

  -- injected function path
  if type(matcher_opt) == "function" then
    local ok, res = pcall(matcher_opt, query, items)
    if ok and type(res) == "table" then
      if #res > 0 and res[1].item then
        sort_results(res, recency)
        return res
      end
      if #res > 0 and res[1].label then
        local out = {}
        for _, it in ipairs(res) do
          table.insert(out, { item = it, score = 0, positions = {} })
        end
        return out
      end
      if #res == 0 then
        return res
      end
      return res
    end
    -- fall through to fallback on error
  end

  local handlers = {
    ["vim.fn"] = function()
      local r = vim_match(query, items, recency)
      if r ~= nil then
        return r
      end
      return lua_fzy(query, items, recency)
    end,
    native = function()
      local r = native_match(query, items, recency)
      if r ~= nil then
        return r
      end
      return lua_fzy(query, items, recency)
    end,
    lua = function()
      return lua_fzy(query, items, recency)
    end,
    fzy = function()
      return lua_fzy(query, items, recency)
    end,
    auto = function()
      local r = vim_match(query, items, recency)
      if r ~= nil then
        return r
      end
      local nr = native_match(query, items, recency)
      if nr ~= nil then
        return nr
      end
      return lua_fzy(query, items, recency)
    end,
  }

  local h = handlers[matcher_opt]
  if h then
    return h()
  end
  -- unknown string: treat as auto
  local r = vim_match(query, items, recency)
  if r ~= nil then
    return r
  end
  return lua_fzy(query, items, recency)
end

-- Alias
M.match = M.filter

-- Exposed for testing / forcing fallback
M._lua_fzy = lua_fzy
M._vim_match = vim_match
M._native_match = native_match
M._cmp = cmp
M._make_cmp = make_cmp
M._recency_score = recency_score
M._sort_results = sort_results

return M
