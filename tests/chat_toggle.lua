vim.opt.rtp:append(vim.fn.getcwd())
vim.g.mapleader = " "

local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
local path = root .. "/sample.lua"
vim.fn.writefile({ "return true" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win = api.nvim_get_current_win()
local pair = require("pair")
local ui = require("pair.ui")
pair.setup({ keymaps = true })

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(30)
end

press("<leader>pc")
assert(ui.is_open() and api.nvim_buf_get_name(0) == "pair://input",
  "Pair chat mapping should open the chat input")
vim.cmd("stopinsert")
local input_buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(input_buf, 0, -1, false, { "unsent draft" })
press("<leader>pc")
assert(not ui.is_open() and api.nvim_get_current_win() == source_win,
  "Pair chat mapping should close all chat windows and return to source")

press("<leader>pc")
assert(ui.is_open() and api.nvim_get_current_buf() == input_buf,
  "Pair chat mapping should reopen the same input buffer")
assert(api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "unsent draft",
  "toggling should keep an unsent draft")
vim.cmd("stopinsert")
vim.cmd("PairChat")
assert(not ui.is_open() and api.nvim_get_current_win() == source_win,
  ":PairChat should close an open chat")
vim.cmd("PairChat")
assert(ui.is_open(), ":PairChat should reopen a closed chat")
vim.cmd("stopinsert")
pair.toggle_chat()
assert(not ui.is_open(), "programmatic toggle should close chat")

local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root)
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(root, "rf")
print("Pair chat toggle tests passed")
