-- Opt-in live backend probe. Run with PAIR_LIVE_BACKEND=codex|gemini|antigravity|opencode|claude|copilot.
vim.opt.rtp:append(vim.fn.getcwd())

local backend = vim.env.PAIR_LIVE_BACKEND
assert(backend and backend ~= "", "Set PAIR_LIVE_BACKEND before running this probe")

local api = vim.api
local backends = require("pair.backends")
local context = require("pair.context")
local models = vim.env.PAIR_LIVE_MODEL and { [backend] = vim.env.PAIR_LIVE_MODEL } or {}
local spec = assert(backends.resolve(backend, { command = "codex", agents = {}, models = models }))
local Client = spec.kind == "codex" and require("pair.app_server")
  or spec.kind == "antigravity" and require("pair.antigravity") or require("pair.acp")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/pair_probe.txt"
local nonce = vim.fn.sha256(root):sub(1, 10)
local disk_text = "PAIR_DISK_" .. nonce
local live_text = "PAIR_EDITOR_" .. nonce
vim.fn.writefile({ disk_text }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, -1, false, { live_text })
local snapshot = assert(context.capture(buf))
assert(snapshot.modified and snapshot.lines[1] == live_text)

local messages, tools, errors = {}, {}, {}
local client = Client.new({
  command = spec.command, args = spec.args, env = spec.env,
  session_meta = spec.session_meta,
  allowed_tool_names = spec.allowed_tool_names,
  allowed_tool_kinds = spec.allowed_tool_kinds,
  required_mode = spec.required_mode, model = spec.model,
  cwd = root, session_file = root .. "/pair.session",
  on_update = function(update)
    if update.sessionUpdate == "agent_message_chunk" and update.content
      and update.content.type == "text" then
      messages[#messages + 1] = update.content.text
    elseif update.sessionUpdate == "tool_call" then
      tools[#tools + 1] = update.title or "unnamed tool"
    end
  end,
  on_error = function(err) errors[#errors + 1] = tostring(err) end,
})

local report = { backend = backend, disk = disk_text, editor = live_text }
local started
client:start(function(_, err) started = { err = err } end)
if not vim.wait(40000, function() return started ~= nil end, 50) then
  report.status = "startup_timeout"
elseif started.err then
  report.status = "startup_error"
  report.error = started.err.message or tostring(started.err)
else
  local prompt = "Pair session rules: inspect only; do not write project files. Run only read-only inspection commands.\n\n"
    .. context.prompt_block(snapshot)
    .. "Use an allowed file inspection tool to read pair_probe.txt from the saved disk file. "
    .. "Then compare that tool result with the attached Neovim snapshot. "
    .. "Reply with three short lines: DISK: <exact saved line or TOOL_UNAVAILABLE>; "
    .. "EDITOR: <exact live line>; AUTHORITATIVE_FOR_CURRENT_EDITOR: <DISK or EDITOR>. "
    .. "Do not save or change the file."
  local finished
  client:prompt(prompt, function(result, err) finished = { result = result, err = err } end)
  if not vim.wait(120000, function() return finished ~= nil end, 50) then
    report.status = "prompt_timeout"
    client:cancel()
  elseif finished.err then
    report.status = "prompt_error"
    report.error = finished.err.message or tostring(finished.err)
  else
    report.status = (finished.result or {}).stopReason or "unknown"
  end
end
report.response = table.concat(messages)
report.tool_calls = tools
report.events = errors
report.disk_unchanged = vim.fn.readfile(path)[1] == disk_text
report.editor_unchanged = api.nvim_buf_get_lines(buf, 0, 1, false)[1] == live_text
report.identified_disk = report.response:find(disk_text, 1, true) ~= nil
report.identified_editor = report.response:find(live_text, 1, true) ~= nil
client:stop()
print(vim.json.encode(report))
if backend == "antigravity" then
  vim.fn.delete(vim.fn.stdpath("state") .. "/pair/antigravity/" .. vim.fn.sha256(root), "rf")
end
vim.fn.delete(root, "rf")
