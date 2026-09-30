-- Opt-in end-to-end Codex check of Pair chat and selection Ask.
vim.opt.rtp:append(vim.fn.getcwd())

local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/pair_probe.txt"
local nonce = vim.fn.sha256(root):sub(1, 10)
local disk_text = "PAIR_DISK_" .. nonce
local live_text = "PAIR_EDITOR_" .. nonce
vim.fn.writefile({ disk_text }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win = api.nvim_get_current_win()
local source_buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, -1, false, { live_text })

local pair = require("pair")
pair.setup({ keymaps = false })
local state_root = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root)
local history_path = assert(require("pair.sessions").current(root, "codex")).transcript
local function agent_replies()
  if vim.fn.filereadable(history_path) == 0 then return {} end
  local replies = {}
  for _, entry in ipairs(vim.json.decode(table.concat(vim.fn.readfile(history_path), "\n"))) do
    if entry.role == "Agent" then replies[#replies + 1] = entry.text end
  end
  return replies
end
local function has_editor_answer(count)
  local matches = 0
  for _, reply in ipairs(agent_replies()) do
    if reply:find(live_text, 1, true) then matches = matches + 1 end
  end
  return matches >= count
end

pair.send("What exact single line is in the attached Neovim editor snapshot? Reply with that line only.")
local chat_ok = vim.wait(90000, function() return has_editor_answer(1) end, 50)
local ask_ok = false
if chat_ok then
  api.nvim_set_current_win(source_win)
  vim.cmd("normal! gg0V\27")
  pair.ask("What exact line is selected in the attached editor snapshot? Reply with that line only.")
  ask_ok = vim.wait(90000, function() return has_editor_answer(2) end, 50)
end

local report = {
  backend = "codex", chat_used_editor = chat_ok, ask_used_editor = ask_ok,
  disk_unchanged = vim.fn.readfile(path)[1] == disk_text,
  editor_unchanged = api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == live_text,
  agent_replies = agent_replies(),
}
pair.new_session()
vim.fn.delete(state_root .. ".records", "rf")
vim.fn.delete(state_root .. ".sessions.json")
vim.fn.delete(root, "rf")
print(vim.json.encode(report))
