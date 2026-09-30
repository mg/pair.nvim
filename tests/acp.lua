vim.opt.rtp:append(vim.fn.getcwd())

local ACP = require("pair.acp")
local backends = require("pair.backends")
local root = vim.fn.getcwd()
local session_file = vim.fn.tempname()
local updates = {}
local args = {
  command = "python3",
  args = { root .. "/tests/mock_acp.py" },
  model = "mock/model",
  required_mode = "plan",
  cwd = root,
  session_file = session_file,
  on_update = function(update) updates[#updates + 1] = update end,
  on_error = function(message) error(message) end,
}

local client = ACP.new(args)
local started
client:start(function(result, err) started = { result = result, err = err } end)
assert(vim.wait(3000, function() return started ~= nil end), "ACP should initialize and create a session")
assert(started.result and started.result.sessionId == "mock-session", vim.inspect(started.err))

local finished
client:prompt("say hello", function(result, err) finished = { result = result, err = err } end)
assert(vim.wait(3000, function() return finished ~= nil end), "ACP prompt should finish")
assert(finished.result and finished.result.stopReason == "end_turn", vim.inspect(finished.err))
assert(#updates == 2 and updates[1].content.text == "hello" and updates[2].content.text == " world",
  "ACP should stream text and deny permission requests")
updates = {}
local tool_finished
client:prompt("status tool", function(result, err) tool_finished = { result = result, err = err } end)
assert(vim.wait(3000, function() return tool_finished ~= nil end), "ACP inspection should finish")
assert(updates[1].sessionUpdate == "tool_call" and updates[1].status == "in_progress"
  and updates[2].sessionUpdate == "tool_call" and updates[2].status == "completed"
  and updates[2].toolCallId == updates[1].toolCallId,
  "ACP tool updates should preserve identity and lifecycle")
local cancelled
client:prompt("cancel me", function(result, err) cancelled = { result = result, err = err } end)
client:cancel()
assert(vim.wait(3000, function() return cancelled ~= nil end), "ACP cancellation should complete")
assert(cancelled.result and cancelled.result.stopReason == "cancelled", vim.inspect(cancelled.err))
client:stop()

local resumed = ACP.new(args)
local resumed_start
resumed:start(function(result, err) resumed_start = { result = result, err = err } end)
assert(vim.wait(3000, function() return resumed_start ~= nil end), "ACP should load a saved session")
assert(resumed_start.result and resumed_start.result.sessionId == "mock-session", vim.inspect(resumed_start.err))
resumed:stop()
vim.fn.delete(session_file)

local wrong_mode = vim.deepcopy(args)
wrong_mode.session_file = vim.fn.tempname()
wrong_mode.required_mode = "build"
local blocked = ACP.new(wrong_mode)
local blocked_start
blocked:start(function(result, err) blocked_start = { result = result, err = err } end)
assert(vim.wait(3000, function() return blocked_start ~= nil end), "unsafe mode check should finish")
assert(blocked_start.err and blocked_start.err.message:find("required build mode", 1, true),
  "ACP must refuse a session outside its required mode")

local modern_args = vim.deepcopy(args)
modern_args.session_file = vim.fn.tempname()
modern_args.env = { PAIR_MOCK_MODES = "modern" }
local modern = ACP.new(modern_args)
local modern_start
modern:start(function(result, err) modern_start = { result = result, err = err } end)
assert(vim.wait(3000, function() return modern_start ~= nil end), "ACP mode selection should finish")
assert(modern_start.result and modern_start.result.sessionId == "mock-session", vim.inspect(modern_start.err))
local unsafe_turn
modern:prompt("leave plan", function(result, err) unsafe_turn = { result = result, err = err } end)
assert(vim.wait(3000, function() return unsafe_turn ~= nil end), "mode escape should stop the turn")
assert(unsafe_turn.err and unsafe_turn.err.message:find("left required plan mode", 1, true),
  "ACP must stop when the agent leaves its required mode")
modern:stop()
vim.fn.delete(modern_args.session_file)

local spec = assert(backends.resolve("copilot", { command = "codex", agents = {} }))
assert(spec.kind == "acp" and spec.args[3] == "--available-tools=view,glob,grep",
  "Copilot must launch with only inspection tools")
local claude = assert(backends.resolve("claude", { command = "codex", agents = {} }))
assert(claude.required_mode == "plan" and claude.command == "claude-agent-acp",
  "Claude must require the adapter's plan mode")
local claude_trace, claude_session = vim.fn.tempname(), vim.fn.tempname()
local claude_args = {
  command = "python3", args = { root .. "/tests/mock_acp.py" },
  env = { PAIR_MOCK_REQUEST_TRACE = claude_trace },
  session_meta = claude.session_meta, required_mode = claude.required_mode,
  allowed_tool_names = claude.allowed_tool_names,
  cwd = root, session_file = claude_session,
  on_update = function() end, on_error = function(message) error(message) end,
}
local claude_mock = ACP.new(claude_args)
local claude_started
claude_mock:start(function(result, err) claude_started = { result = result, err = err } end)
assert(vim.wait(3000, function() return claude_started ~= nil end), "Claude profile should start")
assert(claude_started.result, vim.inspect(claude_started.err))
assert(vim.fn.filereadable(claude_session) == 0,
  "an unprompted ACP session should not leave an unresumable pointer")
local claude_answer
claude_mock:prompt("profile check", function(result, err) claude_answer = { result = result, err = err } end)
assert(vim.wait(3000, function() return claude_answer ~= nil end), "Claude profile mock should answer")
assert(claude_answer.result and vim.fn.filereadable(claude_session) == 1,
  "the first completed ACP turn should save its session")
local unsafe_answer
claude_mock:prompt("unsafe tool", function(result, err) unsafe_answer = { result = result, err = err } end)
assert(vim.wait(3000, function() return unsafe_answer ~= nil end), "unexpected Claude tool should stop")
assert(unsafe_answer.err and unsafe_answer.err.message:find("outside Pair's inspection set", 1, true),
  "Claude tool drift should stop the ACP session")
claude_mock:stop()
local claude_restored = ACP.new(claude_args)
local claude_loaded
claude_restored:start(function(result, err) claude_loaded = { result = result, err = err } end)
assert(vim.wait(3000, function() return claude_loaded ~= nil end), "Claude profile should load")
assert(claude_loaded.result, vim.inspect(claude_loaded.err))
claude_restored:stop()
local profile_calls = {}
for _, line in ipairs(vim.fn.readfile(claude_trace)) do
  local entry = vim.json.decode(line)
  if entry.method == "session/new" or entry.method == "session/load" then
    profile_calls[entry.method] = entry.params
  end
end
for _, method in ipairs({ "session/new", "session/load" }) do
  local params = assert(profile_calls[method], method .. " should carry Claude's profile")
  local options = assert(params._meta.claudeCode.options)
  assert(params.mcpServers and #params.mcpServers == 0
    and options.strictMcpConfig and options.allowDangerouslySkipPermissions == false
    and #options.settingSources == 0 and #options.plugins == 0,
    method .. " should disable external tool and settings sources")
  assert(vim.deep_equal(options.tools, { "Read", "Glob", "Grep" }),
    method .. " should expose inspection tools only")
  for _, name in ipairs({ "Bash", "Write", "Edit", "NotebookEdit", "Agent", "Task",
    "WebFetch", "WebSearch", "Skill" }) do
    assert(vim.tbl_contains(options.disallowedTools, name), method .. " must deny " .. name)
  end
end
vim.fn.delete(claude_trace)
vim.fn.delete(claude_session)
local opencode = assert(backends.resolve("opencode", { command = "codex", agents = {} }))
assert(opencode.required_mode == "plan" and opencode.args[2] == "--pure",
  "OpenCode must start in its restricted plan mode")
local permissions = vim.json.decode(opencode.env.OPENCODE_PERMISSION)
assert(permissions["*"] == "deny" and permissions.read == "allow" and permissions.bash == nil,
  "OpenCode must deny unknown tools and leave shell commands denied")
assert(opencode.env.OPENCODE_PERMISSION:find('^{"%*":"deny","read":"allow"'),
  "OpenCode catch-all deny must precede inspection tool allows")
local gemini = assert(backends.resolve("gemini", { command = "codex", agents = {} }))
assert(gemini.required_mode == "plan" and gemini.args[3] == "plan",
  "Gemini must require plan mode")
assert(not backends.resolve("unrestricted", { agents = {
  unrestricted = { kind = "acp", command = "agent", args = {} },
} }), "custom ACP agent must explicitly declare a restricted tool configuration")

print("Pair ACP tests passed")
