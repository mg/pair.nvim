local M = {}
local api = vim.api
local context = require("pair.context")
local sessions = require("pair.sessions")
local chat_ns = api.nvim_create_namespace("pair.nvim.chat")
local wheel_ns = api.nvim_create_namespace("pair.nvim.chat_wheel")
local status_ns = api.nvim_create_namespace("pair.nvim.status")

local chat_buf
local chat_win
local header_buf
local header_win
local input_buf
local input_win
local entries = {}
local tool_rows = {}
local history_file
local persist_error_shown = false
local on_send
local on_cancel
local status = { backend = "codex", activity = "Ready", queued = 0 }
local cancel_column
local cancel_text
local source_mru = {}
local forwarding_quit = false
local follow_bottom = true
local adjusting_scroll = false
local input_context_mode = "full"
local input_submission_pending = false

local function brighten(color, amount)
  local toward = amount >= 0 and 255 or 0
  local fraction = math.abs(amount)
  local function channel(shift)
    local value = math.floor(color / 2 ^ shift) % 256
    return math.floor(value + (toward - value) * fraction + 0.5)
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

local function define_highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local accent = api.nvim_get_hl(0, { name = "Title", link = false })
  local base = normal.bg or (vim.o.background == "dark" and 0x202020 or 0xf0f0f0)
  local foreground = normal.fg or (vim.o.background == "dark" and 0xe8e8e8 or 0x222222)
  local accent_fg = accent.fg or foreground
  local input_bg = brighten(base, vim.o.background == "dark" and 0.09 or -0.06)
  api.nvim_set_hl(0, "PairAgent", { fg = foreground })
  api.nvim_set_hl(0, "PairUserMessage", { bg = brighten(base, vim.o.background == "dark" and 0.13 or -0.1), fg = foreground })
  api.nvim_set_hl(0, "PairNotice", { fg = brighten(foreground, vim.o.background == "dark" and -0.24 or 0.24) })
  api.nvim_set_hl(0, "PairTool", { fg = brighten(foreground, vim.o.background == "dark" and -0.24 or 0.24) })
  api.nvim_set_hl(0, "PairToolSuccess", { fg = 0x80b890 })
  api.nvim_set_hl(0, "PairToolFailure", { fg = 0xe07a7a })
  api.nvim_set_hl(0, "PairHeading", { fg = accent_fg, bold = true })
  api.nvim_set_hl(0, "PairCode", { link = "String" })
  api.nvim_set_hl(0, "PairCodeFence", { fg = accent_fg })
  api.nvim_set_hl(0, "PairChatHeader", { bg = brighten(base, vim.o.background == "dark" and 0.04 or -0.18), fg = accent_fg, bold = true })
  api.nvim_set_hl(0, "PairStatus", { bg = brighten(base, vim.o.background == "dark" and 0.04 or -0.18), fg = foreground })
  api.nvim_set_hl(0, "PairStatusCancel", { bg = brighten(base, vim.o.background == "dark" and 0.04 or -0.18), fg = 0xe07a7a, bold = true })
  api.nvim_set_hl(0, "PairInput", { bg = input_bg, fg = foreground })
  api.nvim_set_hl(0, "PairInputPrompt", { bg = input_bg, fg = accent_fg, bold = true })
  api.nvim_set_hl(0, "PairPrompt", { bg = input_bg, fg = foreground })
  api.nvim_set_hl(0, "PairPromptBorder", { bg = input_bg, fg = accent_fg })
  api.nvim_set_hl(0, "PairPromptTitle", { bg = input_bg, fg = accent_fg, bold = true })
end

define_highlights()
api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

local function persist()
  if not history_file then return end
  local ok, err = sessions.save_transcript(history_file, entries)
  if not ok and not persist_error_shown then
    persist_error_shown = true
    vim.notify("Pair: Could not save chat transcript: " .. tostring(err), vim.log.levels.ERROR)
  elseif ok then
    persist_error_shown = false
  end
end

local function valid_window(win)
  return win and api.nvim_win_is_valid(win)
end

local function clip(text, width)
  if width <= 0 then return "" end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  if width == 1 then return "…" end
  return vim.fn.strcharpart(text, 0, width - 1) .. "…"
end

