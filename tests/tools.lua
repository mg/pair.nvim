vim.opt.rtp:append(vim.fn.getcwd())
local ui = require("pair.ui")
local api = vim.api
ui.chat()
local chat_win
for _, win in ipairs(api.nvim_list_wins()) do
  if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == "pair://chat" then chat_win = win end
end
assert(chat_win)
local chat_buf = api.nvim_win_get_buf(chat_win)
local function lines() return api.nvim_buf_get_lines(chat_buf, 0, -1, false) end
local function find_tool()
  for row, line in ipairs(lines()) do
    if line:find("Read sample.lua", 1, true) then return row, line end
  end
end

local index = ui.tool(nil, { title = "Read sample.lua", status = "running",
  detail = "Tool: Read sample.lua" })
local row, line = find_tool()
assert(row and line:find("◌", 1, true), "inspection should show one running row")
assert(#lines() == 1, "tool details should start collapsed")
ui.tool(index, { status = "completed", detail = "Tool: Read sample.lua\nOutput:\nsample contents" })
row, line = find_tool()
assert(line:find("✓", 1, true) and #lines() == 1, "completion should update the same compact row")
api.nvim_set_current_win(chat_win)
api.nvim_win_set_cursor(chat_win, { row, 0 })
assert(ui.toggle_tool(), "Enter on a tool should expand it")
assert(table.concat(lines(), "\n"):find("sample contents", 1, true), "expanded row should show output")
assert(ui.toggle_tool(), "expanded tool should collapse")
assert(#lines() == 1, "collapsed tool should be compact again")

local failed = ui.tool(nil, { title = "rg missing", status = "running", detail = "Command: rg missing" })
ui.tool(failed, { status = "failed", detail = "Command: rg missing\nError: no matches\nExit code: 1" })
local failure_row
for row_number, text in ipairs(lines()) do
  if text:find("rg missing", 1, true) then failure_row = row_number; assert(text:find("✕", 1, true)) end
end
assert(failure_row, "failed inspection should have its own row")
api.nvim_win_set_cursor(chat_win, { failure_row, 0 })
assert(ui.toggle_tool())
assert(table.concat(lines(), "\n"):find("Exit code: 1", 1, true), "failure details should be expandable")
ui.toggle_tool()
local unfinished = ui.tool(nil, { title = "Inspect fallback", status = "running" })
ui.finish_tool(unfinished, false)
assert(table.concat(lines(), "\n"):find("✓ Inspect fallback", 1, true),
  "a successful turn should finish tools without a completion event")

for n = 1, 35 do ui.add("Agent", "scroll row " .. n) end
api.nvim_set_current_win(chat_win)
api.nvim_win_set_cursor(chat_win, { find_tool(), 0 })
assert(ui.toggle_tool())
assert(api.nvim_win_get_cursor(chat_win)[1] == find_tool(),
  "expanding an older tool should keep the cursor on its row")
assert(ui.toggle_tool(), "Enter should collapse the same tool without moving away")
api.nvim_feedkeys(api.nvim_replace_termcodes("5<C-Y>", true, false, true), "x", false)
vim.wait(30)
local before = api.nvim_win_call(chat_win, vim.fn.winsaveview)
local streaming = ui.tool(nil, { title = "Inspect logs", status = "running" })
ui.tool(streaming, { status = "completed", detail = string.rep("output", 1000) })
local after = api.nvim_win_call(chat_win, vim.fn.winsaveview)
assert(after.topline == before.topline and after.skipcol == before.skipcol,
  "tool streaming should preserve manual chat scrolling")
api.nvim_win_set_cursor(chat_win, { api.nvim_buf_line_count(chat_buf), 0 })
assert(ui.toggle_tool())
assert(#table.concat(lines(), "\n") < 5000, "tool output should be bounded")
ui.close()
print("Pair tool entry tests passed")
