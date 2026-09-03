local M = {}

-- internal state (Filter owns filter pipeline)
local state = {
  all_items = {},
  filtered = {},
  selected_idx = 0,
  offset = 0,
  prev_query = "",
  prev_raw = "",
  pending = false,
}

local current_mode = nil
local req_id = 0
local pending_req = nil
local function resolve_mode_and_query(raw) return require("nock.config").resolve(raw) end

function M.resolve(raw) return resolve_mode_and_query(raw) end

function M.get_state() return state end
function M.get_current_mode() return current_mode end
function M.set_current_mode(m) current_mode = m end
function M.get_req_id() return req_id end
function M.is_pending() return pending_req ~= nil and pending_req == req_id end

function M.reset()
  state.all_items = {}
  state.filtered = {}
  state.selected_idx = 0
  state.offset = 0
  state.prev_query = ""
  state.prev_raw = ""
  state.pending = false
  current_mode = nil
  req_id = 0
  pending_req = nil
end

-- Apply raw query through full pipeline: mode resolution, provider, matcher
-- ctx: { win, buf, file, is_cancelled? } — filter will wrap is_cancelled with generation token
-- on_update: optional function(state, current_mode) called after sync apply and after async callback
function M.apply(raw, ctx, on_update)
  raw = raw or ""
  state.prev_raw = raw
  local cfg = require("nock.config")
  local mode_name, eff_query = resolve_mode_and_query(raw)
  -- Input trim: both ends, %s, eff only (Q1-4). Trims after prefix resolution so prefix matching stays exact.
  -- "   " -> "" reuses empty-query branch (Initial Display, show_on_open) per Q5.
  if eff_query and eff_query ~= "" then
    local trimmed = eff_query:match("^%s*(.-)%s*$")
    if trimmed then eff_query = trimmed end
  end

  req_id = (req_id or 0) + 1
  local cur_req = req_id
  local origin_mode = mode_name
  ctx = ctx or {}
  local orig_cancel = ctx.is_cancelled
  ctx.is_cancelled = function()
    if cur_req ~= req_id then return true end
    if origin_mode ~= current_mode then return true end
    if orig_cancel and orig_cancel() then return true end
    return false
  end

  local function is_stale()
    if cur_req ~= req_id then return true end
    if origin_mode ~= current_mode then return true end
    return false
  end

  local function apply_async_results(items)
    if type(items) ~= "table" then return end
    if is_stale() then return end
    if ctx.is_cancelled and ctx.is_cancelled() then return end
    pending_req = nil
    state.pending = false
    state.all_items = items
    if eff_query == "" then
      local mode_spec = cfg.options.modes[current_mode] or {}
      local show_on_open = mode_spec.show_on_open
      if show_on_open == nil then show_on_open = cfg.options.show_on_open end
      if show_on_open == false then
        state.filtered = {}
        state.selected_idx = 0
      else
        local initial_list = {}
        for _, it in ipairs(items) do
          table.insert(initial_list, { item = it, score = 0, positions = {} })
        end
        state.filtered = initial_list
        state.selected_idx = #initial_list > 0 and 1 or 0
      end
      state.prev_query = ""
    else
      local matcher_opt = cfg.options.matcher
      local matcher = require("nock.matcher")
      local recencyFn = cfg.options._recencyFn or cfg.options.recency
      local results = matcher.filter(eff_query, items, matcher_opt, { recency = recencyFn })
      state.filtered = results or {}
      state.prev_query = eff_query
      if #state.filtered > 0 then
        state.selected_idx = 1
      else
        state.selected_idx = 0
      end
    end
    state.offset = 0
    if on_update then on_update(state, current_mode) end
  end

  if mode_name ~= current_mode then
    current_mode = mode_name
    local spec = cfg.options.modes[mode_name]
    if spec and type(spec.provider) == "function" then
      local ok, items = pcall(spec.provider, "", ctx, apply_async_results)
      if ok and type(items) == "table" then
        state.all_items = items
        state.pending = false
        pending_req = nil
      else
        state.all_items = {}
        local want_pending = spec.provider ~= nil and not (ok and type(items) == "table")
        if want_pending and is_stale() then
          state.pending = false
          pending_req = nil
        else
          state.pending = want_pending
          pending_req = want_pending and cur_req or nil
        end
      end
    else
      state.all_items = {}
      state.pending = false
      pending_req = nil
    end
    state.prev_query = ""
    state.filtered = {}
    state.selected_idx = 0
    state.offset = 0
  end

  if eff_query == "" then
    local mode_spec = cfg.options.modes[current_mode] or {}
    local show_on_open = mode_spec.show_on_open
    if show_on_open == nil then show_on_open = cfg.options.show_on_open end
    if show_on_open == false then
      state.filtered = {}
      state.selected_idx = 0
    else
      local spec = mode_spec
      if spec and type(spec.provider) == "function" then
        local ok, items = pcall(spec.provider, "", ctx, apply_async_results)
        if ok and type(items) == "table" then
          state.all_items = items
          state.pending = false
          pending_req = nil
        else
          -- async pending if provider returned nil (not error)
          if is_stale() then
            state.pending = false
            pending_req = nil
          else
            state.pending = true
            pending_req = cur_req
          end
        end
      else
        state.pending = false
        pending_req = nil
      end
      local initial_list = {}
      for _, it in ipairs(state.all_items) do
        table.insert(initial_list, { item = it, score = 0, positions = {} })
      end
      state.filtered = initial_list
      state.selected_idx = #initial_list > 0 and 1 or 0
    end
    state.offset = 0
    if on_update then on_update(state, current_mode) end
    return
  end

  local source
  local function use_incremental()
    if state.prev_query == "" or #eff_query <= #state.prev_query then return false end
    if eff_query:sub(1, #state.prev_query) ~= state.prev_query then return false end
    if #state.filtered == 0 then return false end
    local spec = cfg.options.modes[current_mode]
    if spec and spec.incremental == false then return false end
    return true
  end
  if use_incremental() then
    source = {}
    for _, e in ipairs(state.filtered) do
      table.insert(source, e.item)
    end
    state.pending = false
    pending_req = nil
  else
    local spec = cfg.options.modes[current_mode]
    if spec and type(spec.provider) == "function" then
      local ok, items = pcall(spec.provider, eff_query, ctx, apply_async_results)
      if ok and type(items) == "table" then
        state.all_items = items
        state.pending = false
        pending_req = nil
      else
        if is_stale() then
          state.pending = false
          pending_req = nil
        else
          state.pending = true
          pending_req = cur_req
        end
        if state.pending then
          if on_update then on_update(state, current_mode) end
          return
        end
      end
    else
      state.pending = false
      pending_req = nil
    end
    source = state.all_items
  end

  local matcher_opt = cfg.options.matcher
  local matcher = require("nock.matcher")
  local recencyFn = cfg.options._recencyFn or cfg.options.recency
  local results = matcher.filter(eff_query, source, matcher_opt, { recency = recencyFn })
  state.filtered = results or {}
  state.prev_query = eff_query
  if #state.filtered > 0 then
    state.selected_idx = 1
  else
    state.selected_idx = 0
  end
  state.offset = 0
  if on_update then on_update(state, current_mode) end
end

return M
