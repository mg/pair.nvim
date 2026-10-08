vim.opt.rtp:append(vim.fn.getcwd())
local pair = require("pair")
pair.setup({ backend = "pi", keymaps = false, remember_selection = false })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select this code" })
local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

-- No Visual marks: preserve edit.selection()'s second return value.
for _, command in ipairs({ "PairAsk", "PairChange" }) do
  vim.cmd(command)
  local notice = notices[#notices]
  assert(notice.message == "Pair: Select code first", vim.inspect(notice))
  assert(notice.level == vim.log.levels.WARN)
end

-- Unsupported selections should report their specific error, not crash.
vim.cmd("normal! gg0\22l\27")
for _, command in ipairs({ "PairAsk", "PairChange" }) do
  vim.cmd(command)
  assert(notices[#notices].message == "Pair: Blockwise selections are not supported yet")
end
assert(vim.fn.bufnr("pair://prompt") == -1, "invalid selections must not open a request prompt")
vim.bo.modified = false
print("Pair selection error tests passed")
