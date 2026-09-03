local M = {}

local function format_item_label(item)
  if not item then return "" end
  local label = item.label or item.value or ""
  if (not item.icon or item.icon == "") and item.kind then
    local ok2, cfg2 = pcall(require, "nock.config")
    local def = ok2 and cfg2.defaults and cfg2.defaults.icons and cfg2.defaults.icons.symbols or {}
    local ic = def[item.kind] or def[item.kind:lower()]
    if ic then item.icon = ic end
  end
  if item.icon and type(item.icon) == "string" and item.icon ~= "" then
    local ok, cfg = pcall(require, "nock.config")
    local enabled = not (ok and cfg.options and cfg.options.icons and cfg.options.icons.enabled == false)
    if not enabled and item.kind then
      local is_goto = ({ reference = true, references = true, definition = true, declaration = true, implementation = true, typedefinition = true })[item.kind:lower()]
      if is_goto then enabled = true end
    end
    if enabled then
      if label:sub(1, #item.icon) ~= item.icon then return item.icon .. " " .. label end
      return label
    end
  end
  if item.kind and type(item.kind) == "string" and item.kind ~= "" then
    local prefix = "[" .. item.kind .. "] "
    if label:sub(1, #prefix) ~= prefix then return prefix .. label end
  end
  return label
end

-- Pure render: builds buffer lines and extmarks from filtered state
-- opts: { buf, win, filtered, offset, selected_idx, query_line, width, maxheight, ns_id }
-- Returns { offset = clamped_offset, ns_id = ns }
function M.render(opts)
  opts = opts or {}
  local buf = opts.buf
  local filtered = opts.filtered or {}
  local offset = opts.offset or 0
  local selected_idx = opts.selected_idx or 0
  local query_line = opts.query_line or ""
  local width = opts.width or 40
  local maxheight = opts.maxheight or 10
  local ns_id = opts.ns_id

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return { offset = offset, ns_id = ns_id }
  end

  local count = #filtered
  local visible = math.min(count, maxheight)

  -- clamp offset
  if count <= maxheight then
    offset = 0
  else
    if offset < 0 then
      offset = 0
    elseif offset + visible > count then
      offset = count - visible
    end
  end

  -- Padding: hard-coded 1 left / 1 right, inner width = width - 2 (A: inner)
  -- Rendered via virt_text (non-editable) to avoid deletable buffer spaces causing flash on <BS>/<Del>
  local PAD_L, PAD_R = 1, 1
  local inner = width - PAD_L - PAD_R
  if inner < 1 then inner = 1 end
  local function truncate_to_inner(s)
    s = s or ""
    if vim.api.nvim_strwidth(s) <= inner then return s end
    local approx = vim.fn.strcharpart(s, 0, inner)
    while vim.api.nvim_strwidth(approx) > inner and #approx > 0 do
      approx = approx:sub(1, #approx - 1)
      approx = vim.fn.strcharpart(approx, 0, vim.fn.strchars(approx) - 1)
    end
    return approx
  end

  local q_trunc = truncate_to_inner(query_line)
  local lines = { q_trunc }
  if count > 0 then
    local sep_line = string.rep("─", width)
    table.insert(lines, sep_line)
    for i = 1, visible do
      local idx = offset + i
      local entry = filtered[idx]
      if entry then
        table.insert(lines, truncate_to_inner(format_item_label(entry.item)))
      end
    end
  end

  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)

  if ns_id then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns_id, 0, -1)
  else
    ns_id = vim.api.nvim_create_namespace("nock")
  end

  -- Virtual padding: 1 space left/right for Input and List rows (non-editable)
  -- Input row 0: force NormalFloat bg to override any Search/illuminate/syntax bg that may leak
  -- (log shows syntax:"" hlsearch:false extmark clean but still bg, so force NormalFloat)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, 0, 0, {
    line_hl_group = "NormalFloat",
    hl_eol = true,
    priority = 10000,
  })
  -- Input row 0 virt padding
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, 0, 0, {
    virt_text = { { string.rep(" ", PAD_L), "Normal" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, 0, #q_trunc, {
    virt_text = { { string.rep(" ", PAD_R), "Normal" } },
    virt_text_pos = "inline",
  })
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, 1, 0, {
    line_hl_group = "NockSeparator",
    hl_eol = true,
  })

  local has_overflow = count > maxheight
  local thumb_start, thumb_end = nil, nil
  if has_overflow then
    local thumb_h = math.max(1, math.floor(visible * visible / count + 0.5))
    if thumb_h > visible then thumb_h = visible end
    local max_offset = count - visible
    local thumb_offset = 0
    if max_offset > 0 then
      thumb_offset = math.floor(offset * (visible - thumb_h) / max_offset + 0.5)
    end
    thumb_start = thumb_offset + 1
    thumb_end = thumb_offset + thumb_h
  end

  for i = 1, visible do
    local idx = offset + i
    local entry = filtered[idx]
    if entry then
      local row = 1 + i
      -- Virtual padding for List rows (left/right 1, non-editable)
      local label_trunc = truncate_to_inner(format_item_label(entry.item))
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, row, 0, {
        virt_text = { { string.rep(" ", PAD_L), "Normal" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, row, #label_trunc, {
        virt_text = { { string.rep(" ", PAD_R), "Normal" } },
        virt_text_pos = "inline",
      })
      -- offset positions by kind/icon prefix when present
      local kind_offset = 0
      local display = format_item_label(entry.item)
      do
        local has_icon = entry.item.icon and type(entry.item.icon) == "string" and entry.item.icon ~= ""
        local icon_enabled = true
        local ok, cfg = pcall(require, "nock.config")
        if ok and cfg.options and cfg.options.icons and cfg.options.icons.enabled == false then icon_enabled = false end
        if has_icon and icon_enabled then
          local icon_pref = entry.item.icon .. " "
          if display:sub(1, #icon_pref) == icon_pref then kind_offset = #icon_pref end
        elseif entry.item.kind and type(entry.item.kind) == "string" and entry.item.kind ~= "" then
          local prefix = "[" .. entry.item.kind .. "] "
          if display:sub(1, #prefix) == prefix then kind_offset = #prefix end
        end
      end
      for _, col in ipairs(entry.positions or {}) do
        if type(col) == "number" and col >= 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, row, col + kind_offset, {
            end_col = col + kind_offset + 1,
            hl_group = "NockMatch",
          })
        end
      end
      if idx == selected_idx then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, row, 0, {
          line_hl_group = "NockSelected",
          hl_eol = true,
        })
      end
      if has_overflow and thumb_start and i >= thumb_start and i <= thumb_end then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, row, 0, {
          virt_text = { { "▐", "NockScrollbar" } },
          virt_text_pos = "right_align",
          hl_mode = "combine",
        })
      end
    end
  end

  return { offset = offset, ns_id = ns_id }
end

M.format_item_label = format_item_label

return M
