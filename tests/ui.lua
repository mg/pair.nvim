vim.opt.rtp:append(vim.fn.getcwd())
local ui = require("pair.ui")
local api = vim.api
local source_buf = api.nvim_get_current_buf()
local sent

ui.on_send(function(message) sent = message end)
ui.chat()
assert(ui.is_open(), "chat should report both windows as open")
assert(#api.nvim_list_wins() == 4, "chat should have fixed header, transcript, and input beside the source")
local input_buf = api.nvim_get_current_buf()
assert(api.nvim_buf_get_name(input_buf) == "pair://input", "chat should focus its persistent input")
local input_win = api.nvim_get_current_win()
local chat_win
local header_win
for _, win in ipairs(api.nvim_list_wins()) do
  if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == "pair://chat" then chat_win = win end
  if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == "pair://header" then header_win = win end
end
assert(chat_win and header_win, "chat header and transcript windows should exist")
assert(api.nvim_win_get_height(header_win) == 1, "the fixed chat header should be one row high")
assert(api.nvim_win_get_position(header_win)[1] < api.nvim_win_get_position(chat_win)[1],
  "the fixed header should sit above the scrolling transcript")
assert(api.nvim_win_get_position(chat_win)[1] > api.nvim_win_get_position(header_win)[1] + 1,
  "the window divider should separate the header from chat")
assert(api.nvim_win_get_width(input_win) == api.nvim_win_get_width(chat_win), "input should match chat pane width")
assert(api.nvim_win_get_position(input_win)[2] == api.nvim_win_get_position(chat_win)[2], "input should stay under the transcript")
assert(api.nvim_win_get_width(input_win) < vim.o.columns, "input must not span the editor")
assert(vim.wo[input_win].winbar == "", "input should not have a decorative top border")
assert(api.nvim_win_get_height(input_win) == 3, "input should show three editable lines")
assert(api.nvim_buf_line_count(input_buf) == 3, "all three default input rows should be editable")
assert(vim.wo[input_win].statuscolumn:find("❯", 1, true), "prompt should sit beside the first editable row")
assert(vim.wo[input_win].statuscolumn:find("v:virtnum == 0", 1, true),
  "wrapped input rows should not repeat the prompt marker")
assert(vim.wo[input_win].number and api.nvim_win_get_cursor(input_win)[2] == 0,
  "the cursor should stay at the first editable column after the prompt gutter")
assert(vim.fn.screenpos(input_win, 1, 1).col > api.nvim_win_get_position(input_win)[2] + 1,
  "the prompt gutter should keep the cursor clear of the prompt glyph")
assert(vim.b[input_buf].completion == false, "completion should be disabled in the chat input")
assert(vim.wo[input_win].winhighlight:find("NormalNC:PairInput", 1, true), "input should keep its own background")
assert(vim.wo[chat_win].winhighlight:find("NormalNC:Normal", 1, true), "chat should keep active-pane colors")
assert(api.nvim_buf_get_lines(api.nvim_win_get_buf(header_win), 0, 1, false)[1]:find("Pair Chat", 1, true),
  "chat should have a clear title")
assert(api.nvim_get_hl(0, { name = "PairChatHeader", link = false }).bg
  ~= api.nvim_get_hl(0, { name = "PairUserMessage", link = false }).bg,
  "chat header and user messages should have distinct backgrounds")
assert(vim.bo[input_buf].modifiable, "chat input should use an editable Neovim buffer")
local function mapped(mode, key)
  for _, mapping in ipairs(api.nvim_buf_get_keymap(input_buf, mode)) do
    if mapping.lhs == key then return true end
  end
  return false
end
assert(mapped("n", "<CR>"), "Normal-mode Enter should send")
assert(mapped("n", "gN"), "the chat input should offer a new-session mapping")
assert(not mapped("i", "<CR>") and not mapped("i", "<C-S>"), "Insert-mode Enter should keep its normal newline behavior")
api.nvim_buf_set_lines(input_buf, 0, -1, false, { "Explain this", "and this" })
assert(ui.submit(), "nonempty input should send")
assert(sent == "Explain this\nand this", "input should preserve multiline messages")
assert(api.nvim_buf_line_count(input_buf) == 3 and api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == "", "sending should restore three empty input rows")
assert(not ui.submit(), "empty input should not send")

ui.add("You", "Explain the helper")
ui.add("Pair", "Checking the project")
ui.add("Tool", "rg helper")
ui.add("Agent", "A `helper` is reusable.\n```lua\nreturn true\n```")
local chat_buf = api.nvim_win_get_buf(chat_win)
local chat_new = false
for _, mapping in ipairs(api.nvim_buf_get_keymap(chat_buf, "n")) do
  if mapping.lhs == "gN" then chat_new = true end
end
assert(chat_new, "the transcript should offer a new-session mapping")
assert(api.nvim_buf_get_lines(chat_buf, 0, 1, false)[1]:find("Explain the helper", 1, true),
  "chat transcript should start below the fixed header")
local transcript = table.concat(api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(not transcript:find("You:", 1, true) and not transcript:find("Pair:", 1, true) and not transcript:find("Agent:", 1, true), "messages should not have role labels")
assert(transcript:find("› Explain the helper", 1, true), "user messages should have a distinct marker")
local chat_ns = api.nvim_get_namespaces()["pair.nvim.chat"]
local marks = api.nvim_buf_get_extmarks(chat_buf, chat_ns, 0, -1, { details = true })
local user_background = false
for _, mark in ipairs(marks) do
  if mark[4].line_hl_group == "PairUserMessage" then user_background = true end
end
assert(user_background, "user messages should have a background highlight")
local function press(key)
  api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "x", false)
  vim.wait(30)
end
api.nvim_buf_set_lines(input_buf, 0, -1, false, { "unsent draft" })
ui.clear()
assert(api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "", "clearing chat should clear its unsent draft")
ui.add("Agent", "A short answer")
api.nvim_set_current_win(chat_win)
press("20<C-E>")
local short_view = api.nvim_win_call(chat_win, vim.fn.winsaveview)
assert(short_view.topline == 1 and short_view.skipcol == 0,
  "short chat content should not scroll away from the top")
for index = 1, 35 do ui.add("Agent", "scroll check " .. index) end
local function assert_chat_at_bottom()
  vim.cmd("redraw")
  local last = api.nvim_buf_line_count(chat_buf)
  local screen = vim.fn.screenpos(chat_win, last, 1)
  local bottom = api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win)
  assert(screen.row == bottom, "the final chat line should sit at the physical bottom of the transcript pane")