local function render_header()
  if not header_buf or not api.nvim_buf_is_valid(header_buf) then return end
  -- Leave one cell clear of the split edge so the cancel target is clickable.
  local width = math.max(1, (valid_window(header_win) and api.nvim_win_get_width(header_win) or 60) - 1)
  local title = " Pair Chat"
  local cancel = status.cancellable and " [Cancel]" or ""
  local queued = status.queued and status.queued > 0 and (" | " .. status.queued .. " queued") or ""
  local backend = tostring(status.backend or "agent")
  local activity = tostring(status.activity or "Ready")
  local model = status.model and tostring(status.model) or nil
  local model_text = model and (" | " .. model) or ""
  local right = backend .. model_text .. " | " .. activity .. queued .. cancel
  if vim.fn.strdisplaywidth(title .. " " .. right) > width then
    local short_activity = activity:gsub("Connecting", "Start")
      :gsub("inspecting", "read"):gsub("replying", "reply")
      :gsub("generating", "gen"):gsub("thinking", "wait")
      :gsub("cancelling", "stop"):gsub("Review proposal", "Review")
    local short_queue = status.queued > 0 and (" " .. status.queued .. "q") or ""
    right = backend .. (model and "/" .. model or "") .. " " .. short_activity .. short_queue .. cancel
    if vim.fn.strdisplaywidth(title .. " " .. right) > width then
      cancel = status.cancellable and " [X]" or ""
      right = backend .. (model and "/" .. model or "") .. " " .. short_activity .. short_queue .. cancel
    end
    if vim.fn.strdisplaywidth(title .. " " .. right) > width then
      right = backend .. " " .. short_activity .. short_queue .. cancel
    end
  end
  if model and not right:find(model, 1, true) then
    local short_action = activity:match("^[^:]+") or activity
    local short_queue = status.queued > 0 and (" " .. status.queued .. "q") or ""
    local base = backend .. " " .. short_action .. short_queue .. cancel
    local room = width - vim.fn.strdisplaywidth(title .. " " .. base .. "/")
    if room >= 3 then
      local candidate = backend .. "/" .. clip(model, room) .. " " .. short_action .. short_queue .. cancel
      if vim.fn.strdisplaywidth(title .. " " .. candidate) <= width then right = candidate end
    end
  end
  if vim.fn.strdisplaywidth(title .. " " .. right) > width then
    local short_action = activity:match("^[^:]+") or activity
    local short_queue = status.queued > 0 and (" " .. status.queued .. "q") or ""
    local base = backend .. " " .. short_action .. short_queue .. cancel
    local room = width - vim.fn.strdisplaywidth(title .. " " .. base .. "/")
    right = backend .. (model and room >= 3 and ("/" .. clip(model, room)) or "")
      .. " " .. short_action .. short_queue .. cancel
  end
  if vim.fn.strdisplaywidth(title .. " " .. right) > width then
    right = clip(backend, 6) .. " " .. clip(activity, 7)
      .. (status.queued > 0 and (" " .. status.queued .. "q") or "") .. cancel
  end
  if vim.fn.strdisplaywidth(title .. " " .. right) > width then
    right = clip(right, math.max(0, width - vim.fn.strdisplaywidth(title) - 1))
  end
  local space = math.max(0, width - vim.fn.strdisplaywidth(title) - vim.fn.strdisplaywidth(right))
  local prefix = title .. string.rep(" ", space)
  local line = prefix .. right
  cancel_text = status.cancellable and right:sub(-#cancel) == cancel and cancel or nil
  cancel_column = cancel_text
    and vim.fn.strdisplaywidth(line:sub(1, #line - #cancel)) + 1 or nil
  local current = api.nvim_buf_get_lines(header_buf, 0, 1, false)[1]
  if current ~= line then
    api.nvim_set_option_value("modifiable", true, { buf = header_buf })
    api.nvim_buf_set_lines(header_buf, 0, -1, false, { line })
    api.nvim_set_option_value("modifiable", false, { buf = header_buf })
  end
  api.nvim_buf_clear_namespace(header_buf, status_ns, 0, -1)
  api.nvim_buf_set_extmark(header_buf, status_ns, 0, #prefix, {
    end_col = #line - (cancel_text and #cancel_text or 0), hl_group = "PairStatus",
  })
  if cancel_column then
    api.nvim_buf_set_extmark(header_buf, status_ns, 0, #line - #cancel_text, {
      end_col = #line, hl_group = "PairStatusCancel",
    })
  end
end

function M.status(value)
  if vim.deep_equal(status, value) then return end
  status = vim.deepcopy(value)
  render_header()
end

function M.on_cancel(callback)
  on_cancel = callback
end

local function source_window(win)
  if not valid_window(win) or api.nvim_win_get_config(win).relative ~= "" then return false end
  if api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage() then return false end
  return vim.bo[api.nvim_win_get_buf(win)].buftype == ""
end

local function source_windows()
  local result = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if source_window(win) then result[#result + 1] = win end
  end
  return result
end

local function remember_source(win)
  if not source_window(win) then return end
  for index = #source_mru, 1, -1 do
    if source_mru[index] == win or not valid_window(source_mru[index]) then
      table.remove(source_mru, index)
    end
  end
  table.insert(source_mru, 1, win)
end

local function recent_source_window()
  local current = api.nvim_get_current_win()
  if source_window(current) then
    remember_source(current)
    return current
  end
  for _, win in ipairs(source_mru) do
    if source_window(win) then return win end
  end
  local fallback = source_windows()[1]
  if fallback then remember_source(fallback) end
  return fallback
end

function M.source_buffer()
  local win = recent_source_window()
  if win then return api.nvim_win_get_buf(win), win end
end

local function show_context(source, target, mode)
  local origin = api.nvim_get_current_win()
  local was_insert = api.nvim_get_mode().mode:sub(1, 1) == "i"
  local lines
  if not source then
    lines = { "No source buffer is attached to this message." }
  else
    local snapshot, err = context.capture(source, target)
    if not snapshot then vim.notify("Pair: " .. err, vim.log.levels.WARN); return end
    local attachment = mode == "none" and context.detached(snapshot) or snapshot
    local label = attachment.path or attachment.label
    lines = {
      "Pair context preview · captured again when sent",
      label,
      string.format("%s · %d lines · %d bytes", snapshot.modified and "unsaved" or "saved",
        #snapshot.lines, context.byte_size(snapshot)),
      mode == "none" and "Full buffer detached for this message." or "Full live buffer attached.",
    }
    if attachment.scope then
      lines[#lines + 1] = string.format("Scope: %s at %d:%d to %d:%d (zero-based bytes, end exclusive)",
        attachment.scope.kind, attachment.scope.start_row, attachment.scope.start_col,
        attachment.scope.end_row, attachment.scope.end_col)
    end
    lines[#lines + 1] = ""
    if mode == "none" then
      if attachment.scope then
        lines[#lines + 1] = "Selected text still sent:"
        vim.list_extend(lines, vim.split(attachment.scope.text, "\n", { plain = true }))
      end
    else
      for row, line in ipairs(snapshot.lines) do
        lines[#lines + 1] = string.format("%d  %s", row, line)
      end
    end
  end
  if was_insert then vim.cmd("stopinsert") end
  local preview = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("buftype", "nofile", { buf = preview })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = preview })
  api.nvim_buf_set_lines(preview, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = preview })
  local width = math.max(24, math.min(vim.o.columns - 6, 88))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.7)))
  local win = api.nvim_open_win(preview, true, {
    relative = "editor", row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, border = "rounded", title = " Pair context · q to close ",
    style = "minimal",
  })
  api.nvim_set_option_value("wrap", false, { win = win })
  api.nvim_set_option_value("winhighlight", "Normal:PairPrompt,NormalFloat:PairPrompt,FloatBorder:PairPromptBorder,FloatTitle:PairPromptTitle", { win = win })
  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    if valid_window(origin) then api.nvim_set_current_win(origin) end
    if was_insert and valid_window(origin) then vim.cmd("startinsert") end
  end
  vim.keymap.set("n", "q", close, { buffer = preview, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = preview, silent = true })
