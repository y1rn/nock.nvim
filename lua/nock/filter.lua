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
-- Q12a: filter owns the kill handle of the latest generation.
-- Provider contract (async-only): provider(query, ctx, callback) -> nil, cancel_fn?
local pending_cancel = nil
local function cancel_prev()
  if type(pending_cancel) == "function" then
    local f = pending_cancel
    pending_cancel = nil
    pcall(f)
  else
    pending_cancel = nil
  end
end
function M.cancel_pending() cancel_prev() end
local function resolve_mode_and_query(raw) return require("nock.config").resolve(raw) end

function M.resolve(raw) return resolve_mode_and_query(raw) end

function M.get_state() return state end
function M.get_current_mode() return current_mode end
function M.set_current_mode(m) current_mode = m end
function M.get_req_id() return req_id end
function M.is_pending() return pending_req ~= nil and pending_req == req_id end

function M.reset()
  cancel_prev()
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
-- Async-only: provider MUST return nil (+ optional cancel_fn) and later callback(items).
-- ctx: { win, buf, file, is_cancelled? } — filter will wrap is_cancelled with generation token
-- on_update: optional function(state, current_mode) called after apply and after async callback
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

  -- True kill (Q7): new generation kills the previous in-flight job first.
  cancel_prev()
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

  -- Set when the provider delivers synchronously inside pcall (test doubles).
  -- Production providers deliver via vim.schedule / job callback (async tick).
  local resolved_final = false
  -- `opts.more=true` marks a non-final delivery (files empty+show buffers
  -- immediate, full enumeration still in flight): state refreshes and
  -- on_update fires, but pending stays bound to this generation so the
  -- Loading Indicator grace timer survives until the final callback.
  local function apply_async_results(items, opts)
    if type(items) ~= "table" then return end
    if is_stale() then return end
    if ctx.is_cancelled and ctx.is_cancelled() then return end
    local more = type(opts) == "table" and opts.more == true
    if not more then
      resolved_final = true
      pending_req = nil
      state.pending = false
    end
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

  -- Mode switch: reset session state only. The single provider call below
  -- (empty / non-empty branch) fills the new session; no double enumeration.
  if mode_name ~= current_mode then
    current_mode = mode_name
    state.all_items = {}
    state.prev_query = ""
    state.filtered = {}
    state.selected_idx = 0
    state.offset = 0
    state.pending = false
    pending_req = nil
  end

  if eff_query == "" then
    local mode_spec = cfg.options.modes[current_mode] or {}
    local show_on_open = mode_spec.show_on_open
    if show_on_open == nil then show_on_open = cfg.options.show_on_open end
    if show_on_open == false then
      state.filtered = {}
      state.selected_idx = 0
      state.pending = false
      pending_req = nil
    else
      local spec = mode_spec
      if spec and type(spec.provider) == "function" then
        state.all_items = {}
        local ok, _, cancel_fn = pcall(spec.provider, "", ctx, apply_async_results)
        if not ok then
          state.pending = false
          pending_req = nil
          pending_cancel = nil
        elseif resolved_final then
          -- Synchronous delivery inside pcall (test doubles): keep callback state.
          state.pending = false
          pending_req = nil
          pending_cancel = nil
        elseif is_stale() then
          if type(cancel_fn) == "function" then pcall(cancel_fn) end
          pending_cancel = nil
          state.pending = false
          pending_req = nil
        else
          state.pending = true
          pending_req = cur_req
          pending_cancel = type(cancel_fn) == "function" and cancel_fn or nil
        end
      else
        state.pending = false
        pending_req = nil
      end
      if not resolved_final then
        state.filtered = {}
        state.selected_idx = 0
      end
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
      state.all_items = {}
      local ok, _, cancel_fn = pcall(spec.provider, eff_query, ctx, apply_async_results)
      if not ok then
        state.pending = false
        pending_req = nil
        pending_cancel = nil
      elseif resolved_final then
        state.pending = false
        pending_req = nil
        pending_cancel = nil
      elseif is_stale() then
        if type(cancel_fn) == "function" then pcall(cancel_fn) end
        pending_cancel = nil
        state.pending = false
        pending_req = nil
      else
        state.pending = true
        pending_req = cur_req
        pending_cancel = type(cancel_fn) == "function" and cancel_fn or nil
      end
      if state.pending then
        -- Q4: non-empty pending clears the list and shows the spinner.
        state.filtered = {}
        state.selected_idx = 0
        state.offset = 0
        if on_update then on_update(state, current_mode) end
        return
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