end
assert_chat_at_bottom()
api.nvim_set_current_win(chat_win)
press("5<C-Y>")
local reading_view = api.nvim_win_call(chat_win, vim.fn.winsaveview)
assert(reading_view.topline > 1, "long chat should scroll upward for reading")
ui.append(35, "\nNew streamed text while reading")
local streamed_view = api.nvim_win_call(chat_win, vim.fn.winsaveview)
assert(streamed_view.topline == reading_view.topline and streamed_view.skipcol == reading_view.skipcol,
  "streaming should preserve a manually scrolled chat position: " .. vim.inspect({ reading_view, streamed_view }))
ui.follow()
assert_chat_at_bottom()
press("k")
local reading_cursor = api.nvim_win_get_cursor(chat_win)[1]
ui.append(35, "\nMore text while navigating")
assert(api.nvim_win_get_cursor(chat_win)[1] == reading_cursor,
  "streaming should not pull the cursor away while navigating older chat text")
ui.follow()
assert_chat_at_bottom()
press("20<C-E>")
assert_chat_at_bottom()
api.nvim_win_set_height(input_win, 6)
api.nvim_exec_autocmds("WinResized", {})
vim.wait(30)
assert_chat_at_bottom()
ui.append(4, "\nA streamed follow-up")
assert_chat_at_bottom()
ui.add("Agent", string.rep("A wrapped final paragraph ", 20))
vim.cmd("redraw")
local last = api.nvim_buf_line_count(chat_buf)
local final_line = api.nvim_buf_get_lines(chat_buf, last - 1, last, false)[1]
local final_cell = vim.fn.screenpos(chat_win, last, #final_line)
assert(final_cell.row == api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win),
  "the final wrapped row should sit at the bottom while streaming: " .. vim.inspect({
    final_cell = final_cell, height = api.nvim_win_get_height(chat_win),
    view = api.nvim_win_call(chat_win, vim.fn.winsaveview),
  }))
