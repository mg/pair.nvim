-- Opt-in Copilot ACP handshake. No model prompt is sent.
vim.opt.rtp:append(vim.fn.getcwd())

local spec = assert(require("pair.backends").resolve("copilot", {
  command = "codex", agents = {}, models = {},
}))
spec.command = vim.env.PAIR_LIVE_COPILOT or spec.command
local ACP = require("pair.acp")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local session_file = root .. "/pair.session"
local report = { backend = "copilot", adapter = spec.command }

local function open_session()
  local client = ACP.new({
    command = spec.command, args = spec.args, env = spec.env,
    session_meta = spec.session_meta, required_mode = spec.required_mode,
    allowed_tool_names = spec.allowed_tool_names,
    allowed_tool_kinds = spec.allowed_tool_kinds,
    cwd = root, session_file = session_file,
    on_update = function() end, on_error = function() end,
  })
  local result
  client:start(function(session, err) result = { session = session, err = err } end)
  assert(vim.wait(40000, function() return result ~= nil end, 50), "Copilot ACP startup timed out")
  return client, result
end

local ok, failure = pcall(function()
  local first, created = open_session()
  assert(created.session, vim.inspect(created.err))
  report.new = true
  report.session_id = created.session.sessionId
  assert(vim.fn.filereadable(session_file) == 0,
    "empty ACP session should not save an unresumable pointer")
  first:stop()

  local second, created_again = open_session()
  assert(created_again.session, vim.inspect(created_again.err))
  report.second_new = created_again.session.sessionId ~= report.session_id
  second:stop()
end)
if not ok then report.error = tostring(failure) end
vim.fn.delete(root, "rf")
print(vim.json.encode(report))
assert(ok, tostring(failure))
