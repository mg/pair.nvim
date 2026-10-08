-- Exercise the built-in Pi preset through Pair, without contacting a provider.
local api = vim.api
local plugin = vim.fn.getcwd()
vim.opt.rtp:append(plugin)
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
vim.fn.writefile(vim.fn.readfile(plugin .. "/tests/mock_pi.py"), root .. "/bin/pi")
vim.fn.setfperm(root .. "/bin/pi", "rwxr-xr-x")
local prior_path = vim.env.PATH
vim.env.PATH = root .. "/bin:" .. prior_path
vim.cmd.cd(root)
root = vim.fn.getcwd()
vim.fn.writefile({ "disk copy" }, root .. "/sample.lua")
vim.cmd.edit(root .. "/sample.lua")
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved copy", "second line" })
local pair, edit, sessions = require("pair"), require("pair.edit"), require("pair.sessions")
pair.setup({ backend = "pi", keymaps = false, remember_selection = false, models = { pi = "mock/other" } })
assert(pair.health_info().transport == "rpc")
local record = assert(sessions.current(root, "pi"))
local function wait(fn) assert(vim.wait(5000, fn, 10), "Pi Pair flow timed out") end
local function ready()
  local header = vim.fn.bufnr("pair://header")
  return header ~= -1 and table.concat(api.nvim_buf_get_lines(header, 0, -1, false), " "):find("Ready", 1, true)
end
local function source() api.nvim_set_current_win(win) end
pair.send("chat")
wait(function() return vim.fn.filereadable(record.session) == 1 and ready() end)
local pointer = vim.fn.readfile(record.session)[1]
local first_prompt = vim.json.decode(vim.fn.readfile(pointer)[1]).message
assert(first_prompt:find("unsaved copy", 1, true), "Pi must receive the editor snapshot")
pair.model("mock/default")
wait(function() return sessions.read_model(record) == "mock/default" end)
source()
vim.cmd("normal! gg0V\27")
pair.ask("explain")
wait(function() return #vim.fn.readfile(pointer) >= 2 and ready() end)
edit.dismiss_answer()
source()
vim.cmd("normal! gg0V\27")
pair.change("replace")
wait(function() return edit.pending() end)
assert(api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "changed")
assert(edit.reject())
assert(api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "unsaved copy")
source()
api.nvim_win_set_cursor(win, { 2, 0 })
pair.here("insert")
wait(function() return edit.pending() end)
assert(edit.accept())
assert(api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changedsecond line")
assert(vim.fn.readfile(root .. "/sample.lua")[1] == "disk copy")
local previous = record
pair.new_session()
record = sessions.current(root, "pi")
assert(record.id ~= previous.id)
local select = vim.ui.select
vim.ui.select = function(items, _, callback)
  for _, item in ipairs(items) do if item.id == previous.id then callback(item); return end end
end
pair.pick_session()
vim.ui.select = select
wait(function() return sessions.current(root, "pi").id == previous.id and ready() end)
source()
pair.send("resumed")
wait(function() return #vim.fn.readfile(pointer) >= 5 and ready() end)
pair.cancel()
vim.env.PATH = prior_path
vim.bo[buf].modified = false
vim.fn.delete(root, "rf")
print("Pair Pi mock workflow tests passed")
