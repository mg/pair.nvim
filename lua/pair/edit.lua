local M = {}
local api = vim.api
local uv = vim.uv or vim.loop
local ns = api.nvim_create_namespace("pair.nvim.proposal")
local control_ns = api.nvim_create_namespace("pair.nvim.control")
local anchor_ns = api.nvim_create_namespace("pair.nvim.control_anchor")
local answer_ns = api.nvim_create_namespace("pair.nvim.answer")
local progress_ns = api.nvim_create_namespace("pair.nvim.progress")
local mouse_ns = api.nvim_create_namespace("pair.nvim.mouse")
local answer_mouse_ns = api.nvim_create_namespace("pair.nvim.answer_mouse")
local pending
local answer
local progress
local prior_mousemove
local control_win
local control_buf
local source_mappings
local diff_view
local diff_serial = 0
local accept_label = "  ✓ Accept  "
local reject_label = "  ✕ Reject  "
local diff_label = "  ◫ Diff (d)  "
local compact_labels = { " ✓Accept", " ✕Reject", " d Diff" }
local tiny_labels = { " ✓ ", " ✕ ", " d " }

local function enable_mousemove()
  if prior_mousemove == nil then
    prior_mousemove = vim.o.mousemoveevent
    vim.o.mousemoveevent = true
  end
end

local function restore_mousemove()
  if pending or answer or prior_mousemove == nil then return end
  vim.o.mousemoveevent = prior_mousemove
  prior_mousemove = nil
end

local function tint(color, toward, fraction)
  local function channel(shift)
    local value = math.floor(color / 2 ^ shift) % 256
    local goal = math.floor(toward / 2 ^ shift) % 256
    return math.floor(value + (goal - value) * fraction + 0.5)
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

local function define_highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local base = normal.bg or (vim.o.background == "dark" and 0x202020 or 0xf0f0f0)
  local foreground = normal.fg or (vim.o.background == "dark" and 0xeeeeee or 0x222222)
  local ok = api.nvim_get_hl(0, { name = "DiagnosticOk", link = false })
  local error_hl = api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  local green = ok.fg or 0x65b88a
  local red = error_hl.fg or 0xd97878
  local card = tint(base, vim.o.background == "dark" and 0xffffff or 0x000000, 0.08)
  api.nvim_set_hl(0, "PairAnswer", { bg = card, fg = foreground })
  api.nvim_set_hl(0, "PairAnswerTitle", { bg = card, fg = green, bold = true })
  api.nvim_set_hl(0, "PairAnswerClose", { bg = card, fg = red, bold = true })
  api.nvim_set_hl(0, "PairAnswerCloseSelected", { bg = tint(base, red, 0.3), fg = foreground, bold = true })
  api.nvim_set_hl(0, "PairAccept", { bg = card, fg = green, bold = true })
  api.nvim_set_hl(0, "PairReject", { bg = card, fg = red, bold = true })
  api.nvim_set_hl(0, "PairAcceptSelected", { bg = tint(base, green, 0.3), fg = foreground, bold = true })
  api.nvim_set_hl(0, "PairRejectSelected", { bg = tint(base, red, 0.3), fg = foreground, bold = true })
  api.nvim_set_hl(0, "PairDiff", { bg = card, fg = foreground, bold = true })
  api.nvim_set_hl(0, "PairDiffSelected", { bg = tint(base, foreground, 0.18), fg = foreground, bold = true })
  api.nvim_set_hl(0, "PairControl", { bg = card, fg = foreground })
  api.nvim_set_hl(0, "PairRationale", { bg = card, fg = tint(foreground, base, 0.18) })
end

define_highlights()
api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

local function split_lines(text)
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

local function text_at(target)
	if target.kind == "insert" then
		return ""
	end
	if target.linewise then
		return table.concat(api.nvim_buf_get_lines(target.buf, target.start_row, target.end_row + 1, false), "\n")
	end
	return table.concat(
		api.nvim_buf_get_text(target.buf, target.start_row, target.start_col, target.end_row, target.end_col, {}),
		"\n"
	)
end

local function source_window(buf)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == buf and api.nvim_win_get_config(win).relative == "" then return win end
  end
end

local function proposal_window(proposal)
  local win = proposal.source_win
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == proposal.target.buf then
    return win
  end
  return source_window(proposal.target.buf)
end

