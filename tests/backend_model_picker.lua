vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root, trace = vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()

local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local pair = require("pair")
local sessions = require("pair.sessions")
pair.setup({
  backend = "mock", keymaps = false,
  agents = {
    mock = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
      env = { PAIR_MOCK_TRACE = trace }, required_mode = "plan", restricted = true },
    other = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
      required_mode = "plan", restricted = true },
    locked = { kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
      env = { PAIR_MOCK_AUTH_FAIL = "1" }, required_mode = "plan", restricted = true },
    absent = { kind = "acp", command = "pair-definitely-missing", args = {}, restricted = true },
  },
})

local function record(name) return assert(sessions.current(root, name or "mock")) end
local function wait_for(test, message)
  assert(vim.wait(4000, test, 20), message)
end

local pick
vim.ui.select = function(items, _, callback)
  pick = { items = items, callback = callback }
end

pair.pick_backend()
assert(pick and #pick.items >= 3, "backend picker should show available backends")
local missing
for _, choice in ipairs(pick.items) do
  if choice.name == "absent" then missing = choice end
end
assert(missing and not missing.installed, "missing CLI should be identified")
pick.callback(missing)
wait_for(function() return table.concat(notices, "\n"):find("missing: pair-definitely-missing", 1, true) end,
  "missing executable should have a useful error")

pair.pick_backend()
local locked
for _, choice in ipairs(pick.items) do
  if choice.name == "locked" then locked = choice end
end
pick.callback(locked)
wait_for(function() return table.concat(notices, "\n"):find("Authentication failed for locked", 1, true) end,
  "login failure should be explained")
assert(not sessions.read_model(record()), "failed backend switch should preserve current conversation")

pair.model()
wait_for(function() return pick and pick.items[1] and pick.items[1].value ~= nil end,
  "model picker should show agent-supplied choices")
local alternate
for _, choice in ipairs(pick.items) do
  if choice.value == "mock/model" then alternate = choice end
end
assert(alternate, "ACP alternative should be offered")
pick.callback(alternate)
wait_for(function() return sessions.read_model(record()) == "mock/model" end,
  "selected model should be saved in the current conversation")
pair.model("mock/unsupported")
wait_for(function() return table.concat(notices, "\n"):find("Model is not available", 1, true) end,
  "unsupported model should explain the problem")
assert(sessions.read_model(record()) == "mock/model", "unsupported model should not alter selection")

pair.pick_backend()
local other_choice
for _, choice in ipairs(pick.items) do
  if choice.name == "other" then other_choice = choice end
end
pick.callback(other_choice)
wait_for(function()
  local entries = sessions.read_transcript(record("other"))
  for _, entry in ipairs(entries or {}) do
    if entry.text:find("Using other", 1, true) then return true end
  end
  return false
end, "backend picker should connect before switching")
assert(sessions.read_model(record("other")) == nil, "other backend must not inherit the model")
pair.backend("mock")
pair.model()
wait_for(function()
  local lines = vim.fn.filereadable(trace) == 1 and vim.fn.readfile(trace) or {}
  local selected = 0
  for _, line in ipairs(lines) do
    if line == "session/set_config_option" then selected = selected + 1 end
  end
  return selected >= 2
end, "returning to conversation should restore its selected model")

for _, name in ipairs({ "mock", "other", "absent", "locked" }) do
  local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. "." .. name
  vim.fn.delete(base .. ".records", "rf")
  vim.fn.delete(base .. ".sessions.json")
end
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair backend/model picker tests passed")
