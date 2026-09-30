vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root = vim.fn.tempname()
local trace = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()

local pair = require("pair")
pair.setup({
  backend = "mock",
  keymaps = true,
  agents = {
    mock = {
      kind = "acp",
      command = "python3",
      args = { plugin_root .. "/tests/mock_acp.py" },
      env = { PAIR_MOCK_TRACE = trace },
      required_mode = "plan",
      restricted = true,
    },
  },
})

local sessions = require("pair.sessions")
local state_base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".mock"
local function trace_count(method)
  local file = io.open(trace, "r")
  if not file then return 0 end
  local count = 0
  for line in file:lines() do
    if line == method then count = count + 1 end
  end
  file:close()
  return count
end
local function chat_text()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == "pair://chat" then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end

pair.send("hello")
assert(vim.wait(3000, function() return chat_text():find("hello world", 1, true) ~= nil end),
  "first chat should finish")
local first = assert(sessions.current(root, "mock"))
assert(vim.wait(3000, function() return vim.fn.filereadable(first.session) == 1 end),
  "first completed chat should save a session")
assert(vim.fn.filereadable(first.session) == 1, "first chat should save a session")

pair.send("cancel me")
assert(vim.wait(3000, function() return trace_count("session/prompt") == 2 end),
  "second turn should start before reset")
pair.new_session()
assert(chat_text() == "Ask about this project, or select code in the editor.",
  "new session should clear the visible transcript")
local second = assert(sessions.current(root, "mock"))
local records = assert(sessions.list(root, "mock"))
assert(#records == 2 and first.id ~= second.id and records[1].id == first.id
  and records[2].active, "new chat should create a second indexed record")
assert(vim.fn.filereadable(first.session) == 1 and vim.fn.filereadable(second.session) == 0,
  "new chat must preserve the previous agent pointer and start without one")
local first_history = vim.json.decode(table.concat(vim.fn.readfile(first.transcript), "\n"))
assert(#first_history > 0 and first_history[1].text == "hello",
  "new chat must preserve the previous transcript")
local stopped = false
for _, entry in ipairs(first_history) do
  if entry.text:find("Stopped the current request", 1, true) then stopped = true end
end
assert(stopped, "a streaming turn should be marked as stopped in its preserved transcript")
assert(vim.json.decode(table.concat(vim.fn.readfile(second.transcript), "\n"))[1] == nil,
  "new chat should start with an empty persisted transcript")

pair.send("hello again")
assert(vim.wait(3000, function() return chat_text():find("hello world", 1, true) ~= nil end),
  "chat should work after restart")
assert(trace_count("session/new") == 2 and trace_count("session/load") == 0,
  "restart should create a fresh ACP session")
assert(vim.wait(3000, function() return vim.fn.filereadable(second.session) == 1 end),
  "second completed chat should save its session")
assert(vim.fn.filereadable(second.session) == 1,
  "second record should gain its own agent pointer")
assert(chat_text():find("hello again", 1, true) and not chat_text():find("cancel me", 1, true),
  "old conversation should not appear in the new chat")

local edit = require("pair.edit")
local source_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then source_win = win end
end
assert(source_win, "source window should remain open")
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_buf_set_name(0, root .. "/sample.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1" })
local target = edit.insertion()
assert(edit.show(target, "-- proposed", nil, "test"), "proposal should be shown")
local previous = chat_text()
local before_blocked = #assert(sessions.list(root, "mock"))
pair.new_session()
assert(#assert(sessions.list(root, "mock")) == before_blocked and chat_text() == previous,
  "new chat should wait for explicit acceptance or rejection of a pending proposal")
assert(edit.reject(), "test proposal should reject cleanly")

vim.fn.delete(state_base .. ".records", "rf")
vim.fn.delete(state_base .. ".sessions.json")
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair session tests passed")
