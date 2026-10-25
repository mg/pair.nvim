vim.opt.rtp:append(vim.fn.getcwd())
local pair = require("pair")
pair.setup({ backend = "pi", keymaps = false, remember_selection = false })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first line", "current context", "" })
local source_win = vim.api.nvim_get_current_win()
local edit = require("pair.edit")
local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

-- No Visual marks: use the whole cursor line, including empty lines.
for _, row in ipairs({ 2, 3 }) do
  vim.api.nvim_win_set_cursor(source_win, { row, 0 })
  local target = assert(edit.selection())
  assert(target.linewise and target.start_row == row - 1 and target.end_row == row - 1)
  assert(target.original == (row == 2 and "current context" or ""))
  for _, command in ipairs({ "PairAsk", "PairChange" }) do
    vim.cmd(command)
    assert(vim.bo.filetype == "pairprompt", "missing selections should open a request prompt")
    assert(#notices == 0, "current-line fallback must not warn")
    local keys = vim.api.nvim_replace_termcodes("<Esc>q", true, false, true)
    vim.api.nvim_feedkeys(keys, "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == source_win end))
  end
end

-- Unsupported selections should report their specific error, not crash.
vim.cmd("normal! gg0\22l\27")
for _, command in ipairs({ "PairAsk", "PairChange" }) do
  vim.cmd(command)
  assert(notices[#notices].message == "Pair: Blockwise selections are not supported yet")
end
assert(vim.api.nvim_get_current_win() == source_win, "invalid selections must not open a request prompt")
vim.bo.modified = false
print("Pair selection error tests passed")