local function review_labels(proposal)
  local win = proposal_window(proposal)
  local width = win and api.nvim_win_get_width(win) or 80
  if win then
    local info = vim.fn.getwininfo(win)[1]
    width = width - (info and info.textoff or 0) - 1
  end
  local full = { accept_label, reject_label, diff_label }
  if width >= vim.fn.strdisplaywidth(table.concat(full)) then return full end
  if width >= vim.fn.strdisplaywidth(table.concat(compact_labels)) then return compact_labels end
  return tiny_labels
end

local function close_control()
  if control_win and api.nvim_win_is_valid(control_win) then api.nvim_win_close(control_win, true) end
  control_win = nil
  if control_buf and api.nvim_buf_is_valid(control_buf) then api.nvim_buf_delete(control_buf, { force = true }) end
  control_buf = nil
end

local function restore_source_mappings()
  if not source_mappings then return end
  local saved = source_mappings
  source_mappings = nil
  if not api.nvim_buf_is_valid(saved.buf) then return end
  for _, key in ipairs({ "j", "k" }) do
    pcall(vim.keymap.del, "n", key, { buffer = saved.buf })
    if saved.keys[key] then
      api.nvim_buf_call(saved.buf, function() pcall(vim.fn.mapset, "n", false, saved.keys[key]) end)
    end
  end
end

local function restore_review_focus(view)
  if pending ~= view.proposal then return end
  local win = view.origin_win
  if not win or not api.nvim_win_is_valid(win) then win = source_window(view.proposal.target.buf) end
  if not win or not api.nvim_win_is_valid(win) then return end
  api.nvim_set_current_win(win)
  if view.origin_view and win == view.origin_win then
    pcall(api.nvim_win_call, win, function() vim.fn.winrestview(view.origin_view) end)
  end
  if view.origin_cursor and win == view.origin_win then
    pcall(api.nvim_win_set_cursor, win, view.origin_cursor)
  end
end

function M.close_diff()
  local view = diff_view
  if not view then return false end
  diff_view = nil
  if view.tab and api.nvim_tabpage_is_valid(view.tab) then
    if #api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew")
      local source = view.proposal.target.buf
      if api.nvim_buf_is_valid(source) and api.nvim_buf_is_loaded(source) then
        api.nvim_win_set_buf(0, source)
      end
    end
    api.nvim_set_current_tabpage(view.tab)
    vim.cmd("tabclose")
  end
  restore_review_focus(view)
  return true
end

local function clean()
  if not pending then return end
  if diff_view then M.close_diff() end
  vim.on_key(nil, mouse_ns)
  close_control()
  restore_source_mappings()
  if api.nvim_buf_is_valid(pending.target.buf) and api.nvim_buf_is_loaded(pending.target.buf) then
    api.nvim_buf_clear_namespace(pending.target.buf, ns, 0, -1)
    api.nvim_buf_clear_namespace(pending.target.buf, control_ns, 0, -1)
    api.nvim_buf_clear_namespace(pending.target.buf, anchor_ns, 0, -1)
  end
  pending = nil
  restore_mousemove()
  vim.cmd("redraw")
end

