-- Exercise the built-in Copilot preset and its unnamed ACP read-tool events without an account.
local api = vim.api
local plugin_root = vim.fn.getcwd()
vim.opt.rtp:append(plugin_root)
local root, request_trace, prompt_trace, args_trace = vim.fn.tempname(), vim.fn.tempname(),
  vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local executable = root .. "/bin/copilot"
local wrapper = { "#!/usr/bin/env python3" }
vim.list_extend(wrapper, vim.fn.readfile(plugin_root .. "/tests/mock_acp.py"))
vim.fn.writefile(wrapper, executable)
vim.fn.setfperm(executable, "rwxr-xr-x")
local env_names = { "PATH", "PAIR_MOCK_REQUEST_TRACE", "PAIR_MOCK_PROMPT_TRACE",
  "PAIR_MOCK_ARGS_TRACE" }
local prior = {}
for _, name in ipairs(env_names) do prior[name] = vim.env[name] end
vim.env.PATH = root .. "/bin:" .. (prior.PATH or "")
vim.env.PAIR_MOCK_REQUEST_TRACE = request_trace
vim.env.PAIR_MOCK_PROMPT_TRACE = prompt_trace
vim.env.PAIR_MOCK_ARGS_TRACE = args_trace

local path = root .. "/sample.lua"
vim.fn.writefile({ "disk copy" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, -1, false,
  { "local unsaved = true", "local second = 2", "return second" })
local pair, edit, sessions = require("pair"), require("pair.edit"), require("pair.sessions")
pair.setup({ backend = "copilot", keymaps = false })
local record = assert(sessions.current(root, "copilot"))
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".copilot"

local function wait_for(test, label)
  assert(vim.wait(5000, test, 20), "Timed out: " .. label)
end
local function entries() return assert(sessions.read_transcript(record)) end
local function contains(needle)
  for _, item in ipairs(entries()) do
    if item.text:find(needle, 1, true) then return true end
  end
  return false
end
local function trace_lines(path)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local lines = vim.fn.readfile(path, "b")
  -- The mock appends JSONL while we poll. Only decode newline-terminated records;
  -- the final item is either empty or a record that is still being written.
  table.remove(lines)
  return lines
end
local function requests(method)
  local result = {}
  for _, line in ipairs(trace_lines(request_trace)) do
    local item = vim.json.decode(line)
    if item.method == method then result[#result + 1] = item.params end
  end
  return result
end
local function snapshot(index)
  wait_for(function() return #trace_lines(prompt_trace) >= index end, "prompt " .. index)
  local prompt = vim.json.decode(trace_lines(prompt_trace)[index])
  return vim.json.decode(assert(prompt:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>")))
end
local function ready()
  local header = vim.fn.bufnr("pair://header")
  return header ~= -1 and table.concat(api.nvim_buf_get_lines(header, 0, -1, false), " ")
    :find("Ready", 1, true) ~= nil
end
local function source() api.nvim_set_current_win(source_win) end

local ok, err = pcall(function()
  local complete = '{"method":"pair-test-trace","params":{}}'
  vim.fn.writefile({ complete, '{"method":"pair-test-trace","params":' }, request_trace, "b")
  assert(#requests("pair-test-trace") == 1, "polling must ignore a partially written record")
  vim.fn.writefile({ complete, complete, "" }, request_trace, "b")
  assert(#requests("pair-test-trace") == 2, "the completed record must appear on the next poll")
  vim.fn.delete(request_trace)

  pair.send("pair-test-unnamed-read")
  wait_for(function() return contains("read complete") end, "unnamed read result")
  wait_for(ready, "read completion")
  local chat = snapshot(1)
  assert(chat.modified and chat.lines[1] == "local unsaved = true" and chat.scope == nil)
  assert(vim.fn.filereadable(record.session) == 1, "completed prompt should save session pointer")
  local tool_seen = false
  for _, item in ipairs(entries()) do
    if item.role == "Tool" and item.text == "Viewing sample.lua" then tool_seen = true end
  end
  assert(tool_seen, "Copilot's unnamed read tool should reach Pair's chat")

  source()
  vim.cmd("normal! gg0v4l\27")
  pair.ask("explain selected scope")
  local asked = snapshot(2)
  assert(asked.scope.kind == "replace" and asked.scope.text == "local"
    and asked.lines[1] == "local unsaved = true")
  wait_for(ready, "Ask completion")
  edit.dismiss_answer()

  source()
  vim.cmd("normal! gg0V\27")
  pair.change("pair-test-change")
  assert(snapshot(3).scope.text == "local unsaved = true")
  wait_for(function() return edit.pending() ~= nil end, "Change proposal")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local changed = true")
  assert(edit.reject())

  source()
  api.nvim_win_set_cursor(source_win, { 2, 0 })
  pair.here("pair-test-insert")
  assert(snapshot(4).scope.kind == "insert")
  wait_for(function() return edit.pending() ~= nil end, "Insert proposal")
  assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local helper = true")
  assert(edit.accept())
  assert(vim.fn.readfile(path)[1] == "disk copy")

  local previous = record
  pair.new_session()
  record = assert(sessions.current(root, "copilot"))
  assert(record.id ~= previous.id)
  local original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if item.id == previous.id then callback(item); return end
    end
    callback(nil)
  end
  pair.pick_session()
  vim.ui.select = original_select
  wait_for(function() return sessions.current(root, "copilot").id == previous.id end,
    "Copilot session/load")
  record = previous
  source()
  pair.send("pair-test-unnamed-read after resume")
  wait_for(function() return #requests("session/prompt") >= 5 end, "resumed read prompt")
  wait_for(ready, "resumed read completion")

  source()
  pair.send("pair-test-unnamed-edit")
  wait_for(function() return contains("outside Pair's inspection set") end,
    "unnamed edit must stop Copilot session")
  assert(vim.fn.readfile(path)[1] == "disk copy")
  assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local helper = true")

  local args = vim.json.decode(vim.fn.readfile(args_trace)[1])
  for _, expected in ipairs({ "--acp", "--stdio", "--available-tools=view,glob,grep",
    "--disable-builtin-mcps", "--no-custom-instructions", "--no-auto-update",
    "--no-experimental", "--no-remote-export" }) do
    assert(vim.tbl_contains(args, expected), "Copilot launch must include " .. expected)
  end
  assert(#requests("session/new") >= 1 and #requests("session/load") >= 1)
  for _, method in ipairs({ "session/new", "session/load" }) do
    for _, params in ipairs(requests(method)) do assert(#params.mcpServers == 0) end
  end
  local caps = assert(requests("initialize")[1]).clientCapabilities
  assert(caps.fs.readTextFile == false and caps.fs.writeTextFile == false
    and caps.terminal == false)
end)

if edit.pending() then pcall(edit.reject) end
pair.cancel()
for _, name in ipairs(env_names) do vim.env[name] = prior[name] end
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(root, "rf")
vim.fn.delete(request_trace)
vim.fn.delete(prompt_trace)
vim.fn.delete(args_trace)
if not ok then
  vim.bo[source_buf].modified = false
  error(err)
end
print("Pair Copilot mock workflow tests passed")
