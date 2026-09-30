vim.opt.rtp:append(vim.fn.getcwd())
vim.g.mapleader = " "

local api = vim.api
local plugin_root = vim.fn.getcwd()
local root, trace = vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/sample.lua"
vim.fn.writefile({ "saved on disk" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, -1, false, { "local alpha = 1", "local beta = 2", "return alpha + beta" })

local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local pair = require("pair")
local sessions = require("pair.sessions")
local edit = require("pair.edit")
pair.setup({ backend = "mock", keymaps = true, agents = {
  mock = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_PROMPT_TRACE = trace }, required_mode = "plan", restricted = true },
  other = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    required_mode = "plan", restricted = true },
} })

local picked
vim.ui.select = function(items, opts, callback)
  picked = { items = items, opts = opts, callback = callback }
end
local function choose(id)
  assert(picked and picked.opts.prompt == "Pair actions:", "expected Pair action picker")
  for _, item in ipairs(picked.items) do
    if item.id == id then picked.callback(item); return end
  end
  error("missing action " .. id)
end
local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(40)
end
local function source()
  api.nvim_set_current_win(source_win)
end
local function prompt()
  assert(vim.bo.filetype == "pairprompt", "expected scoped request prompt")
end
local function requests()
  if vim.fn.filereadable(trace) ~= 1 then return {} end
  local result = {}
  for _, line in ipairs(vim.fn.readfile(trace)) do result[#result + 1] = vim.json.decode(line) end
  return result
end
local function snapshot(index)
  assert(vim.wait(4000, function() return #requests() >= index end, 20), "expected request " .. index)
  return vim.json.decode(assert(requests()[index]:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>")))
end

press("<leader>pp")
assert(#picked.items == 7 and not picked.items[2].available and not picked.items[3].available,
  "normal mapping should show all seven actions; scoped actions need a selection")
choose("ask")
assert(table.concat(notices, "\n"):find("select code first", 1, true),
  "an unavailable action should explain what is needed")
vim.cmd("PairActions")
choose("chat")
assert(vim.bo.filetype == "pairinput", "Chat should focus the persistent chat input")

source()
press("gg0v4l<leader>pp")
assert(picked.items[2].available and picked.items[3].available,
  "Visual action picker should offer selection actions")
choose("ask")
prompt()
press("iexplain this<CR>")
local ask = snapshot(1)
assert(ask.scope.text == "local" and ask.scope.start_col == 0 and ask.scope.end_col == 5,
  "Ask should keep the exact Visual selection across the picker")

source()
press("gg0v4l:PairActions<CR>")
assert(picked.opts.prompt == "Pair actions:" and picked.items[2].available,
  "typing the command from Visual mode should preserve selection")
picked.callback(nil)

source()
press("gg0Vj<leader>pp")
choose("change")
prompt()
press("ipair-test-change<CR>")
local change = snapshot(2)
assert(change.scope.linewise and change.scope.start_row == 0 and change.scope.end_row == 2,
  "Change should keep the linewise Visual selection")
assert(vim.wait(4000, function() return edit.pending() ~= nil end, 20),
  "Change should use the existing proposal flow")
assert(edit.reject())

source()
api.nvim_win_set_cursor(source_win, { 2, 0 })
vim.cmd("PairActions")
choose("insert")
prompt()
press("ipair-test-insert<CR>")
local insertion = snapshot(3)
assert(insertion.scope.kind == "insert" and insertion.scope.start_row == 1
  and insertion.scope.start_col == 0, "Insert should keep the cursor position at picker opening")
assert(vim.wait(4000, function() return edit.pending() ~= nil end, 20))
assert(edit.reject())

source()
vim.cmd("2,3PairActions")
choose("ask")
prompt()
press("iexplain range<CR>")
local ranged = snapshot(4)
assert(ranged.scope.linewise and ranged.scope.start_row == 1 and ranged.scope.end_row == 3,
  "explicit Ex ranges should reach the action picker")

source()
vim.cmd("PairActions")
api.nvim_buf_set_lines(source_buf, 0, 1, false, { "local alpha = 2" })
choose("insert")
assert(table.concat(notices, "\n"):find("Source buffer changed", 1, true),
  "picker must reject a stale cursor target")

local first = assert(sessions.current(root, "mock"))
vim.cmd("PairActions")
choose("new")
local second = assert(sessions.current(root, "mock"))
assert(second.id ~= first.id, "New chat should create a new record")
vim.cmd("PairActions")
choose("resume")
assert(picked.opts.prompt:find("sessions", 1, true), "Resume chat should open the session picker")
local earlier
for _, item in ipairs(picked.items) do if item.id == first.id then earlier = item end end
assert(earlier, "earlier conversation should be listed")
picked.callback(earlier)
assert(vim.wait(4000, function() return sessions.current(root, "mock").id == first.id end, 20),
  "Resume chat should restore the chosen session")

source()
vim.cmd("PairActions")
choose("backend")
assert(picked.opts.prompt:find("backends", 1, true), "Switch backend should open backend picker")
local other
for _, item in ipairs(picked.items) do if item.name == "other" then other = item end end
assert(other, "other backend should be listed")
picked.callback(other)
assert(vim.wait(4000, function()
  local record = sessions.current(root, "other")
  if not record then return false end
  local entries = sessions.read_transcript(record)
  for _, entry in ipairs(entries or {}) do
    if entry.text:find("Using other", 1, true) then return true end
  end
end, 20), "Switch backend should connect to the selected backend")

pair.chat()
vim.cmd("stopinsert")
press("gP")
assert(picked.opts.prompt == "Pair actions:" and not picked.items[2].available,
  "the chat-pane mapping should open actions with editor selection unavailable")
picked.callback(nil)

for _, name in ipairs({ "mock", "other" }) do
  local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. "." .. name
  vim.fn.delete(base .. ".records", "rf")
  vim.fn.delete(base .. ".sessions.json")
end
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair action picker tests passed")
