vim.opt.rtp:append(vim.fn.getcwd())
local api = vim.api
local plugin_root = vim.fn.getcwd()
local root = vim.fn.tempname()
local trace = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.cmd("edit sample.lua")
local source_buf = api.nvim_get_current_buf()
local source_win = api.nvim_get_current_win()
api.nvim_buf_set_lines(source_buf, 0, -1, false, { "local original = true" })
local original = api.nvim_buf_get_lines(source_buf, 0, -1, false)
local pair = require("pair")
pair.setup({ backend = "mock", keymaps = false, agents = { mock = {
  kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
  env = { PAIR_MOCK_TRACE = trace, PAIR_MOCK_START_DELAY = "0.4" },
  required_mode = "plan", restricted = true,
} } })
local function chat_text()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf) == "pair://chat" then
      return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end
local function header()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf) == "pair://header" then
      return api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end
  end
  return ""
end
local function trace_count(method)
  if vim.fn.filereadable(trace) == 0 then return 0 end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(trace)) do
    if line == method then count = count + 1 end
  end
  return count
end
local function wait_for(fn, message, timeout)
  assert(vim.wait(timeout or 3000, fn, 10), message .. "\n" .. chat_text())
end

pair.send("startup request")
wait_for(function() return header():find("Connecting", 1, true) or header():find("Start", 1, true) end,
  "startup should show connecting")
pair.cancel()
wait_for(function() return chat_text():find("Startup cancelled", 1, true) end,
  "startup cancellation should explain how to retry")
vim.wait(500)
assert(trace_count("session/prompt") == 0, "cancelled startup must not send a late turn")

pair.send("ready after startup cancellation")
wait_for(function() return chat_text():find("hello world", 1, true) end,
  "a new message should recover after startup cancellation")
api.nvim_set_current_win(source_win)
pair.here("late edit")
wait_for(function() return chat_text():find("Read for late edit", 1, true) end,
  "edit should start streaming before cancellation")
pair.send("queued after edit")
local prompts_before_cancel = trace_count("session/prompt")
pair.cancel()
wait_for(function() return chat_text():find("Request cancelled", 1, true) end,
  "late edit should resolve as cancelled")
vim.wait(400)
assert(trace_count("session/prompt") == prompts_before_cancel,
  "cancellation should discard the queued request")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), original),
  "late edit output must not change the source buffer")
assert(not require("pair.edit").pending(), "late edit must not leave a proposal")
assert(not chat_text():find("Proposal applied", 1, true), "late success must not become a proposal")

pair.send("fail turn")
wait_for(function() return chat_text():find("Read before failure", 1, true) end,
  "failed turn should start")
pair.send("queued after failure")
local prompts_before_failure = trace_count("session/prompt")
wait_for(function() return chat_text():find("mock turn failure", 1, true) end,
  "failed turn should show its error and next action")
vim.wait(100)
assert(trace_count("session/prompt") == prompts_before_failure,
  "a failed turn should discard queued work")
assert(chat_text():find("Send another message to retry", 1, true),
  "failure should suggest a retry")

pair.send("agent cancels")
wait_for(function() return chat_text():find("Read before agent", 1, true) end,
  "agent-initiated cancellation should begin")
pair.send("queued after agent cancellation")
local prompts_before_agent_cancel = trace_count("session/prompt")
wait_for(function() return chat_text():find("Request cancelled", 1, true)
  and select(2, chat_text():gsub("Request cancelled", "")) >= 2 end,
  "agent-initiated cancellation should resolve")
assert(trace_count("session/prompt") == prompts_before_agent_cancel,
  "agent-initiated cancellation should discard queued work")

pair.send("stuck cancel")
wait_for(function() return chat_text():find("partial", 1, true) end,
  "stuck backend should stream before cancellation")
pair.cancel()
assert(pair.send("sent during cancellation") == false,
  "a message submitted during cancellation should keep its draft for retry")
wait_for(function() return select(2, chat_text():gsub("Request cancelled", "")) >= 3 end,
  "unresponsive backend should time out cancellation", 4000)
assert(header():find("Reconn", 1, true),
  "a disconnected saved session should show that it will reconnect: " .. header())
local replies_before_retry = select(2, chat_text():gsub("hello world", ""))
pair.send("after timeout")
wait_for(function() return select(2, chat_text():gsub("hello world", "")) > replies_before_retry end,
  "next message should resume after forced cancellation")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), original),
  "recovery should leave the source buffer untouched")

api.nvim_set_current_win(source_win)
pair.here("late edit")
wait_for(function() return chat_text():find("Read for late edit", 1, true)
  and select(2, chat_text():gsub("Read for late edit", "")) >= 2 end,
  "another edit should start before new-chat reset")
pair.new_session()
vim.wait(400)
assert(chat_text() == "Ask about this project, or select code in the editor.",
  "new chat should suppress late output from the old streaming turn")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), original),
  "new chat during streaming must not apply late code")

local prompts_before_reset = trace_count("session/prompt")
pair.send("startup reset")
pair.new_session()
vim.wait(500)
assert(trace_count("session/prompt") == prompts_before_reset,
  "new chat during startup should suppress a late prompt")
assert(chat_text() == "Ask about this project, or select code in the editor.",
  "new chat during startup should keep a clear transcript")

pair.new_session()
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair cancellation and recovery tests passed")
