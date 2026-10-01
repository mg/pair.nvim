vim.opt.rtp:append(vim.fn.getcwd())
if not require("pair.command_sandbox").available() then
  print("Antigravity requires a filesystem sandbox; unavailable on this host")
  return
end
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
local script = vim.fn.getcwd() .. "/tests/mock_antigravity.py"
local fake = root .. "/bin/agy"
vim.fn.writefile(vim.fn.readfile(script), fake)
vim.fn.setfperm(fake, "rwxr-xr-x")
vim.fn.mkdir(root .. "/generated", "p")
vim.fn.writefile({ "source unchanged" }, root .. "/source.txt")
local home = vim.fn.stdpath("state") .. "/pair/antigravity/" .. vim.fn.sha256(root)
vim.fn.mkdir(home .. "/scratch", "p")
local trace = home .. "/scratch/launch.jsonl"
local previous_path, previous_key, previous_trace = vim.env.PATH,
  vim.env.GEMINI_API_KEY, vim.env.PAIR_AGY_TRACE
vim.env.PATH = root .. "/bin:" .. previous_path
vim.env.GEMINI_API_KEY = "mock-key"
vim.env.PAIR_AGY_TRACE = trace
local Client = require("pair.antigravity")
local session_file = root .. "/session"
local updates, errors = {}, {}
local function open(paths)
  local client = Client.new({ command = "agy", cwd = root, session_file = session_file,
    on_update = function(update) updates[#updates + 1] = update end,
    writable_paths = paths or {},
    on_error = function(err) errors[#errors + 1] = err end })
  local started
  client:start(function(session, err) started = { session = session, err = err } end)
  assert(vim.wait(3000, function() return started ~= nil end, 20))
  assert(started.session and not started.err)
  return client, started.session
end
local first = open({ "generated" })
local finished
first:prompt("pair-test-read", function(result, err) finished = { result = result, err = err } end)
assert(vim.wait(3000, function() return finished ~= nil end, 20))
assert(finished.result.stopReason == "end_turn" and not finished.err)
assert(vim.fn.readfile(session_file)[1] == "12345678-1234-1234-1234-123456789abc")
assert(updates[1].name == "view_file" and updates[2].content.text == "read complete")
for _, prompt in ipairs({ "pair-test-command", "pair-test-write-command", "pair-test-generate" }) do
  updates, finished = {}, nil
  first:prompt(prompt, function(result, err) finished = { result = result, err = err } end)
  assert(vim.wait(3000, function() return finished ~= nil end, 20))
  assert(finished.result and not finished.err, "command failed the conversation")
  assert(updates[1].name == "run_command" and updates[1].kind == "execute")
  assert(updates[1].command and updates[1].title == updates[1].command)
  assert(updates[2].status == (prompt == "pair-test-write-command" and "failed" or "completed"))
end
assert(vim.fn.readfile(root .. "/source.txt")[1] == "source unchanged")
assert(vim.fn.readfile(root .. "/generated/output.txt")[1] == "generated")
first:stop()

local second, resumed = open()
assert(resumed.sessionId == "12345678-1234-1234-1234-123456789abc")
finished = nil
second:prompt("pair-test-write", function(result, err) finished = { result = result, err = err } end)
assert(vim.wait(3000, function() return finished ~= nil end, 20))
assert(finished.err.message:find("outside Pair's research set", 1, true))
second:stop()
local launch = vim.json.decode(vim.fn.readfile(trace)[1])
assert(vim.tbl_contains(launch.args, "pair-nvim-research"))
assert(vim.tbl_contains(launch.args, "--disable-slash-commands"))
local settings = vim.json.decode(table.concat(vim.fn.readfile(
  launch.home .. "/.gemini/antigravity-cli/settings.json"), "\n"))
for _, rule in ipairs({ "write_file(*)", "mcp(*)", "read_url(*)",
  "execute_url(*)" }) do
  assert(vim.tbl_contains(settings.permissions.deny, rule))
end
assert(vim.tbl_contains(settings.permissions.allow, "command(*)"))
assert(vim.tbl_contains(settings.permissions.allow, "unsandboxed(*)"))
assert(settings.trustedWorkspaces[1] == root)
assert(launch.gemini_home == launch.home .. "/.gemini")
local shared = vim.json.decode(table.concat(vim.fn.readfile(
  launch.home .. "/.gemini/config/config.json"), "\n"))
assert(vim.deep_equal(shared.userSettings.globalPermissionGrants, settings.permissions))
assert(shared.userSettings.permissionGrantsV2Migrated == true)
assert(vim.fn.filereadable(launch.home .. "/.gemini/config/agents/pair-nvim-research.md") == 1)
local second_launch = vim.json.decode(vim.fn.readfile(trace)[2])
assert(vim.tbl_contains(second_launch.args, "--conversation"))
vim.fn.delete(launch.home, "rf")
vim.env.PATH, vim.env.GEMINI_API_KEY, vim.env.PAIR_AGY_TRACE = previous_path,
  previous_key, previous_trace
vim.fn.delete(root, "rf")
print("Pair Antigravity client tests passed")
