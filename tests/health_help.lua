local plugin_root = vim.fn.getcwd()
vim.opt.rtp:append(plugin_root)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()

local pair = require("pair")
local health = require("pair.health")
local sessions = require("pair.sessions")
local index = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".missing.sessions.json"
local secret = "unit-secret-token"

local methods = { "start", "ok", "warn", "error", "info" }
local original, reports = {}, {}
for _, method in ipairs(methods) do
  original[method] = vim.health[method]
  vim.health[method] = function(message)
    reports[#reports + 1] = { kind = method, message = message }
  end
end
local function report_contains(kind, needle)
  for _, report in ipairs(reports) do
    if report.kind == kind and report.message:find(needle, 1, true) then return true end
  end
  return false
end
health.check()
assert(report_contains("warn", "setup() has not run"), "health should explain missing setup")
assert(vim.fn.filereadable(index) == 0, "health must not create a session record")

pair.setup({ backend = "missing", keymaps = false, agents = { missing = {
  kind = "acp", command = root .. "/missing-agent", args = {},
  env = { PRIVATE_TOKEN = secret }, required_mode = "plan", restricted = true,
} } })
reports = {}
health.check()
assert(report_contains("ok", "setup() has run"), "health should find Pair setup")
assert(report_contains("error", "executable is missing"), "health should identify a missing CLI")
assert(report_contains("info", "No saved Pair sessions"), "health should explain empty session state")
assert(vim.fn.filereadable(index) == 0, "checking health must remain read-only")

local record = assert(sessions.current(root, "missing"))
assert(sessions.save_transcript(record.transcript, { { role = "You", text = secret } }))
reports = {}
health.check()
assert(report_contains("warn", "no agent session pointer"),
  "health should identify a transcript that cannot be resumed")
for _, report in ipairs(reports) do
  assert(not report.message:find(secret, 1, true), "health must not expose config or transcript secrets")
end

vim.fn.writefile({ "invalid json" }, index)
reports = {}
health.check()
assert(report_contains("error", "session index is invalid"), "health should explain damaged metadata")

for _, method in ipairs(methods) do vim.health[method] = original[method] end
vim.cmd("checkhealth pair")
assert(vim.wait(2000, function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return table.concat(lines, "\n"):find("Pair.nvim", 1, true) ~= nil
end, 20), ":checkhealth pair should discover the health module")
vim.cmd("help pair")
assert(vim.api.nvim_buf_get_name(0) == plugin_root .. "/doc/pair.txt",
  ":help pair should resolve from shipped tags")

local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".missing"
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(root, "rf")
print("Pair health and help tests passed")
