vim.opt.rtp:append(vim.fn.getcwd())
local plugin = vim.fn.getcwd()
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local state = root .. "/state"
local child = root .. "/check.lua"
-- Use separate Neovim processes to verify real startup, not module reloads.
vim.fn.writefile(vim.split([[
vim.opt.rtp:append(vim.env.PAIR_PREF_PLUGIN)
vim.cmd("cd " .. vim.fn.fnameescape(vim.env.PAIR_PREF_PROJECT))
local phase = vim.env.PAIR_PREF_PHASE
local prefs = require("pair.preferences")
local pair = require("pair")
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local agents = {
  mock = { kind = "acp", command = "python3", args = { vim.env.PAIR_PREF_PLUGIN .. "/tests/mock_acp.py" },
    restricted = true, required_mode = "plan" },
  other = { kind = "acp", command = "python3", args = { vim.env.PAIR_PREF_PLUGIN .. "/tests/mock_acp.py" },
    restricted = true, required_mode = "plan" },
  missing = { kind = "acp", command = "pair-missing-cli", args = {}, restricted = true },
  locked = { kind = "acp", command = "python3", args = { vim.env.PAIR_PREF_PLUGIN .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_AUTH_FAIL = "1" }, restricted = true, required_mode = "plan" },
}
pair.setup({ backend = phase == "write" and "mock" or "other", agents = agents, keymaps = false,
  remember_selection = phase ~= "disabled" })
local function wait(test) assert(vim.wait(4000, test, 10), "preference operation timed out") end
local sessions = require("pair.sessions")
local function record() return assert(sessions.current(vim.fn.getcwd(), "mock")) end
if phase == "write" then
  pair.model("mock/model")
  wait(function() return prefs.read().models.mock == "mock/model" end)
  pair.new_session()
  local selected
  vim.ui.select = function(items, opts)
    for _, item in ipairs(items) do
      if opts.format_item(item):sub(1, 3) == "●" then selected = item.value end
    end
  end
  pair.model()
  wait(function() return selected ~= nil end)
  assert(selected == "mock/model", ":PairNew reset the selected model")
  pair.backend("other")
  pair.model("mock/default")
  wait(function() return prefs.read().backend == "other" and prefs.read().models.other == "mock/default" end)
  pair.backend("mock")
  assert(prefs.read().backend == "mock" and prefs.read().models.mock == "mock/model",
    "backend switch forgot that backend's model")
  local before = assert(prefs.read())
  pair.backend("missing")
  assert(vim.deep_equal(before, prefs.read()), "failed switch changed saved preferences")
  local chosen
  vim.ui.select = function(items, _, cb)
    for _, item in ipairs(items) do if item.name == "locked" then chosen = true; cb(item); return end end
  end
  pair.pick_backend()
  wait(function() return table.concat(notices, " "):find("Authentication failed", 1, true) end)
  assert(chosen and vim.deep_equal(before, prefs.read()), "failed picker changed preferences")
  pair.model("unsupported")
  wait(function() return table.concat(notices, " "):find("Model is not available", 1, true) end)
  assert(vim.deep_equal(before, prefs.read()), "failed model changed preferences")
elseif phase == "read" then
  assert(pair.health_info().backend == "mock", "startup forgot the last backend")
  local selected
  vim.ui.select = function(items, opts)
    for _, item in ipairs(items) do
      if opts.format_item(item):sub(1, 3) == "●" then selected = item.value end
    end
  end
  pair.model()
  wait(function() return selected ~= nil end)
  assert(selected == "mock/model", "startup forgot the last model")
  pair.new_session()
  pair.model("mock/model")
  wait(function() return sessions.read_model(record()) == "mock/model" end)
elseif phase == "disabled" then
  assert(pair.health_info().backend == "other", "disabled persistence overrode setup")
  local before = assert(prefs.read())
  pair.model("mock/model")
  wait(function() return sessions.read_model(assert(sessions.current(vim.fn.getcwd(), "other"))) == "mock/model" end)
  assert(vim.deep_equal(before, prefs.read()), "disabled persistence wrote preferences")
elseif phase == "corrupt" then
  assert(pair.health_info().backend == "other", "corrupt preference did not use setup defaults")
  assert(table.concat(notices, " "):find("invalid", 1, true), "corruption should be explained")
elseif phase == "removed" then
  assert(pair.health_info().backend == "other", "missing backend should use setup defaults")
  assert(table.concat(notices, " "):find("no longer configured", 1, true))
end
]], "\n", { plain = true }), child)
local function run(phase)
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", child }, {
    env = { XDG_STATE_HOME = state, PAIR_PREF_PLUGIN = plugin,
      PAIR_PREF_PROJECT = root, PAIR_PREF_PHASE = phase }, text = true,
  }):wait(15000)
  assert(result.code == 0, phase .. ": " .. (result.stderr or ""))
end
run("write")
local file = state .. "/" .. (vim.env.NVIM_APPNAME or "nvim") .. "/pair/preferences.json"
assert(vim.fn.getfperm(file) == "rw-------", "preferences must be owner-only")
local saved = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
assert(saved.backend == "mock" and saved.models.mock == "mock/model")
assert(saved.models.other == "mock/default", "choices for other backends were overwritten")
run("read")
run("disabled")
vim.fn.writefile({ "invalid json" }, file)
run("corrupt")
vim.fn.writefile({ vim.json.encode({ version = 1, backend = "removed_agent", models = {} }) }, file)
run("removed")
vim.fn.delete(root, "rf")
print("Pair selection persistence tests passed")
