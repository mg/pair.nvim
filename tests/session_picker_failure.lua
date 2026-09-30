vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root, trace = vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()

local pair = require("pair")
local sessions = require("pair.sessions")
pair.setup({
  backend = "mock", keymaps = false,
  agents = { mock = {
    kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_TRACE = trace, PAIR_MOCK_NO_LOAD = "1" },
    required_mode = "plan", restricted = true,
  } },
})

local function replies(record)
  local result = 0
  for _, entry in ipairs(vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))) do
    if entry.role == "Agent" and entry.text == "hello world" then result = result + 1 end
  end
  return result
end

local function send_and_wait(message, record, count)
  pair.send(message)
  assert(vim.wait(4000, function()
    if replies(record) < count then return false end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf) == "pair://header" then
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), " ")
          :find("Ready", 1, true) ~= nil
      end
    end
  end),
    "expected reply for " .. message)
end

local first = assert(sessions.current(root, "mock"))
send_and_wait("old topic", first, 1)
pair.new_session()
local second = assert(sessions.current(root, "mock"))
send_and_wait("current topic", second, 1)

local original_select = vim.ui.select
local options, choose
vim.ui.select = function(items, _, callback) options, choose = items, callback end
local notices = {}
local original_notify = vim.notify
vim.notify = function(message)
  notices[#notices + 1] = message
end
pair.pick_session()
choose(options[2])
assert(vim.wait(4000, function()
  for _, notice in ipairs(notices) do
    if notice:find("cannot restore", 1, true) then return true end
  end
end), "unsupported ACP session loading should explain the failure")
assert(assert(sessions.current(root, "mock")).id == second.id,
  "failed agent restoration must not activate the old transcript")
send_and_wait("current follow-up", second, 2)

vim.fn.delete(first.session)
pair.pick_session()
choose(options[2])
local no_pointer = false
for _, notice in ipairs(notices) do
  if notice:find("no saved agent session", 1, true) then no_pointer = true end
end
assert(no_pointer and assert(sessions.current(root, "mock")).id == second.id,
  "a transcript without an agent pointer must not be presented as resumable")

vim.notify = original_notify
vim.ui.select = original_select
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".mock"
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair session picker failure tests passed")
