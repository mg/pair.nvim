vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root, trace = vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()

local api = vim.api
local pair = require("pair")
local sessions = require("pair.sessions")
pair.setup({
  backend = "mock", keymaps = true,
  agents = { mock = {
    kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_TRACE = trace }, required_mode = "plan", restricted = true,
  } },
})

local function trace_count(method)
  if vim.fn.filereadable(trace) == 0 then return 0 end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(trace)) do if line == method then count = count + 1 end end
  return count
end

local function entries(record)
  return vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))
end

local function replies(record)
  local count = 0
  for _, entry in ipairs(entries(record)) do
    if entry.role == "Agent" and entry.text == "hello world" then count = count + 1 end
  end
  return count
end

local function send_and_wait(message, record, count)
  pair.send(message)
  assert(vim.wait(4000, function()
    if replies(record) < count then return false end
    for _, win in ipairs(api.nvim_list_wins()) do
      local buf = api.nvim_win_get_buf(win)
      if api.nvim_buf_get_name(buf) == "pair://header" then
        return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), " "):find("Ready", 1, true) ~= nil
      end
    end
  end),
    "expected completed reply for " .. message)
end

local function chat_text()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf) == "pair://chat" then
      return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end

local first = assert(sessions.current(root, "mock"))
send_and_wait("first conversation", first, 1)
pair.new_session()
local second = assert(sessions.current(root, "mock"))
send_and_wait("second conversation", second, 1)

local original_select = vim.ui.select
local options, choose, prompt
vim.ui.select = function(items, opts, callback)
  options, choose, prompt = items, callback, opts.prompt
end
vim.cmd("PairSessions")
assert(prompt:find("mock", 1, true) and #options == 2
  and options[1].id == second.id and options[2].id == first.id,
  "picker should show newest first and include the active record")
choose(options[2])
assert(vim.wait(4000, function() return assert(sessions.current(root, "mock")).id == first.id end),
  "choosing an older record should activate it after backend restoration")
assert(trace_count("session/load") == 1, "saved ACP session should be loaded before switching")
assert(chat_text():find("first conversation", 1, true)
  and not chat_text():find("second conversation", 1, true),
  "visible transcript must match the restored agent session")
send_and_wait("first follow-up", first, 2)
assert(chat_text():find("first follow-up", 1, true)
  and not chat_text():find("second conversation", 1, true),
  "follow-up should stay in the restored conversation")

vim.cmd("PairSessions")
assert(options[1].id == second.id and options[2].id == first.id,
  "picker should retain stable record ordering")
choose(options[1])
assert(vim.wait(4000, function() return assert(sessions.current(root, "mock")).id == second.id end),
  "second record should become active again")
assert(trace_count("session/load") == 2 and chat_text():find("second conversation", 1, true)
  and not chat_text():find("first follow-up", 1, true),
  "switching back should load its own agent session and transcript")

vim.cmd("PairSessions")
choose(nil)
assert(assert(sessions.current(root, "mock")).id == second.id,
  "dismissing the picker should leave the active session unchanged")

local input_buf
for _, win in ipairs(api.nvim_list_wins()) do
  local buf = api.nvim_win_get_buf(win)
  if api.nvim_buf_get_name(buf) == "pair://input" then input_buf = buf end
end
assert(input_buf, "chat input should be open")
api.nvim_buf_set_lines(input_buf, 0, -1, false, { "unsent draft" })
vim.cmd("PairSessions")
choose(options[2])
assert(assert(sessions.current(root, "mock")).id == second.id
  and api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "unsent draft",
  "switching sessions should not move or discard an unsent draft")
api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

pair.new_session()
local empty_a = assert(sessions.current(root, "mock"))
pair.new_session()
local empty_b = assert(sessions.current(root, "mock"))
local loaded_before, created_before = trace_count("session/load"), trace_count("session/new")
vim.cmd("PairSessions")
assert(options[1].id == empty_b.id and options[2].id == empty_a.id,
  "picker should include new conversations that have not started an agent")
choose(options[2])
assert(assert(sessions.current(root, "mock")).id == empty_a.id
  and trace_count("session/load") == loaded_before
  and trace_count("session/new") == created_before,
  "an empty record can be selected without inventing an agent session")
send_and_wait("first message in empty record", empty_a, 1)
assert(trace_count("session/new") == created_before + 1,
  "first message after selecting an empty record should create its agent session")

vim.ui.select = original_select
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".mock"
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair session picker tests passed")
