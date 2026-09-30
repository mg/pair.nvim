vim.opt.rtp:append(vim.fn.getcwd())

local api = vim.api
local plugin_root = vim.fn.getcwd()
local root, params_trace, args_trace, method_trace = vim.fn.tempname(), vim.fn.tempname(),
  vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/sample.lua"
vim.fn.writefile({ "disk copy" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, -1, false, {
  "local unsaved = true", "local second = 2", "return second",
})

local env_names = { "PAIR_MOCK_CODEX_PARAMS", "PAIR_MOCK_CODEX_ARGS",
  "PAIR_MOCK_CODEX_TRACE", "PAIR_MOCK_CODEX_MCP" }
local prior = {}
for _, name in ipairs(env_names) do prior[name] = vim.env[name] end
vim.env.PAIR_MOCK_CODEX_PARAMS = params_trace
vim.env.PAIR_MOCK_CODEX_ARGS = args_trace
vim.env.PAIR_MOCK_CODEX_TRACE = method_trace
vim.env.PAIR_MOCK_CODEX_MCP = "read_server"

local pair = require("pair")
local sessions = require("pair.sessions")
local edit = require("pair.edit")
pair.setup({ command = plugin_root .. "/tests/mock_codex.py", keymaps = false })
local record = assert(sessions.current(root, "codex"))

local function wait_for(test, message)
  assert(vim.wait(4000, test, 20), message)
end
local function entries()
  return assert(sessions.read_transcript(record))
end
local function agent_text()
  local texts = {}
  for _, entry in ipairs(entries()) do
    if entry.role == "Agent" then texts[#texts + 1] = entry.text end
  end
  return table.concat(texts, "\n")
end
local function agent_replies()
  local count = 0
  for _, entry in ipairs(entries()) do
    if entry.role == "Agent" and entry.text == "mock codex reply" then count = count + 1 end
  end
  return count
end
local function methods(method)
  if vim.fn.filereadable(method_trace) ~= 1 then return 0 end
  local count = 0
  for _, name in ipairs(vim.fn.readfile(method_trace)) do
    if name == method then count = count + 1 end
  end
  return count
end
local function requests(method)
  local result = {}
  if vim.fn.filereadable(params_trace) ~= 1 then return result end
  for _, line in ipairs(vim.fn.readfile(params_trace)) do
    local item = vim.json.decode(line)
    if item.method == method then result[#result + 1] = item.params end
  end
  return result
end
local function snapshot(index)
  wait_for(function() return #requests("turn/start") >= index end, "missing Codex turn " .. index)
  local prompt = requests("turn/start")[index].input[1].text
  return vim.json.decode(assert(prompt:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>")))
end
local function source() api.nvim_set_current_win(source_win) end

pair.send("mock streaming")
local partial_seen = vim.wait(4000, function()
  local text = agent_text()
  return text:find("mock cod", 1, true) and not text:find("mock codex reply", 1, true)
end, 20)
assert(partial_seen, "Codex output should be visible before the turn completes: " .. vim.inspect(entries())
  .. " methods=" .. vim.inspect(vim.fn.filereadable(method_trace) == 1 and vim.fn.readfile(method_trace) or {}))
wait_for(function() return agent_text():find("mock codex reply", 1, true) end,
  "streamed chat should finish")
local chat = snapshot(1)
assert(chat.modified and chat.lines[1] == "local unsaved = true" and chat.scope == nil,
  "Codex chat should receive the unsaved editor snapshot")

source()
vim.cmd("normal! gg0v4l\27")
pair.ask("explain selected scope")
wait_for(function() return #requests("turn/start") >= 2 end, "Codex Ask should start")
local asked = snapshot(2)
assert(asked.scope.kind == "replace" and asked.scope.text == "local"
  and asked.lines[1] == "local unsaved = true", "Ask should use the same live buffer")

source()
vim.cmd("normal! gg0V\27")
pair.change("pair-test-change")
local changed = snapshot(3)
assert(changed.scope.linewise and changed.scope.text == "local unsaved = true",
  "Change should target the selected line")
wait_for(function() return edit.pending() ~= nil end, "Codex Change should show a proposal")
assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local changed = true")
assert(edit.reject(), "Reject should restore the original line")
assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local unsaved = true")

source()
api.nvim_win_set_cursor(source_win, { 2, 0 })
pair.here("pair-test-insert")
local inserted = snapshot(4)
assert(inserted.scope.kind == "insert" and inserted.scope.start_row == 1
  and inserted.scope.start_col == 0, "Insert should capture the cursor position")
wait_for(function() return edit.pending() ~= nil end, "Codex Insert should show a proposal")
assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local helper = true")
assert(edit.accept(), "Accept should keep the inserted helper")
assert(vim.fn.readfile(path)[1] == "disk copy", "Pair should leave the disk file untouched")

source()
pair.send("mock cancel")
wait_for(function() return agent_text():find("partial", 1, true) end, "Codex cancel target should stream")
pair.cancel()
wait_for(function() return methods("turn/interrupt") >= 1 end, "Pair should interrupt the Codex turn")
wait_for(function()
  for _, entry in ipairs(entries()) do
    if entry.text:find("Request cancelled", 1, true) then return true end
  end
end, "cancelled turn should be recorded")

local previous = record
pair.new_session()
record = assert(sessions.current(root, "codex"))
assert(record.id ~= previous.id, "new chat should make a separate record")
local choices, choose
vim.ui.select = function(items, _, callback) choices, choose = items, callback end
pair.pick_session()
local restore
for _, item in ipairs(choices) do if item.id == previous.id then restore = item end end
assert(restore, "previous Codex session should appear in picker")
choose(restore)
wait_for(function() return sessions.current(root, "codex").id == previous.id end,
  "Codex session should resume")
record = previous
assert(methods("thread/resume") >= 1, "Codex app-server should resume the saved thread")
source()
pair.send("follow-up after resume")
wait_for(function() return #requests("turn/start") >= 6 end, "resumed Codex turn should run")
wait_for(function() return agent_replies() >= 3 end,
  "resumed thread should answer")

local launched = vim.json.decode(vim.fn.readfile(args_trace)[1])
local launch = table.concat(launched, " ")
for _, feature in ipairs(require("pair.mcp").disabled_features) do
  assert(launch:find("--disable " .. feature, 1, true), "unsafe Codex feature should be disabled: " .. feature)
end
assert(launch:find("mcp_servers.read_server.enabled=false", 1, true),
  "configured MCP server should be disabled")
for _, params in ipairs(requests("thread/start")) do
  assert(params.sandbox == "read-only" and params.approvalPolicy == "never",
    "thread/start must request a read-only sandbox")
end
for _, params in ipairs(requests("thread/resume")) do
  assert(params.sandbox == "read-only" and params.approvalPolicy == "never",
    "thread/resume must request a read-only sandbox")
end
for _, params in ipairs(requests("turn/start")) do
  assert(params.sandboxPolicy.type == "readOnly" and params.approvalPolicy == "never",
    "every turn must request a read-only sandbox")
end

local turns_before_drift = #requests("turn/start")
vim.env.PAIR_MOCK_CODEX_MCP = "read_server,new_server"
source()
pair.send("MCP drift check")
wait_for(function()
  for _, entry in ipairs(entries()) do
    if entry.text:find("MCP configuration changed", 1, true) then return true end
  end
end, "Pair should refuse a turn after Codex MCP configuration changes")
assert(#requests("turn/start") == turns_before_drift, "MCP drift must block the turn")
vim.env.PAIR_MOCK_CODEX_MCP = "read_server"

source()
pair.send("mock file change")
wait_for(function()
  for _, entry in ipairs(entries()) do
    if entry.text:find("direct file change", 1, true) then return true end
  end
end, "Pair should stop if Codex reports a direct file change")
assert(vim.fn.readfile(path)[1] == "disk copy", "file-change event must not modify the project")

for _, name in ipairs(env_names) do vim.env[name] = prior[name] end
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root)
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
for _, path_to_delete in ipairs({ params_trace, args_trace, method_trace }) do vim.fn.delete(path_to_delete) end
vim.fn.delete(root, "rf")
print("Pair Codex baseline tests passed")
