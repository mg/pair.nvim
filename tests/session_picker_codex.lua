vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root, trace = vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local prior_trace = vim.env.PAIR_MOCK_CODEX_TRACE
local prior_failure = vim.env.PAIR_MOCK_FAIL_RESUME
local prior_delay = vim.env.PAIR_MOCK_RESUME_DELAY
vim.env.PAIR_MOCK_CODEX_TRACE = trace

local api = vim.api
local pair = require("pair")
local sessions = require("pair.sessions")
pair.setup({ command = plugin_root .. "/tests/mock_codex.py", keymaps = false })

local function trace_count(method)
  if vim.fn.filereadable(trace) == 0 then return 0 end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(trace)) do if line == method then count = count + 1 end end
  return count
end

local function replies(record)
  local count = 0
  for _, entry in ipairs(vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))) do
    if entry.role == "Agent" and entry.text == "mock codex reply" then count = count + 1 end
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
        return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), " ")
          :find("Ready", 1, true) ~= nil
      end
    end
  end), "Codex mock should finish " .. message)
end

local first = assert(sessions.current(root, "codex"))
send_and_wait("first Codex chat", first, 1)
pair.new_session()
local second = assert(sessions.current(root, "codex"))
send_and_wait("second Codex chat", second, 1)

local original_select = vim.ui.select
local options, choose
vim.ui.select = function(items, _, callback) options, choose = items, callback end
local original_notify = vim.notify
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end

vim.env.PAIR_MOCK_FAIL_RESUME = "1"
pair.pick_session()
choose(options[2])
assert(vim.wait(4000, function()
  for _, notice in ipairs(notices) do
    if notice:find("mock Codex restore failed", 1, true) then return true end
  end
end), "failed Codex resume should be reported")
assert(assert(sessions.current(root, "codex")).id == second.id,
  "failed Codex restore must keep the current conversation active")

vim.env.PAIR_MOCK_FAIL_RESUME = nil
pair.pick_session()
choose(options[2])
assert(vim.wait(4000, function() return assert(sessions.current(root, "codex")).id == first.id end),
  "Codex thread/resume should activate its saved record")
assert(trace_count("thread/resume") == 2,
  "Pair should verify Codex restoration before switching the transcript")
send_and_wait("first Codex follow-up", first, 2)
assert(replies(second) == 1, "resumed Codex turn should not enter another transcript")

vim.env.PAIR_MOCK_RESUME_DELAY = "0.3"
pair.pick_session()
choose(options[1])
pair.cancel()
vim.wait(500)
assert(assert(sessions.current(root, "codex")).id == first.id,
  "cancelling an in-progress restore should keep the current record")
send_and_wait("after cancelled restore", first, 3)

vim.notify = original_notify
vim.ui.select = original_select
vim.env.PAIR_MOCK_CODEX_TRACE = prior_trace
vim.env.PAIR_MOCK_FAIL_RESUME = prior_failure
vim.env.PAIR_MOCK_RESUME_DELAY = prior_delay
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root)
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair Codex session picker tests passed")
