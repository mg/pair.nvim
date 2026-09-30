vim.opt.rtp:append(vim.fn.getcwd())
local plugin_root = vim.fn.getcwd()
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
vim.cmd("cd " .. vim.fn.fnameescape(workspace))
vim.cmd("edit sample.lua")
local pair = require("pair")
pair.setup({ backend = "mock", keymaps = false, agents = { mock = {
  kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
  required_mode = "plan", restricted = true,
} } })
pair.chat()
pair.send("status tool")
local api = vim.api
local chat_win
for _, win in ipairs(api.nvim_list_wins()) do
  if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == "pair://chat" then chat_win = win end
end
assert(chat_win)
local chat_buf = api.nvim_win_get_buf(chat_win)
local function tool_rows()
  local found = {}
  for row, line in ipairs(api.nvim_buf_get_lines(chat_buf, 0, -1, false)) do
    if line:find("Read sample.lua", 1, true) then found[#found + 1] = { row = row, text = line } end
  end
  return found
end
assert(vim.wait(3000, function()
  local found = tool_rows()
  return #found == 1 and found[1].text:find("◌", 1, true)
end, 10), "Pair should render the running inspection")
assert(vim.wait(3000, function()
  local found = tool_rows()
  return #found == 1 and found[1].text:find("✓", 1, true)
end, 10), "Pair should update the same row after inspection completes")
api.nvim_set_current_win(chat_win)
api.nvim_win_set_cursor(chat_win, { tool_rows()[1].row, 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
assert(vim.wait(500, function()
  return table.concat(api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("sample contents", 1, true)
end), "expanded ACP inspection should show its reported output")
pair.new_session()
vim.fn.delete(workspace, "rf")
print("Pair tool integration tests passed")