local function wrap_line(line, width)
  if line == "" then return { "" } end
  local result, remaining = {}, line
  while vim.fn.strdisplaywidth(remaining) > width do
    local count = 1
    while count < vim.fn.strchars(remaining)
      and vim.fn.strdisplaywidth(vim.fn.strcharpart(remaining, 0, count + 1)) <= width do
      count = count + 1
    end
    local fitting = vim.fn.strcharpart(remaining, 0, count)
    local break_byte = fitting:match(".*()%s+")
    local break_chars = break_byte and vim.fn.strchars(fitting:sub(1, break_byte - 1)) or nil
    if break_chars and break_chars > 0 then
      result[#result + 1] = vim.fn.strcharpart(remaining, 0, break_chars)
      remaining = vim.fn.strcharpart(remaining, break_chars):gsub("^%s+", "")
    else
      result[#result + 1] = fitting
      remaining = vim.fn.strcharpart(remaining, count)
    end
  end
  result[#result + 1] = remaining
  return result
end

local function render_answer()
  if not answer or not api.nvim_buf_is_valid(answer.target.buf) then return false end
  local target = answer.target
  if api.nvim_buf_get_changedtick(target.buf) ~= target.changedtick then
    api.nvim_buf_clear_namespace(target.buf, answer_ns, 0, -1)
    answer = nil
    vim.on_key(nil, answer_mouse_ns)
    restore_mousemove()
    return false
  end
  local win = source_window(target.buf)
  local width = math.max(12, (win and api.nvim_win_get_width(win) or 80) - 8)
  answer.width = width
  local title = answer.complete and " Pair" or " Pair · " .. (progress and progress.frame or "thinking")
  local title_space = math.max(0, width - vim.fn.strdisplaywidth(title) - 3)
  local lines = { {
    { title, "PairAnswerTitle" },
    { string.rep(" ", title_space), "PairAnswer" },
    { " × ", answer.hover_close and "PairAnswerCloseSelected" or "PairAnswerClose" },
  } }
  for _, paragraph in ipairs(split_lines(answer.text)) do
    for _, line in ipairs(wrap_line(paragraph, width - 2)) do
      local body = "  " .. line
      local pad = math.max(0, width - vim.fn.strdisplaywidth(body))
      lines[#lines + 1] = { { body .. string.rep(" ", pad), "PairAnswer" } }
    end
  end
  api.nvim_buf_clear_namespace(target.buf, answer_ns, 0, -1)
  api.nvim_buf_set_extmark(target.buf, answer_ns, target.end_row, 0, { virt_lines = lines })
  return true
end

local function answer_close_hit(current, mouse)
  local win = mouse.winid
  if not win or not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= current.target.buf then return false end
  local row = current.target.end_row
  local source_line = api.nvim_buf_get_lines(current.target.buf, row, row + 1, false)[1] or ""
  local line_end = vim.fn.screenpos(win, row + 1, #source_line + 1)
  local line_start = vim.fn.screenpos(win, row + 1, 1)
  local relative_col = mouse.screencol - line_start.col + 1
  return line_end.row > 0 and mouse.screenrow == line_end.row + 1
    and relative_col >= current.width - 2 and relative_col <= current.width
end

local function observe_answer(current)
  enable_mousemove()
  local click_key = api.nvim_replace_termcodes("<LeftMouse>", true, false, true)
  local move_key = api.nvim_replace_termcodes("<MouseMove>", true, false, true)
  vim.on_key(function(key)
    if answer ~= current or (key ~= click_key and key ~= move_key) then return end
    vim.schedule(function()
      if answer ~= current then return end
      local hover = answer_close_hit(current, vim.fn.getmousepos())
      if key == click_key and hover then
        M.dismiss_answer()
      elseif key == move_key and current.hover_close ~= hover then
        current.hover_close = hover
        render_answer()
      end
    end)
  end, answer_mouse_ns)
end

function M.selection()
	local buf = api.nvim_get_current_buf()
	if vim.fn.visualmode() == "\22" then
		return nil, "Blockwise selections are not supported yet"
	end
	local start = vim.fn.getpos("'<")
	local finish = vim.fn.getpos("'>")
	if start[2] == 0 or finish[2] == 0 then
		return nil, "Select code first"
	end
	local start_row, start_col = start[2] - 1, start[3] - 1
	local end_row, end_col = finish[2] - 1, finish[3] - 1
	if end_row < start_row or (end_row == start_row and end_col < start_col) then
		start_row, end_row = end_row, start_row
		start_col, end_col = end_col, start_col
	end
	local linewise = vim.fn.visualmode() == "V"
	if linewise then
		start_col = 0
		end_col = #api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1]
	elseif vim.o.selection ~= "exclusive" or (start_row == end_row and start_col == end_col) then
		local line = api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
		local character = vim.fn.strcharpart(line:sub(end_col + 1), 0, 1)
		end_col = end_col + #character
	end
	local target = {
		kind = "replace",
		buf = buf,
		path = api.nvim_buf_get_name(buf),
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
		linewise = linewise,
		changedtick = api.nvim_buf_get_changedtick(buf),
	}
	target.original = text_at(target)
	return target
end

function M.line_range(first, last)
	local buf = api.nvim_get_current_buf()
	local count = api.nvim_buf_line_count(buf)
	if first < 1 or last < first or last > count then
		return nil, "Select a valid line range first"
	end
	local target = {
		kind = "replace", buf = buf, path = api.nvim_buf_get_name(buf),
		start_row = first - 1, start_col = 0,
		end_row = last - 1,
		end_col = #(api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""),
		linewise = true, changedtick = api.nvim_buf_get_changedtick(buf),
	}
	target.original = text_at(target)
	return target
end

function M.insertion()
	local buf = api.nvim_get_current_buf()
	local cursor = api.nvim_win_get_cursor(0)
	local row, col = cursor[1] - 1, cursor[2]
	return {
		kind = "insert",
		buf = buf,
		path = api.nvim_buf_get_name(buf),
		start_row = row,
		start_col = col,
		end_row = row,
		end_col = col,
		changedtick = api.nvim_buf_get_changedtick(buf),
	}
end

local function control_row(proposal)
  local position = api.nvim_buf_get_extmark_by_id(proposal.target.buf, anchor_ns, proposal.anchor_id, {})
  return position[1] or proposal.target.start_row
end

local function render_control(proposal)
  local buf = proposal.target.buf
  if not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_clear_namespace(buf, control_ns, 0, -1)
  proposal.labels = review_labels(proposal)
  local labels = proposal.labels
  local lines = {}
  if proposal.rationale and proposal.rationale ~= "" then
    local win = proposal_window(proposal)
    local width = math.max(16, (win and api.nvim_win_get_width(win) or 80) - 8)
    for _, paragraph in ipairs(split_lines(proposal.rationale)) do
      for _, line in ipairs(wrap_line(paragraph, width - 2)) do
        lines[#lines + 1] = { { "  " .. line, "PairRationale" } }
      end
    end
  end
  lines[#lines + 1] = {
    { labels[1], proposal.hover == 1 and "PairAcceptSelected" or "PairAccept" },
    { labels[2], proposal.hover == 2 and "PairRejectSelected" or "PairReject" },
    { labels[3], proposal.hover == 3 and "PairDiffSelected" or "PairDiff" },
  }
  api.nvim_buf_set_extmark(buf, control_ns, control_row(proposal), 0, {
    virt_lines_above = true,
    virt_lines = lines,
    right_gravity = false,
  })
end

local function control_hit(proposal, mouse)
  local win = mouse.winid
  local labels = proposal.labels or review_labels(proposal)
  local accept_width = vim.fn.strdisplaywidth(labels[1])
  local reject_width = vim.fn.strdisplaywidth(labels[2])
  local diff_width = vim.fn.strdisplaywidth(labels[3])
  if win == control_win then
    return mouse.wincol <= accept_width and 1
      or mouse.wincol <= accept_width + reject_width and 2
      or mouse.wincol <= accept_width + reject_width + diff_width and 3 or nil
  end
  if not win or not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= proposal.target.buf then return end
  local source = vim.fn.screenpos(win, control_row(proposal) + 1, 1)
  if source.row == 0 or mouse.screenrow ~= source.row - 1 then return end
  local column = mouse.screencol - source.col + 1
  if column >= 1 and column <= accept_width then return 1 end
  if column <= accept_width + reject_width then return 2 end
  if column <= accept_width + reject_width + diff_width then return 3 end
end

local function select_control(proposal, choice)
  if pending ~= proposal or not control_win or not api.nvim_win_is_valid(control_win) then return end
  proposal.choice = choice
  api.nvim_buf_clear_namespace(control_buf, control_ns, 0, -1)
  local labels = proposal.labels or review_labels(proposal)
  local second_col = #labels[1]
  api.nvim_buf_add_highlight(control_buf, control_ns,
    choice == 1 and "PairAcceptSelected" or "PairAccept", 0, 0, second_col)
  api.nvim_buf_add_highlight(control_buf, control_ns,
    choice == 2 and "PairRejectSelected" or "PairReject", 0, second_col, second_col + #labels[2])
  api.nvim_buf_add_highlight(control_buf, control_ns, "PairDiff", 0,
    second_col + #labels[2], -1)
  local label = labels[choice]
  local offset = choice == 1 and 0 or second_col
  api.nvim_win_set_cursor(control_win, { 1, offset + (label:find("%S") or 1) - 1 })
end

local function leave_control(proposal, direction)
  if pending ~= proposal then return end
  close_control()
  local win = proposal.source_win
  if not win or not api.nvim_win_is_valid(win) then return end
  api.nvim_set_current_win(win)
  local start = control_row(proposal)
  local row = direction == "down" and start + 1 or math.max(1, start)
  row = math.max(1, math.min(row, api.nvim_buf_line_count(proposal.target.buf)))
  api.nvim_win_set_cursor(win, { row, 0 })
end

local function focus_control(proposal)
  if pending ~= proposal or control_win then return end
  local win = proposal_window(proposal)
  if not win or not api.nvim_win_is_valid(win) then return end
  proposal.source_win = win
  local function position()
    local row = control_row(proposal)
    local shown = vim.fn.screenpos(win, row + 1, 1)
    if shown.row > 1 then return shown end
    -- A headless window can report row 0 for a line with virtual lines.
    -- Estimate the control row from the viewport instead.
    local view = api.nvim_win_call(win, function() return vim.fn.winsaveview() end)
    local marks = api.nvim_buf_get_extmarks(proposal.target.buf, control_ns,
      { row, 0 }, { row, -1 }, { details = true })
    local virtual = 0
    for _, mark in ipairs(marks) do
      virtual = virtual + #(mark[4].virt_lines or {})
    end
    local top, left = unpack(vim.fn.win_screenpos(win))
    return { row = top + row + 1 - view.topline + virtual, col = left }
  end
  local source = position()
  if source.row <= 1 then
    api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
    source = position()
    if source.row <= 1 then return end
  end
  control_buf = api.nvim_create_buf(false, true)
  proposal.labels = review_labels(proposal)
  local text = table.concat(proposal.labels)
  api.nvim_buf_set_lines(control_buf, 0, -1, false, { text })
  api.nvim_set_option_value("buftype", "nofile", { buf = control_buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = control_buf })
  local width = vim.fn.strdisplaywidth(text)
  local col = math.min(math.max(0, source.col - 1), math.max(0, vim.o.columns - width))
  control_win = api.nvim_open_win(control_buf, true, {
    relative = "editor", row = source.row - 2, col = col,
    width = width,
    height = 1, style = "minimal", border = "none", focusable = true, zindex = 100,
  })
  api.nvim_set_option_value("winhighlight", "Normal:PairControl,NormalNC:PairControl", { win = control_win })
  api.nvim_set_option_value("cursorline", false, { win = control_win })
  vim.keymap.set("n", "h", function() select_control(proposal, 1) end, { buffer = control_buf, silent = true })
  vim.keymap.set("n", "l", function() select_control(proposal, 2) end, { buffer = control_buf, silent = true })
  vim.keymap.set("n", "<CR>", function()
    if proposal.choice == 1 then M.accept() else M.reject() end
  end, { buffer = control_buf, silent = true })
  vim.keymap.set("n", "d", function() M.diff() end, { buffer = control_buf, silent = true })
  vim.keymap.set("n", "k", function() leave_control(proposal, "up") end, { buffer = control_buf, silent = true })
  vim.keymap.set("n", "j", function() leave_control(proposal, "down") end, { buffer = control_buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() leave_control(proposal, "up") end, { buffer = control_buf, silent = true })
  select_control(proposal, proposal.choice or 1)
end

local function install_source_mappings(proposal)
  local buf = proposal.target.buf
  local originals = {}
  for _, key in ipairs({ "j", "k" }) do
    for _, mapping in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
      if mapping.lhs == key then originals[key] = mapping; break end
    end
    vim.keymap.set("n", key, function()
      local win = api.nvim_get_current_win()
      local row = api.nvim_win_get_cursor(win)[1]
      local start = pending == proposal and control_row(proposal) or -1
      local at_control = (key == "j" and start > 0 and row == start)
        or (key == "k" and row == start + 1)
      if pending == proposal and win == proposal.source_win and vim.v.count == 0 and at_control then
        vim.schedule(function() focus_control(proposal) end)
        return ""
      end
      return key
    end, { buffer = buf, expr = true, silent = true, replace_keycodes = false })
  end
  source_mappings = { buf = buf, keys = originals }
end

local function observe_control(proposal)
  enable_mousemove()
  local click_key = api.nvim_replace_termcodes("<LeftMouse>", true, false, true)
  local move_key = api.nvim_replace_termcodes("<MouseMove>", true, false, true)
  vim.on_key(function(key)
    if pending ~= proposal then return end
    if key == click_key or key == move_key then
      vim.schedule(function()
        if pending ~= proposal then return end
        local mouse = vim.fn.getmousepos()
        local choice = control_hit(proposal, mouse)
        if key == click_key and choice then
          if choice == 1 then M.accept() elseif choice == 2 then M.reject() else M.diff() end
        elseif key == move_key and choice and choice ~= 3 and control_win and mouse.winid == control_win then
          select_control(proposal, choice)
        elseif key == move_key and proposal.hover ~= choice then
          proposal.hover = choice
          render_control(proposal)
        end
      end)
    end
  end, mouse_ns)
end

function M.start_progress(target, kind)
  M.stop_progress()
  if not api.nvim_buf_is_valid(target.buf) then return end
  if kind == "ask" then M.dismiss_answer() end
  local timer = uv.new_timer()
  progress = { target = target, kind = kind, frame = "⠋", timer = timer, step = 1 }
  if kind == "ask" then
    answer = { target = target, text = "", complete = false }
    observe_answer(answer)
  end
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local function render_spinner()
    if not progress or progress.timer ~= timer or not api.nvim_buf_is_valid(target.buf) then return end
    progress.step = progress.step % #frames + 1
    progress.frame = frames[progress.step]
    if kind ~= "ask" or (answer and answer.text == "") then
      api.nvim_buf_clear_namespace(target.buf, progress_ns, 0, -1)
      local row = math.min(target.start_row, api.nvim_buf_line_count(target.buf) - 1)
      local current_line = api.nvim_buf_get_lines(target.buf, row, row + 1, false)[1] or ""
      api.nvim_buf_set_extmark(target.buf, progress_ns, row, math.min(target.start_col, #current_line), {
        virt_text = { { " Pair " .. progress.frame .. (kind == "ask" and " thinking" or " generating"), "DiagnosticInfo" } },
        virt_text_pos = "eol",
      })
    end
  end
  render_spinner()
  timer:start(120, 120, vim.schedule_wrap(render_spinner))
end

function M.stop_progress()
  if not progress then return end
  local target = progress.target
  progress.timer:stop()
  progress.timer:close()
  progress = nil
  if api.nvim_buf_is_valid(target.buf) then
    api.nvim_buf_clear_namespace(target.buf, progress_ns, 0, -1)
  end
end

function M.show(target, replacement, on_decision, rationale)
 M.stop_progress()
 if pending then return false, "Accept or reject the current proposal first" end
	if not api.nvim_buf_is_valid(target.buf) or not api.nvim_buf_is_loaded(target.buf) then
		return false, "Target buffer was closed or unloaded"
	end
	if api.nvim_buf_get_changedtick(target.buf) ~= target.changedtick then
		return false, "Buffer changed while Pair was working; ask again"
	end
	if replacement == target.original and target.kind == "replace" then
		return false, "Agent proposed no change"
	end
	if replacement == "" and target.kind == "insert" then
		return false, "Agent proposed no code to insert"
	end
 local lines = split_lines(replacement)
 if #lines > 200 then
  return false, "Proposal exceeds 200 lines; request a smaller change"
 end
 M.dismiss_answer()
 local original_line_count = api.nvim_buf_line_count(target.buf)
 local context_start = math.max(0, target.start_row - 3)
 local before_end = math.min(original_line_count, target.end_row + 4)
 local before_lines = api.nvim_buf_get_lines(target.buf, context_start, before_end, false)
 local win = source_window(target.buf)
 local applied = lines
 -- Keep the proposal separate from edits made just before the agent replied.
 vim.bo[target.buf].undolevels = vim.bo[target.buf].undolevels
 if target.linewise then
  if replacement == "" then
   applied = {}
  elseif applied[#applied] == "" then
   table.remove(applied)
  end
  api.nvim_buf_set_lines(target.buf, target.start_row, target.end_row + 1, false, applied)
 else
  api.nvim_buf_set_text(target.buf, target.start_row, target.start_col, target.end_row, target.end_col, applied)
 end
 local undo_seq = api.nvim_buf_call(target.buf, function() return vim.fn.undotree().seq_cur end)
 -- The next user edit should not silently join the proposal's undo block.
 vim.bo[target.buf].undolevels = vim.bo[target.buf].undolevels
 local end_row, end_col, last_row
 if target.linewise then
  end_row = target.start_row + #applied
  last_row = target.start_row + math.max(#applied - 1, 0)
 else
  end_row = target.start_row + #applied - 1
  end_col = #applied == 1 and target.start_col + #applied[1] or #applied[#applied]
  last_row = end_row
 end
 local after_end = math.min(api.nvim_buf_line_count(target.buf), end_row + 4)
 local after_lines = api.nvim_buf_get_lines(target.buf, context_start, after_end, false)
 pending = {
  target = target, replacement = replacement, applied = applied,
  diff_before = before_lines, diff_after = after_lines, diff_start = context_start,
  source_win = win, anchor_row = math.max(1, target.start_row), choice = 1,
  applied_tick = api.nvim_buf_get_changedtick(target.buf),
  undo_seq = undo_seq,
  end_row = end_row, end_col = end_col, last_row = last_row,
  all_deleted = target.linewise and #applied == 0 and target.start_row == 0
    and target.end_row + 1 == original_line_count,
  on_decision = on_decision,
  rationale = type(rationale) == "string" and vim.trim(rationale) or nil,
 }
 local proposal = pending
 api.nvim_buf_attach(target.buf, false, {
  on_lines = function()
   if pending ~= proposal then return true end
   local event_seq = api.nvim_buf_call(target.buf, function() return vim.fn.undotree().seq_cur end)
   vim.schedule(function()
    if pending ~= proposal or not api.nvim_buf_is_loaded(target.buf) then return end
    local seq = api.nvim_buf_call(target.buf, function() return vim.fn.undotree().seq_cur end)
    if event_seq >= proposal.undo_seq and seq >= proposal.undo_seq then return end
    clean()
    if proposal.on_decision then proposal.on_decision("rejected") end
   end)
  end,
 })
 pending.anchor_id = api.nvim_buf_set_extmark(target.buf, anchor_ns, target.start_row, 0, {
  right_gravity = false,
 })
 for row = target.start_row, math.min(last_row, api.nvim_buf_line_count(target.buf) - 1) do
  api.nvim_buf_set_extmark(target.buf, ns, row, 0, { line_hl_group = "DiffAdd" })
 end
 render_control(pending)
 observe_control(pending)
 install_source_mappings(pending)
 if win and api.nvim_win_is_valid(win) then
  local row = math.min(pending.anchor_row - 1, api.nvim_buf_line_count(target.buf) - 1)
  local line = api.nvim_buf_get_lines(target.buf, row, row + 1, false)[1] or ""
  api.nvim_win_set_cursor(win, { row + 1, math.min(target.start_col, math.max(0, #line - 1)) })
 end
 return true
end

function M.accept()
 if not pending then return false, "No pending proposal" end
 local proposal = pending
 clean()
 if proposal.on_decision then proposal.on_decision("accepted") end
 return true
end

function M.reject()
 if not pending then return false, "No pending proposal" end
 local proposal = pending
 local target = proposal.target
 if not api.nvim_buf_is_valid(target.buf) or not api.nvim_buf_is_loaded(target.buf) then
  clean()
  return false, "Target buffer was closed or unloaded"
 end
  if api.nvim_buf_get_changedtick(target.buf) ~= proposal.applied_tick then
    return false, "Buffer changed since the proposal; accept or save it instead of rejecting"
 end
 if target.linewise then
  api.nvim_buf_set_lines(target.buf, target.start_row,
   proposal.all_deleted and 1 or proposal.end_row, false, split_lines(target.original))
 else
  api.nvim_buf_set_text(target.buf, target.start_row, target.start_col,
   proposal.end_row, proposal.end_col, split_lines(target.original or ""))
 end
 clean()
 if proposal.on_decision then proposal.on_decision("rejected") end
 return true
end

function M.pending()
	return pending
end

local function diff_buffer(name, lines, filetype)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, name)
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  if filetype ~= "" then api.nvim_set_option_value("filetype", filetype, { buf = buf }) end
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  return buf
end

function M.diff()
  if not pending then return false, "No pending proposal" end
  if diff_view and api.nvim_tabpage_is_valid(diff_view.tab) then
    M.close_diff()
    return true
  end
  local proposal = pending
  if not api.nvim_buf_is_valid(proposal.target.buf) or not api.nvim_buf_is_loaded(proposal.target.buf) then
    return false, "Target buffer was closed or unloaded"
  end
  local origin_win = api.nvim_get_current_win()
  local origin_view = api.nvim_win_call(origin_win, vim.fn.winsaveview)
  local origin_cursor = api.nvim_win_get_cursor(origin_win)
  local filetype = vim.bo[proposal.target.buf].filetype
  local path = proposal.target.path ~= "" and vim.fn.fnamemodify(proposal.target.path, ":t") or "[No Name]"
  path = path:gsub("%%", "%%%%")
  local changed = api.nvim_buf_get_changedtick(proposal.target.buf) ~= proposal.applied_tick
  diff_serial = diff_serial + 1
  local before_buf = diff_buffer("pair://diff/original/" .. diff_serial, proposal.diff_before, filetype)
  local after_buf = diff_buffer("pair://diff/proposed/" .. diff_serial, proposal.diff_after, filetype)
  vim.cmd("tabnew")
  local left = api.nvim_get_current_win()
  api.nvim_win_set_buf(left, before_buf)
  vim.cmd("vsplit")
  local right = api.nvim_get_current_win()
  api.nvim_win_set_buf(right, after_buf)
  local view = {
    tab = api.nvim_get_current_tabpage(), proposal = proposal, origin_win = origin_win,
    origin_view = origin_view, origin_cursor = origin_cursor,
  }
  diff_view = view
  for _, spec in ipairs({ { left, before_buf, "Original" }, { right, after_buf, "Proposed as applied" } }) do
    local win, buf, title = spec[1], spec[2], spec[3]
    api.nvim_set_option_value("number", true, { win = win })
    api.nvim_set_option_value("relativenumber", false, { win = win })
    api.nvim_set_option_value("wrap", false, { win = win })
    api.nvim_set_option_value("statuscolumn",
      "%=%{v:virtnum == 0 ? v:lnum + " .. proposal.diff_start .. " : ''} ", { win = win })
    api.nvim_set_option_value("winbar", " Pair Diff · " .. title .. " · " .. path
      .. (changed and " · source buffer changed" or ""), { win = win })
    api.nvim_win_call(win, function() vim.cmd("diffthis") end)
    vim.keymap.set("n", "q", M.close_diff, { buffer = buf, silent = true, desc = "Close Pair diff" })
    vim.keymap.set("n", "<Esc>", M.close_diff, { buffer = buf, silent = true, desc = "Close Pair diff" })
    local row = math.max(1, math.min(proposal.target.start_row - proposal.diff_start + 1,
      api.nvim_buf_line_count(buf)))
    api.nvim_win_set_cursor(win, { row, 0 })
  end
  api.nvim_set_current_win(right)
  return true
end

function M.show_answer(target, text, complete)
 if not api.nvim_buf_is_valid(target.buf) then return false end
 if not answer or answer.target ~= target then
  M.dismiss_answer()
  answer = { target = target, text = text, complete = complete ~= false }
  observe_answer(answer)
 else
  answer.text = text
  answer.complete = complete ~= false
 end
 if text ~= "" and api.nvim_buf_is_valid(target.buf) then
  api.nvim_buf_clear_namespace(target.buf, progress_ns, 0, -1)
 end
 if complete ~= false then M.stop_progress() end
 return render_answer()
end

function M.dismiss_answer()
 if progress and progress.kind == "ask" then M.stop_progress() end
 vim.on_key(nil, answer_mouse_ns)
 if answer and api.nvim_buf_is_valid(answer.target.buf) then
  api.nvim_buf_clear_namespace(answer.target.buf, answer_ns, 0, -1)
 end
 answer = nil
 restore_mousemove()
end

api.nvim_create_autocmd("WinResized", { callback = function()
  if answer then render_answer() end
  local proposal = pending
  if not proposal then return end
  local focused = control_win and api.nvim_win_is_valid(control_win)
    and api.nvim_get_current_win() == control_win
  if control_win then close_control() end
  render_control(proposal)
  if focused then vim.schedule(function() if pending == proposal then focus_control(proposal) end end) end
end })
api.nvim_create_autocmd("WinClosed", {
 callback = function(event)
  if tonumber(event.match) == control_win then
   control_win = nil
   if control_buf and api.nvim_buf_is_valid(control_buf) then
    api.nvim_buf_delete(control_buf, { force = true })
   end
   control_buf = nil
  end
 end,
})
api.nvim_create_autocmd("TabClosed", {
 callback = function()
  local view = diff_view
  if not view or api.nvim_tabpage_is_valid(view.tab) then return end
  diff_view = nil
  vim.schedule(function() restore_review_focus(view) end)
 end,
})
api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
 callback = function()
  if not pending then return end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_config(win).relative ~= ""
    or api.nvim_win_get_buf(win) ~= pending.target.buf then return end
  pending.source_win = win
  render_control(pending)
 end,
})
api.nvim_create_autocmd("BufWritePost", {
 callback = function(event)
  if pending and pending.target.buf == event.buf then M.accept() end
 end,
})
api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
 callback = function(event)
  if pending and pending.target.buf == event.buf then
   if diff_view then
    local proposal = pending
    vim.schedule(function() if pending == proposal then clean() end end)
   else
    clean()
   end
  end
  if answer and answer.target.buf == event.buf then M.dismiss_answer() end
  if progress and progress.target.buf == event.buf then M.stop_progress() end
 end,
})

return M
