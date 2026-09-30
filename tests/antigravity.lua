vim.opt.rtp:append(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
local script = vim.fn.getcwd() .. "/tests/mock_antigravity.py"
local fake = root .. "/bin/agy"
vim.fn.writefile(vim.fn.readfile(script), fake)
vim.fn.setfperm(fake, "rwxr-xr-x")
local trace = root .. "/launch.jsonl"
local previous_path, previous_key, previous_trace = vim.env.PATH,
  vim.env.GEMINI_API_KEY, vim.env.PAIR_AGY_TRACE
vim.env.PATH = root .. "/bin:" .. previous_path
vim.env.GEMINI_API_KEY = "mock-key"
vim.env.PAIR_AGY_TRACE = trace
local Client = require("pair.antigravity")
local session_file = root .. "/session"
local updates, errors = {}, {}
local function open()
  local client = Client.new({ command = "agy", cwd = root, session_file = session_file,
    on_update = function(update) updates[#updates + 1] = update end,
    on_error = function(err) errors[#errors + 1] = err end })
  local started
  client:start(function(session, err) started = { session = session, err = err } end)
  assert(vim.wait(3000, function() return started ~= nil end, 20))
  assert(started.session and not started.err)
  return client, started.session
end
local first = open()
local finished
first:prompt("pair-test-read", function(result, err) finished = { result = result, err = err } end)
assert(vim.wait(3000, function() return finished ~= nil end, 20))
assert(finished.result.stopReason == "end_turn" and not finished.err)
assert(vim.fn.readfile(session_file)[1] == "12345678-1234-1234-1234-123456789abc")
assert(updates[1].name == "view_file" and updates[2].content.text == "read complete")
first:stop()

local second, resumed = open()
assert(resumed.sessionId == "12345678-1234-1234-1234-123456789abc")
finished = nil
second:prompt("pair-test-write", function(result, err) finished = { result = result, err = err } end)
assert(vim.wait(3000, function() return finished ~= nil end, 20))
assert(finished.err.message:find("outside Pair's inspection set", 1, true))
second:stop()
local launch = vim.json.decode(vim.fn.readfile(trace)[1])
assert(vim.tbl_contains(launch.args, "pair-nvim-readonly"))
assert(vim.tbl_contains(launch.args, "--disable-slash-commands"))
local settings = vim.json.decode(table.concat(vim.fn.readfile(
  launch.home .. "/antigravity-cli/settings.json"), "\n"))
for _, rule in ipairs({ "write_file(*)", "command(*)", "mcp(*)", "read_url(*)",
  "execute_url(*)" }) do
  assert(vim.tbl_contains(settings.permissions.deny, rule))
end
assert(settings.trustedWorkspaces[1] == root)
assert(vim.fn.filereadable(launch.home .. "/config/agents/pair-nvim-readonly.md") == 1)
local second_launch = vim.json.decode(vim.fn.readfile(trace)[2])
assert(vim.tbl_contains(second_launch.args, "--conversation"))
vim.fn.delete(launch.home, "rf")
vim.env.PATH, vim.env.GEMINI_API_KEY, vim.env.PAIR_AGY_TRACE = previous_path,
  previous_key, previous_trace
vim.fn.delete(root, "rf")
print("Pair Antigravity client tests passed")
