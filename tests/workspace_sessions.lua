vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root_a, root_b, trace = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root_a, "p")
vim.fn.mkdir(root_b, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root_a))
root_a = vim.fn.getcwd()

local pair = require("pair")
local sessions = require("pair.sessions")
pair.setup({
  backend = "mock", keymaps = false,
  agents = {
    mock = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
      env = { PAIR_MOCK_TRACE = trace }, required_mode = "plan", restricted = true },
    another = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
      env = { PAIR_MOCK_TRACE = trace }, required_mode = "plan", restricted = true },
  },
})

local function messages(record)
  local entries = vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))
  local result = {}
  for _, entry in ipairs(entries) do
    if entry.role == "You" then result[#result + 1] = entry.text end
  end
  return table.concat(result, " | ")
end

local function completed_replies(record)
  local entries = vim.json.decode(table.concat(vim.fn.readfile(record.transcript), "\n"))
  local count = 0
  for _, entry in ipairs(entries) do
    if entry.role == "Agent" and entry.text == "hello world" then count = count + 1 end
  end
  return count
end

local function trace_count(method)
  if vim.fn.filereadable(trace) == 0 then return 0 end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(trace)) do
    if line == method then count = count + 1 end
  end
  return count
end

local function send_and_wait(message, prompt_count, reply_count, backend)
  backend = backend or "mock"
  pair.send(message)
  assert(vim.wait(4000, function()
    local record = assert(sessions.current(vim.fn.getcwd(), backend))
    return trace_count("session/prompt") >= prompt_count
      and vim.fn.filereadable(record.session) == 1
      and completed_replies(record) >= reply_count
  end), "agent should receive message " .. message)
end

send_and_wait("workspace A first", 1, 1)
local a = assert(sessions.current(root_a, "mock"))
assert(messages(a):find("workspace A first", 1, true))

vim.cmd("cd " .. vim.fn.fnameescape(root_b))
root_b = vim.fn.getcwd()
send_and_wait("workspace B only", 2, 1)
local b = assert(sessions.current(root_b, "mock"))
assert(a.transcript ~= b.transcript and messages(b):find("workspace B only", 1, true)
  and not messages(b):find("workspace A first", 1, true),
  "changing workspaces should use a different transcript and agent pointer")

vim.cmd("cd " .. vim.fn.fnameescape(root_a))
send_and_wait("workspace A again", 3, 2)
assert(trace_count("session/load") >= 1 and messages(a):find("workspace A first", 1, true)
  and messages(a):find("workspace A again", 1, true)
  and not messages(a):find("workspace B only", 1, true),
  "returning to a workspace should restore its previous conversation")

pair.backend("another")
send_and_wait("other backend only", 4, 1, "another")
local other = assert(sessions.current(root_a, "another"))
assert(messages(other):find("other backend only", 1, true)
  and not messages(other):find("workspace A first", 1, true),
  "backend switch should keep a separate conversation")
pair.backend("mock")
assert(assert(sessions.current(root_a, "mock")).id == a.id
  and messages(a):find("workspace A again", 1, true),
  "switching back should retain the earlier backend record")

for _, item in ipairs({ { root_a, "mock" }, { root_b, "mock" }, { root_a, "another" } }) do
  local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(item[1]) .. "." .. item[2]
  vim.fn.delete(base .. ".records", "rf")
  vim.fn.delete(base .. ".sessions.json")
end
vim.fn.delete(trace)
vim.fn.delete(root_a, "rf")
vim.fn.delete(root_b, "rf")
print("Pair workspace session isolation tests passed")