local streaming_entry = ui.add("Agent", "")
for iteration = 1, 40 do
  ui.append(streaming_entry, " several more words")
  vim.cmd("redraw")
  local final_row = api.nvim_buf_line_count(chat_buf)
  local final_text = api.nvim_buf_get_lines(chat_buf, final_row - 1, final_row, false)[1]
  local final_pos = vim.fn.screenpos(chat_win, final_row, #final_text)
  assert(final_pos.row == api.nvim_win_get_position(chat_win)[1] + api.nvim_win_get_height(chat_win),
    "a long single-line stream should keep its final wrapped cell visible: " .. vim.inspect({
      iteration = iteration, final_row = final_row, final_pos = final_pos,
      view = api.nvim_win_call(chat_win, vim.fn.winsaveview),
    }))
end
ui.close()
assert(not ui.is_open(), "chat should report both windows as closed")
assert(#api.nvim_list_wins() == 1 and api.nvim_get_current_buf() == source_buf, "closing chat should restore the source window")
local first_source_win = api.nvim_get_current_win()
ui.prompt("Ask", function() end)
local prompt_buf = api.nvim_get_current_buf()
assert(vim.b[prompt_buf].completion == false, "request input should disable completion")
assert(vim.wo.winhighlight:find("Normal:PairPrompt", 1, true), "request input should use bright Pair text")
local context_ns = api.nvim_get_namespaces()["pair.nvim.context_indicator"]
assert(not context_ns or #api.nvim_buf_get_extmarks(prompt_buf, context_ns, 0, -1, {}) == 0,
  "request input should not overlay the first line with context controls")
api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>q", true, false, true), "x", false)
assert(vim.wait(1000, function() return api.nvim_get_current_win() == first_source_win end, 10),
  "closing a request prompt should restore source focus")
ui.chat()
assert(api.nvim_get_current_buf() == input_buf, "reopening chat should reuse the input")
local source_win
for _, win in ipairs(api.nvim_list_wins()) do
  if api.nvim_win_get_buf(win) == source_buf then source_win = win end
end
assert(source_win)
api.nvim_set_current_win(source_win)
vim.wait(30)
assert(api.nvim_get_mode().mode ~= "i", "chat should not start Insert mode after focus has moved to source")
local focus = api.nvim_get_current_win()
ui.add("Agent", string.rep("Streaming while editing ", 20))
assert(api.nvim_get_current_win() == focus, "background chat streaming should keep source focus")
vim.cmd("vsplit")
ui.chat()
vim.cmd("quit")
assert(vim.wait(1000, function()
  local sources, pair_windows = 0, 0
  for _, win in ipairs(api.nvim_list_wins()) do
    local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
    if name == "pair://header" or name == "pair://chat" or name == "pair://input" then pair_windows = pair_windows + 1 else sources = sources + 1 end
  end
  return sources == 1 and pair_windows == 3
end, 10), ":q in Pair should quit the source window and preserve Pair when another source remains")
ui.close()

api.nvim_buf_set_lines(source_buf, 0, -1, false, { "unsaved change" })
ui.chat()
vim.cmd("quit")
assert(vim.wait(1000, ui.is_open, 10), "Pair should reopen when source :q is refused for unsaved changes")
assert(api.nvim_buf_is_valid(source_buf), "refused :q must keep the source buffer")
api.nvim_set_option_value("modified", false, { buf = source_buf })
ui.close()

local remaining_source
for _, win in ipairs(api.nvim_list_wins()) do
  if api.nvim_win_get_config(win).relative == "" then remaining_source = win end
end
assert(remaining_source)
api.nvim_set_current_win(remaining_source)
api.nvim_buf_set_name(0, vim.fn.tempname() .. ".lua")
ui.chat()
api.nvim_set_current_win(remaining_source)
vim.cmd("bdelete")
assert(vim.wait(1000, function() return not ui.is_open() end, 10), "deleting the last source buffer should close Pair")

print("Pair UI tests passed")
