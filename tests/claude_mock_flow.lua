-- Exercise the built-in Claude preset through Pair without an account or model prompt.
local api = vim.api
local plugin_root = vim.fn.getcwd()
vim.opt.rtp:append(plugin_root)
local root, request_trace, prompt_trace = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local executable = root .. "/bin/claude-agent-acp"
local wrapper = { "#!/usr/bin/env python3" }
vim.list_extend(wrapper, vim.fn.readfile(plugin_root .. "/tests/mock_acp.py"))
vim.fn.writefile(wrapper, executable)
vim.fn.setfperm(executable, "rwxr-xr-x")
local env_names = { "PATH", "PAIR_MOCK_REQUEST_TRACE", "PAIR_MOCK_PROMPT_TRACE", "PAIR_MOCK_MODES" }
local prior = {}
for _, name in ipairs(env_names) do
  prior[name] = vim.env[name]
end
vim.env.PATH = root .. "/bin:" .. (prior.PATH or "")
vim.env.PAIR_MOCK_REQUEST_TRACE = request_trace
vim.env.PAIR_MOCK_PROMPT_TRACE = prompt_trace
vim.env.PAIR_MOCK_MODES = "modern"

local path = root .. "/sample.lua"
vim.fn.writefile({ "disk copy" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, -1, false,
  { "local unsaved = true", "local second = 2", "return second" })

local pair = require("pair")
local edit = require("pair.edit")
local sessions = require("pair.sessions")
pair.setup({ backend = "claude", keymaps = false })
local record = assert(sessions.current(root, "claude"))
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".claude"

local function wait_for(predicate, label)
  assert(vim.wait(5000, predicate, 20), "Timed out: " .. label)
end
local function entries()
  return assert(sessions.read_transcript(record))
end
local function agent_text()
  local result = {}
  for _, item in ipairs(entries()) do
    if item.role == "Agent" then result[#result + 1] = item.text end
  end
  return table.concat(result, "\n")
end
local function requests(method)
  local result = {}
  if vim.fn.filereadable(request_trace) ~= 1 then return result end
  for _, line in ipairs(vim.fn.readfile(request_trace)) do
    local item = vim.json.decode(line)
    if item.method == method then result[#result + 1] = item.params end
  end
  return result
end
local function prompts()
  local result = {}
  if vim.fn.filereadable(prompt_trace) ~= 1 then return result end
  for _, line in ipairs(vim.fn.readfile(prompt_trace)) do result[#result + 1] = vim.json.decode(line) end
  return result
end
local function snapshot(index)
  wait_for(function() return #prompts() >= index end, "Claude prompt " .. index)
  local raw = assert(prompts()[index]:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>"))
  return vim.json.decode(raw)
end
local function ready()
  local header = vim.fn.bufnr("pair://header")
  return header ~= -1 and table.concat(api.nvim_buf_get_lines(header, 0, -1, false), " ")
    :find("Ready", 1, true) ~= nil
end
local function source() api.nvim_set_current_win(source_win) end

local ok, err = pcall(function()
  pair.send("pair-test-stream")
  wait_for(function()
    local result = agent_text()
    return result:find("first", 1, true) and not result:find("first second", 1, true)
  end, "partial streamed chat reply")
  wait_for(function() return agent_text():find("first second", 1, true) end, "full chat reply")
  wait_for(ready, "completed chat")
  assert(vim.fn.filereadable(record.session) == 1, "completed turn should save the ACP pointer")
  local chat = snapshot(1)
  assert(chat.modified and chat.lines[1] == "local unsaved = true" and chat.scope == nil,
    "Chat should use the unsaved editor snapshot")

  source()
  vim.cmd("normal! gg0v4l\27")
  pair.ask("explain selected scope")
  local asked = snapshot(2)
  assert(asked.scope.kind == "replace" and asked.scope.text == "local"
    and asked.lines[1] == "local unsaved = true", "Ask should use the selected live buffer")
  wait_for(ready, "Ask completion")
  edit.dismiss_answer()

  source()
  vim.cmd("normal! gg0V\27")
  pair.change("pair-test-change")
  local changed = snapshot(3)
  assert(changed.scope.linewise and changed.scope.text == "local unsaved = true",
    "Change should target the selected line")
  wait_for(function() return edit.pending() ~= nil end, "Change proposal")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local changed = true")
  assert(edit.reject(), "Reject should restore the original line")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local unsaved = true")

  source()
  api.nvim_win_set_cursor(source_win, { 2, 0 })
  pair.here("pair-test-insert")
  local inserted = snapshot(4)
  assert(inserted.scope.kind == "insert" and inserted.scope.start_row == 1
    and inserted.scope.start_col == 0, "Insert should capture the cursor")
  wait_for(function() return edit.pending() ~= nil end, "Insert proposal")
  assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local helper = true")
  assert(edit.accept(), "Accept should keep the helper")
  assert(vim.fn.readfile(path)[1] == "disk copy", "Pair should leave disk untouched")

  source()
  pair.send("cancel me")
  wait_for(function() return #requests("session/prompt") >= 5 end, "cancellable prompt")
  pair.cancel()
  wait_for(function() return #requests("session/cancel") >= 1 end, "ACP cancel request")
  wait_for(function()
    for _, item in ipairs(entries()) do
      if item.text:find("Request cancelled", 1, true) then return true end
    end
  end, "cancellation transcript")

  local previous = record
  pair.new_session()
  record = assert(sessions.current(root, "claude"))
  assert(record.id ~= previous.id, "PairNew should create a separate conversation")
  local original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if item.id == previous.id then callback(item); return end
    end
    callback(nil)
  end
  pair.pick_session()
  vim.ui.select = original_select
  wait_for(function() return sessions.current(root, "claude").id == previous.id end,
    "saved Claude session restore")
  record = previous
  assert(#requests("session/load") >= 1, "restore should use ACP session/load")
  source()
  pair.send("follow-up after resume")
  wait_for(function() return #requests("session/prompt") >= 6 end, "resumed prompt")
  wait_for(function() return agent_text():find("hello world", 1, true) end, "resumed reply")
  wait_for(ready, "resumed completion")

  source()
  pair.send("pair-test-unsafe")
  wait_for(function()
    for _, item in ipairs(entries()) do
      if item.text:find("outside Pair's inspection set", 1, true) then return true end
    end
  end, "unexpected Write tool blocked")
  assert(vim.fn.readfile(path)[1] == "disk copy", "unexpected tool must not write to disk")
  assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local helper = true",
    "unexpected tool must not alter the source buffer")

  assert(#requests("session/new") >= 1 and #requests("session/load") >= 1,
    "Claude should start and resume under the restricted profile")
  for _, method in ipairs({ "session/new", "session/load" }) do
    for _, params in ipairs(requests(method)) do
      local options = assert(params._meta.claudeCode.options)
      assert(#params.mcpServers == 0 and #options.mcpServers == 0
        and #options.settingSources == 0 and #options.plugins == 0
        and options.strictMcpConfig and options.allowDangerouslySkipPermissions == false)
      assert(vim.deep_equal(options.tools, { "Read", "Glob", "Grep" }))
      for _, name in ipairs({ "Bash", "Write", "Edit", "NotebookEdit", "Agent", "Task",
        "WebFetch", "WebSearch", "Skill" }) do
        assert(vim.tbl_contains(options.disallowedTools, name), "must block " .. name)
      end
    end
  end
  assert(#requests("session/set_mode") >= 2, "new and resumed sessions should enter plan mode")
  for _, params in ipairs(requests("session/set_mode")) do assert(params.modeId == "plan") end
  local initialized = assert(requests("initialize")[1])
  assert(initialized.clientCapabilities.fs.readTextFile == false
    and initialized.clientCapabilities.fs.writeTextFile == false
    and initialized.clientCapabilities.terminal == false,
    "Pair must not expose filesystem or terminal client capabilities")
end)

if edit.pending() then pcall(edit.reject) end
pair.cancel()
for _, name in ipairs(env_names) do vim.env[name] = prior[name] end
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(root, "rf")
vim.fn.delete(request_trace)
vim.fn.delete(prompt_trace)
if not ok then
  vim.bo[source_buf].modified = false
  error(err)
end
print("Pair Claude mock workflow tests passed")