end

local function hide_completion()
  local blink = package.loaded["blink.cmp"]
  if blink and type(blink.hide) == "function" then pcall(blink.hide) end
  local cmp = package.loaded["cmp"]
  if cmp and type(cmp.close) == "function" then pcall(cmp.close) end
end

local function disable_completion(buf)
  vim.b[buf].completion = false -- blink.cmp's per-buffer switch
  api.nvim_set_option_value("completefunc", "", { buf = buf })
  api.nvim_set_option_value("omnifunc", "", { buf = buf })
  api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    callback = function()
      local cmp = package.loaded["cmp"]
      if cmp then pcall(function() cmp.setup.buffer({ enabled = false }) end) end
    end,
  })
end

local function pin_chat_bottom(align)
  if not valid_window(chat_win) or adjusting_scroll then return end
  adjusting_scroll = true
  local last = api.nvim_buf_line_count(chat_buf)
  local line = api.nvim_buf_get_lines(chat_buf, last - 1, last, false)[1] or ""
  local cursor = { last, math.max(0, #line - 1) }
  api.nvim_win_set_cursor(chat_win, cursor)
  local row = vim.fn.screenpos(chat_win, last, math.max(1, #line)).row
  local bottom = api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win)
  if align and row ~= bottom then
    api.nvim_win_call(chat_win, function() vim.cmd("normal! zb") end)
    -- `zb` can move the cursor backwards on a wrapped line taller than the pane.
    api.nvim_win_set_cursor(chat_win, cursor)
  end
  adjusting_scroll = false
end

local function chat_content_height()
  if not valid_window(chat_win) then return 0 end
  local ok, height = pcall(api.nvim_win_text_height, chat_win, {
    start_row = 0,
    end_row = api.nvim_buf_line_count(chat_buf),
  })
  return ok and height.all or api.nvim_buf_line_count(chat_buf)
end

local function clamp_chat_scroll()
  if not valid_window(chat_win) then return end
  if chat_content_height() <= api.nvim_win_get_height(chat_win) then
    api.nvim_win_call(chat_win, function()
      vim.fn.winrestview({ topline = 1, topfill = 0, leftcol = 0, skipcol = 0 })
    end)
    return
  end
  local last = api.nvim_buf_line_count(chat_buf)
  local line = api.nvim_buf_get_lines(chat_buf, last - 1, last, false)[1] or ""
  local row = vim.fn.screenpos(chat_win, last, math.max(1, #line)).row
  local bottom = api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win)
  if row > 0 and row < bottom then pin_chat_bottom(true) end
end

local function update_chat_lines(lines)
  local old = api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local old_text = table.concat(old, "\n")
  local new_text = table.concat(lines, "\n")
  if old_text == new_text then return end
  api.nvim_set_option_value("modifiable", true, { buf = chat_buf })
  if vim.startswith(new_text, old_text) then
    api.nvim_buf_set_text(chat_buf, #old - 1, #old[#old], #old - 1, #old[#old],
      vim.split(new_text:sub(#old_text + 1), "\n", { plain = true, trimempty = false }))
  else
    local first = 1
    while first <= math.min(#old, #lines) and old[first] == lines[first] do
      first = first + 1
    end
    api.nvim_buf_set_lines(chat_buf, first - 1, -1, false, vim.list_slice(lines, first))
  end
  api.nvim_set_option_value("modifiable", false, { buf = chat_buf })
end

local function render()
  if not chat_buf or not api.nvim_buf_is_valid(chat_buf) then
    return
  end
  local old_cursor, old_view
  if valid_window(chat_win) then
    old_cursor = api.nvim_win_get_cursor(chat_win)
    if not follow_bottom then
      old_view = api.nvim_win_call(chat_win, vim.fn.winsaveview)
    end
  end
  local lines = {}
  local marks = {}
  tool_rows = {}
  if #entries == 0 then
    lines[1] = "Ask about this project, or select code in the editor."
    marks[1] = { row = 0, group = "PairNotice" }
  end
  for entry_index, entry in ipairs(entries) do
    if entry.role == "Tool" and entry.status then
      local symbol = entry.status == "running" and "◌" or entry.status == "failed" and "✕" or "✓"
      local arrow = entry.expanded and "▾" or "▸"
      local title = (entry.text or "Inspection"):gsub("[\r\n]+", " ")
      local width = valid_window(chat_win) and api.nvim_win_get_width(chat_win) or 60
      local row = #lines + 1
      lines[row] = clip("↳ " .. arrow .. " " .. symbol .. " " .. title, math.max(8, width - 2))
      tool_rows[row] = entry_index
      marks[#marks + 1] = { row = row - 1, group = entry.status == "failed" and "PairToolFailure"
        or entry.status == "completed" and "PairToolSuccess" or "PairTool" }
      if entry.expanded then
        local detail = entry.detail ~= "" and entry.detail or "No output reported."
        for _, part in ipairs(vim.split(detail, "\n", { plain = true, trimempty = false })) do
          lines[#lines + 1] = "    " .. part
          tool_rows[#lines] = entry_index
          marks[#marks + 1] = { row = #lines - 1, group = "PairTool" }
        end
      end
      if entry_index < #entries and entries[entry_index + 1].role ~= "Tool" then
        lines[#lines + 1] = ""
      end
    else
      local prefix = entry.role == "You" and "› "
        or entry.role == "Pair" and "· "
        or entry.role == "Tool" and "↳ "
        or ""
      local in_code = false
      local parts = vim.split(entry.text, "\n", { plain = true, trimempty = false })
      while #parts > 1 and parts[#parts] == "" do table.remove(parts) end
      for index, line in ipairs(parts) do
        local rendered = (index == 1 and prefix or "  ") .. line
        local mark = { row = #lines, role = entry.role, content = line }
        if entry.role == "Agent" then
          if line:match("^%s*```") then
            mark.group = "PairCodeFence"
            in_code = not in_code
          elseif in_code then
            mark.group = "PairCode"
          elseif line:match("^%s*#+%s") then
            mark.group = "PairHeading"
          else
            mark.group = "PairAgent"
          end
        elseif entry.role == "You" then
          mark.group = "PairUserMessage"
        elseif entry.role == "Tool" then
          mark.group = "PairTool"
        else
          mark.group = "PairNotice"
        end
        lines[#lines + 1] = rendered
        marks[#marks + 1] = mark
      end
      if entry_index < #entries then lines[#lines + 1] = "" end
    end
  end
  update_chat_lines(lines)
  api.nvim_buf_clear_namespace(chat_buf, chat_ns, 0, -1)
  for _, mark in ipairs(marks) do
    local rendered = lines[mark.row + 1]
    local opts = { end_col = #rendered, hl_group = mark.group }
    if mark.role == "You" then opts.line_hl_group = "PairUserMessage" end
    api.nvim_buf_set_extmark(chat_buf, chat_ns, mark.row, 0, opts)
    if mark.role == "Agent" and mark.group == "PairAgent" then
      for column, token in rendered:gmatch("()(`[^`]+`)") do
        api.nvim_buf_set_extmark(chat_buf, chat_ns, mark.row, column - 1, {
          end_col = column - 1 + #token,
          hl_group = "PairCode",
        })
      end
    end
  end
  if valid_window(chat_win) then
    if follow_bottom then
      pin_chat_bottom(true)
    else
      api.nvim_win_set_cursor(chat_win, { math.min(old_cursor and old_cursor[1] or 1, #lines), 0 })
      if old_view then
        api.nvim_win_call(chat_win, function() vim.fn.winrestview(old_view) end)
      end
    end
  end
end

local function ensure_header()
  if header_buf and api.nvim_buf_is_valid(header_buf) then return end
  header_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(header_buf, "pair://header")
  api.nvim_set_option_value("buftype", "nofile", { buf = header_buf })
  api.nvim_set_option_value("bufhidden", "hide", { buf = header_buf })
  api.nvim_buf_set_lines(header_buf, 0, -1, false, { " Pair Chat" })
  api.nvim_set_option_value("modifiable", false, { buf = header_buf })
  vim.keymap.set("n", "q", function() M.close() end, { buffer = header_buf, silent = true })
  vim.keymap.set("n", "gN", "<Cmd>PairNew<CR>", { buffer = header_buf, silent = true, desc = "Start a new Pair chat" })
  vim.keymap.set("n", "gS", "<Cmd>PairSessions<CR>", { buffer = header_buf, silent = true, desc = "Choose a Pair session" })
  vim.keymap.set("n", "gB", "<Cmd>PairBackends<CR>", { buffer = header_buf, silent = true, desc = "Choose a Pair backend" })
  vim.keymap.set("n", "gM", "<Cmd>PairModel<CR>", { buffer = header_buf, silent = true, desc = "Choose a Pair model" })
  vim.keymap.set("n", "gP", "<Cmd>PairActions<CR>", { buffer = header_buf, silent = true, desc = "Choose a Pair action" })
  vim.keymap.set("n", "<CR>", function()
    if status.cancellable and on_cancel then on_cancel() end
  end, { buffer = header_buf, silent = true, desc = "Cancel Pair work" })
  vim.keymap.set("n", "x", function()
    if status.cancellable and on_cancel then on_cancel() end
  end, { buffer = header_buf, silent = true, desc = "Cancel Pair work" })
  vim.keymap.set("n", "<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid == header_win and cancel_column and mouse.column >= cancel_column
      and mouse.column < cancel_column + vim.fn.strdisplaywidth(cancel_text) and on_cancel then
      on_cancel()
    end
  end, { buffer = header_buf, silent = true, desc = "Click Pair cancel control" })
  render_header()
end

local function ensure_chat()
  if chat_buf and api.nvim_buf_is_valid(chat_buf) then
    return
  end
  chat_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(chat_buf, "pair://chat")
  api.nvim_set_option_value("buftype", "nofile", { buf = chat_buf })
  api.nvim_set_option_value("bufhidden", "hide", { buf = chat_buf })
  api.nvim_set_option_value("filetype", "pairchat", { buf = chat_buf })
  vim.keymap.set("n", "q", function() M.close() end, { buffer = chat_buf, silent = true, desc = "Close Pair chat" })
  vim.keymap.set("n", "gN", "<Cmd>PairNew<CR>", { buffer = chat_buf, silent = true, desc = "Start a new Pair chat" })
  vim.keymap.set("n", "gS", "<Cmd>PairSessions<CR>", { buffer = chat_buf, silent = true, desc = "Choose a Pair session" })
  vim.keymap.set("n", "gB", "<Cmd>PairBackends<CR>", { buffer = chat_buf, silent = true, desc = "Choose a Pair backend" })
  vim.keymap.set("n", "gM", "<Cmd>PairModel<CR>", { buffer = chat_buf, silent = true, desc = "Choose a Pair model" })
  vim.keymap.set("n", "gP", "<Cmd>PairActions<CR>", { buffer = chat_buf, silent = true, desc = "Choose a Pair action" })
  vim.keymap.set("n", "<CR>", function()
    if not M.toggle_tool() then M.chat() end
  end, { buffer = chat_buf, silent = true, desc = "Expand tool activity or write a Pair message" })
  vim.keymap.set("n", "za", function() M.toggle_tool() end,
    { buffer = chat_buf, silent = true, desc = "Toggle Pair tool details" })
  for _, spec in ipairs({
    { "<C-Y>", "up" }, { "<C-U>", "up" }, { "<C-B>", "up" },
    { "<C-E>", "down" }, { "<C-D>", "down" }, { "<C-F>", "down" },
  }) do
    vim.keymap.set("n", spec[1], function()
      local count = vim.v.count > 0 and tostring(vim.v.count) or ""
      vim.cmd("normal! " .. count .. api.nvim_replace_termcodes(spec[1], true, false, true))
      if spec[2] == "up" then
        follow_bottom = false
      else
        local last = api.nvim_buf_line_count(chat_buf)
        local line = api.nvim_buf_get_lines(chat_buf, last - 1, last, false)[1] or ""
        local row = vim.fn.screenpos(chat_win, last, math.max(1, #line)).row
        local bottom = api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win)
        follow_bottom = row > 0 and row <= bottom
      end
      clamp_chat_scroll()
    end, { buffer = chat_buf, silent = true })
  end
  render()
end

local function ensure_input()
  if input_buf and api.nvim_buf_is_valid(input_buf) then return end
  input_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(input_buf, "pair://input")
  api.nvim_set_option_value("buftype", "nofile", { buf = input_buf })
  api.nvim_set_option_value("bufhidden", "hide", { buf = input_buf })
  disable_completion(input_buf)
  api.nvim_set_option_value("filetype", "pairinput", { buf = input_buf })
  api.nvim_buf_set_lines(input_buf, 0, -1, false, { "", "", "" })
  vim.keymap.set("n", "<CR>", function() M.submit() end, { buffer = input_buf, silent = true, desc = "Send Pair message" })
  vim.keymap.set("n", "q", function() M.close() end, { buffer = input_buf, silent = true, desc = "Close Pair chat" })
  vim.keymap.set("n", "gN", "<Cmd>PairNew<CR>", { buffer = input_buf, silent = true, desc = "Start a new Pair chat" })
  vim.keymap.set("n", "gS", "<Cmd>PairSessions<CR>", { buffer = input_buf, silent = true, desc = "Choose a Pair session" })
  vim.keymap.set("n", "gB", "<Cmd>PairBackends<CR>", { buffer = input_buf, silent = true, desc = "Choose a Pair backend" })
  vim.keymap.set("n", "gM", "<Cmd>PairModel<CR>", { buffer = input_buf, silent = true, desc = "Choose a Pair model" })
  vim.keymap.set("n", "gP", "<Cmd>PairActions<CR>", { buffer = input_buf, silent = true, desc = "Choose a Pair action" })
  vim.keymap.set("n", "gC", function()
    show_context(M.source_buffer(), nil, input_context_mode)
  end, { buffer = input_buf, silent = true, desc = "Inspect Pair context" })
  vim.keymap.set("n", "gA", function()
    input_context_mode = input_context_mode == "full" and "none" or "full"
  end, { buffer = input_buf, silent = true, desc = "Attach or detach Pair source buffer" })
end

function M.on_send(callback)
  on_send = callback
end

function M.has_draft()
  if not input_buf or not api.nvim_buf_is_valid(input_buf) then return false end
  return vim.trim(table.concat(api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n")) ~= ""
end

function M.submit()
  if not input_buf or not api.nvim_buf_is_valid(input_buf) then return false end
  if input_submission_pending then return false end
  local message = vim.trim(table.concat(api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
  if message == "" then return false end
  if not on_send then return false end
  local changedtick = api.nvim_buf_get_changedtick(input_buf)
  local finished = false
  local function complete(accepted)
    if finished then return end
    finished = true
    input_submission_pending = false
    if not accepted then return end
    if api.nvim_buf_is_valid(input_buf) and api.nvim_buf_get_changedtick(input_buf) == changedtick then
      api.nvim_buf_set_lines(input_buf, 0, -1, false, { "", "", "" })
      if valid_window(input_win) then api.nvim_win_set_cursor(input_win, { 1, 0 }) end
    end
    input_context_mode = "full"
  end
  local result = on_send(message, input_context_mode, complete)
  if result == "pending" and not finished then input_submission_pending = true end
  if result ~= "pending" and not finished then complete(result ~= false) end
  return true
end

function M.close()
  if api.nvim_get_mode().mode:sub(1, 1) == "i" then vim.cmd("stopinsert") end
  if valid_window(input_win) then api.nvim_win_close(input_win, true) end
  if valid_window(chat_win) then api.nvim_win_close(chat_win, true) end
  if valid_window(header_win) then api.nvim_win_close(header_win, true) end
  input_win = nil
  chat_win = nil
  header_win = nil
  follow_bottom = true
end

function M.is_open()
  return valid_window(header_win) and valid_window(chat_win) and valid_window(input_win)
end

function M.chat()
  ensure_chat()
  ensure_input()
  ensure_header()
  if not M.is_open() then
    remember_source(api.nvim_get_current_win())
    M.close()
    vim.cmd("botright vsplit")
    chat_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(chat_win, chat_buf)
    api.nvim_win_set_width(chat_win, math.min(60, math.floor(vim.o.columns * 0.42)))
    api.nvim_set_option_value("wrap", true, { win = chat_win })
    api.nvim_set_option_value("cursorline", false, { win = chat_win })
    api.nvim_set_option_value("breakindent", false, { win = chat_win })
    api.nvim_set_option_value("showbreak", "", { win = chat_win })
    api.nvim_set_option_value("scrolloff", 0, { win = chat_win })
    api.nvim_set_option_value("smoothscroll", true, { win = chat_win })
    api.nvim_set_option_value("number", false, { win = chat_win })
    api.nvim_set_option_value("relativenumber", false, { win = chat_win })
    api.nvim_set_option_value("signcolumn", "no", { win = chat_win })
    api.nvim_set_option_value("foldcolumn", "0", { win = chat_win })
    api.nvim_set_option_value("statuscolumn", "", { win = chat_win })
    api.nvim_set_option_value("winhighlight", "NormalNC:Normal,WinBar:PairChatHeader,WinBarNC:PairChatHeader", { win = chat_win })
    api.nvim_set_option_value("winbar", "", { win = chat_win })
    vim.cmd("aboveleft split")
    header_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(header_win, header_buf)
    api.nvim_win_set_height(header_win, 1)
    api.nvim_set_option_value("winfixheight", true, { win = header_win })
    api.nvim_set_option_value("number", false, { win = header_win })
    api.nvim_set_option_value("relativenumber", false, { win = header_win })
    api.nvim_set_option_value("signcolumn", "no", { win = header_win })
    api.nvim_set_option_value("foldcolumn", "0", { win = header_win })
    api.nvim_set_option_value("fillchars", "eob: ", { win = header_win })
    api.nvim_set_option_value("winhighlight", "Normal:PairChatHeader,NormalNC:PairChatHeader,EndOfBuffer:PairChatHeader", { win = header_win })
    render_header()
    api.nvim_set_current_win(chat_win)
    vim.cmd("belowright split")
    input_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(input_win, input_buf)
    api.nvim_win_set_height(input_win, 3)
    api.nvim_set_option_value("winfixheight", true, { win = input_win })
    api.nvim_set_option_value("wrap", true, { win = input_win })
    api.nvim_set_option_value("cursorline", false, { win = input_win })
    api.nvim_set_option_value("colorcolumn", "", { win = input_win })
    api.nvim_set_option_value("number", true, { win = input_win })
    api.nvim_set_option_value("numberwidth", 2, { win = input_win })
    api.nvim_set_option_value("relativenumber", false, { win = input_win })
    api.nvim_set_option_value("signcolumn", "no", { win = input_win })
    api.nvim_set_option_value("foldcolumn", "0", { win = input_win })
    api.nvim_set_option_value("statuscolumn", "%#PairInputPrompt#%{v:lnum == 1 && v:virtnum == 0 ? '❯ ' : '  '}", { win = input_win })
    api.nvim_set_option_value("fillchars", "eob: ", { win = input_win })
    api.nvim_set_option_value("winhighlight", "Normal:PairInput,NormalNC:PairInput,EndOfBuffer:PairInput,CursorLine:PairInput,LineNr:PairInputPrompt,SignColumn:PairInput", { win = input_win })
    api.nvim_set_option_value("winbar", "", { win = input_win })
    api.nvim_win_set_height(input_win, 3)
    render()
  end
  api.nvim_set_current_win(input_win)
  local target_win = input_win
  vim.schedule(function()
    if valid_window(target_win) and api.nvim_get_current_win() == target_win
      and api.nvim_get_mode().mode == "n" then
      vim.cmd("startinsert")
    end
  end)
end

api.nvim_create_autocmd("WinScrolled", {
  callback = function(event)
    if not valid_window(chat_win) or adjusting_scroll then return end
    local movement = vim.v.event[tostring(chat_win)] or vim.v.event[chat_win]
    if not movement then return end
    local last = api.nvim_buf_line_count(chat_buf)
    local line = api.nvim_buf_get_lines(chat_buf, last - 1, last, false)[1] or ""
    local row = vim.fn.screenpos(chat_win, last, math.max(1, #line)).row
    local bottom = api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win)
    if row > 0 and row <= bottom then
      follow_bottom = true
      adjusting_scroll = true
      clamp_chat_scroll()
      adjusting_scroll = false
    end
  end,
})

api.nvim_create_autocmd("CursorMoved", {
  callback = function()
    if valid_window(chat_win) and api.nvim_get_current_win() == chat_win
      and api.nvim_win_get_cursor(chat_win)[1] < api.nvim_buf_line_count(chat_buf) then
      follow_bottom = false
    end
  end,
})

local wheel_up = api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true)
vim.on_key(function(key)
  if (key == "j" or key == "k") and valid_window(chat_win)
    and api.nvim_get_current_win() == chat_win then
    follow_bottom = false
  end
  if key == wheel_up and valid_window(chat_win) and vim.fn.getmousepos().winid == chat_win then
    follow_bottom = false
  end
end, wheel_ns)

api.nvim_create_autocmd("WinResized", {
  callback = function()
    if follow_bottom then vim.schedule(function() pin_chat_bottom(true) end) end
    render_header()
  end,
})

api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  callback = function()
    remember_source(api.nvim_get_current_win())
  end,
})

api.nvim_create_autocmd("QuitPre", {
  callback = function()
    if forwarding_quit or not M.is_open() then return end
    local win = api.nvim_get_current_win()
    if win == header_win or win == chat_win or win == input_win then
      local target = recent_source_window()
      if not target then return end
      local last_source = #source_windows() == 1
      forwarding_quit = true
      vim.schedule(function()
        M.close()
        if valid_window(target) then
          api.nvim_set_current_win(target)
          local ok, err = pcall(vim.cmd, "quit")
          if not ok then vim.notify("Pair: " .. tostring(err), vim.log.levels.WARN) end
        end
        if #source_windows() > 0 then
          local focus = source_windows()[1]
          if last_source and valid_window(focus) and not vim.bo[api.nvim_win_get_buf(focus)].modified then
            pcall(vim.cmd, "qa")
          else
            M.chat()
            vim.cmd("stopinsert")
            if valid_window(focus) then api.nvim_set_current_win(focus) end
          end
        end
        forwarding_quit = false
      end)
    elseif source_window(win) and #source_windows() == 1 then
      forwarding_quit = true
      M.close()
      forwarding_quit = false
      vim.schedule(function()
        if valid_window(win) and source_window(win) and not M.is_open() then
          if not vim.bo[api.nvim_win_get_buf(win)].modified then
            pcall(vim.cmd, "qa")
          else
            M.chat()
            vim.cmd("stopinsert")
            api.nvim_set_current_win(win)
          end
        end
      end)
    end
  end,
})

api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(event)
    if not M.is_open() or event.buf == header_buf or event.buf == chat_buf or event.buf == input_buf then return end
    if vim.bo[event.buf].buftype ~= "" then return end
    local listed = 0
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if buf ~= event.buf and api.nvim_buf_is_valid(buf)
        and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
        local contents = api.nvim_buf_get_lines(buf, 0, 2, false)
        local empty = api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
          and #contents == 1 and contents[1] == ""
        if not empty then listed = listed + 1 end
      end
    end
    if listed == 0 then vim.schedule(function() if M.is_open() then M.close() end end) end
  end,
})

function M.add(role, message)
  entries[#entries + 1] = { role = role, text = message }
  render()
  persist()
  return #entries
end

function M.tool(index, update)
  local entry = index and entries[index] or nil
  if not entry or entry.role ~= "Tool" then
    entry = { role = "Tool", text = update.title or "Inspection", status = "running",
      detail = "", expanded = false }
    entries[#entries + 1] = entry
    index = #entries
  end
  if type(update.title) == "string" then entry.text = update.title end
  if type(update.status) == "string" then entry.status = update.status end
  if type(update.detail) == "string" and update.detail ~= "" then
    entry.detail = update.detail:sub(1, 4096)
  end
  render()
  persist()
  return index
end

function M.finish_tool(index, failed)
  local entry = entries[index]
  if not entry or entry.role ~= "Tool" or entry.status ~= "running" then return end
  entry.status = failed and "failed" or "completed"
  render()
  persist()
end

function M.toggle_tool()
  if not valid_window(chat_win) or api.nvim_get_current_win() ~= chat_win then return false end
  local row = api.nvim_win_get_cursor(chat_win)[1]
  local entry = entries[tool_rows[row]]
  if not entry or entry.role ~= "Tool" then return false end
  entry.expanded = not entry.expanded
  follow_bottom = false
  render()
  persist()
  return true
end

function M.follow()
  follow_bottom = true
  pin_chat_bottom(false)
end

function M.append(index, chunk)
  if entries[index] then
    entries[index].text = entries[index].text .. chunk
    render()
    persist()
  end
end

function M.replace(index, message)
  if entries[index] then
    entries[index].text = message
    render()
    persist()
  end
end

function M.history(path)
  if history_file == path then return end
  history_file = path
  entries = {}
  local file = io.open(path, "r")
  if file then
    local source = file:read("*a")
    file:close()
    local ok, stored = pcall(vim.json.decode, source)
    if ok and type(stored) == "table" then
      for _, entry in ipairs(stored) do
        if type(entry) == "table" and type(entry.role) == "string" and type(entry.text) == "string" then
          entries[#entries + 1] = entry
        end
      end
    end
  end
  render()
end

function M.clear()
  entries = {}
  input_context_mode = "full"
  input_submission_pending = false
  if input_buf and api.nvim_buf_is_valid(input_buf) then
    api.nvim_buf_set_lines(input_buf, 0, -1, false, { "", "", "" })
    if valid_window(input_win) then api.nvim_win_set_cursor(input_win, { 1, 0 }) end
  end
  follow_bottom = true
  render()
  persist()
end

function M.prompt(title, callback, opts)
  opts = opts or {}
  local source_win = api.nvim_get_current_win()
  hide_completion()
  local width = math.max(24, math.min(72, vim.o.columns - 6))
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  disable_completion(buf)
  api.nvim_set_option_value("filetype", "pairprompt", { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 3,
    border = "rounded",
    title = " Pair: " .. title .. " (Enter to send) ",
    style = "minimal",
  })
  api.nvim_set_option_value("wrap", true, { win = win })
  api.nvim_set_option_value("cursorline", false, { win = win })
  api.nvim_set_option_value("winblend", 0, { win = win })
  api.nvim_set_option_value("winhighlight", "Normal:PairPrompt,NormalFloat:PairPrompt,FloatBorder:PairPromptBorder,FloatTitle:PairPromptTitle,CursorLine:PairPrompt", { win = win })
  local state = { buf = buf, win = win, source = opts.source_buf or api.nvim_win_get_buf(source_win), target = opts.target, mode = "full" }
  local done = false
  local function close(after)
    hide_completion()
    if api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
    vim.schedule(function()
      if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
      if api.nvim_win_is_valid(source_win) then api.nvim_set_current_win(source_win) end
      if api.nvim_get_mode().mode:sub(1, 1) == "i" then vim.cmd("stopinsert") end
      hide_completion()
      if after then after() end
    end)
  end
  local function submit()
    if done then return end
    if state.submitting then return end
    local message = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if message == "" then
      return
    end
    local finished = false
    local function complete(accepted)
      if finished then return end
      finished = true
      state.submitting = false
      if accepted then
        done = true
        close()
      end
    end
    local result = callback(message, state.mode, complete)
    if result == "pending" and not finished then state.submitting = true end
    if result ~= "pending" and not finished then complete(result ~= false) end
  end
  local function cancel()
    if done then return end
    done = true
    close()
  end
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buf, silent = true })
  vim.keymap.set("i", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "gC", function()
    show_context(state.source, state.target, state.mode)
  end, { buffer = buf, silent = true, desc = "Inspect Pair context" })
  vim.keymap.set("n", "gA", function()
    state.mode = state.mode == "full" and "none" or "full"
  end, { buffer = buf, silent = true, desc = "Attach or detach Pair source buffer" })
  vim.cmd("startinsert")
end

return M
