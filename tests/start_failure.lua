vim.opt.rtp:append(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
local pair = require("pair")
pair.setup({ backend = "missing", keymaps = false, agents = { missing = {
  kind = "acp", command = root .. "/missing-agent", args = {},
  required_mode = "plan", restricted = true,
} } })
pair.send("first request")
local function chat_text()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf) == "pair://chat" then
      return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end
assert(chat_text():find("Could not start", 1, true)
  and chat_text():find("Executable for missing is missing", 1, true),
  "startup failure should explain how to retry")
pair.new_session()
assert(chat_text() == "Ask about this project, or select code in the editor.",
  "new chat should recover the UI after startup failure")
vim.fn.delete(root, "rf")
print("Pair startup failure tests passed")
