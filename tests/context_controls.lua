vim.opt.rtp:append(vim.fn.getcwd())

local api = vim.api
local plugin_root = vim.fn.getcwd()
local root = vim.fn.tempname()
local trace = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/large.lua"
local disk = {}
for row = 1, 12 do disk[row] = "saved line number " .. row end
vim.fn.writefile(disk, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win = api.nvim_get_current_win()
local source_buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, 1, false, { "unsaved line one" })

local pair = require("pair")
local ui = require("pair.ui")
pair.setup({
  backend = "mock", keymaps = false, context_max_bytes = 60, context_nearby_lines = 1,
  agents = { mock = {
    kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_PROMPT_TRACE = trace }, required_mode = "plan", restricted = true,
  } },
})

local function prompts()
  if vim.fn.filereadable(trace) == 0 then return {} end
  local result = {}
  for _, line in ipairs(vim.fn.readfile(trace)) do result[#result + 1] = vim.json.decode(line) end
  return result
end

local function wait_for(count)
  assert(vim.wait(4000, function() return #prompts() >= count end), "expected " .. count .. " prompts")
  return prompts()
end

local function attachment(prompt)
  return vim.json.decode(assert(prompt:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>")))
end

local function no_indicator(buf)
  local ns = api.nvim_get_namespaces()["pair.nvim.context_indicator"]
  assert(not ns or #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0,
    "Pair input should leave the first line unobstructed")
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(25)
end

local selected_options, choose
local original_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  selected_options, choose = items, callback
  assert(opts.prompt:find("limit", 1, true), "oversized prompt should explain the size limit")
end

pair.chat()
vim.cmd("stopinsert")
local input_buf = api.nvim_get_current_buf()
no_indicator(input_buf)
press("gC")
local preview_buf = api.nvim_get_current_buf()
local preview = table.concat(api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
assert(preview:find("unsaved line one", 1, true) and preview:find("captured again when sent", 1, true),
  "context preview should display the current live attachment")
press("q")
assert(api.nvim_get_current_buf() == input_buf, "closing context preview should return to the chat input")
press("gA")
no_indicator(input_buf)
api.nvim_buf_set_lines(input_buf, 0, -1, false, { "detached chat" })
assert(ui.submit())
local sent = wait_for(1)
local detached = attachment(sent[1])
assert(detached.coverage.kind == "scope_only" and detached.lines == nil,
  "removing the attachment must omit full buffer content")
no_indicator(input_buf)

api.nvim_buf_set_lines(input_buf, 0, -1, false, { "cancel oversized" })
assert(ui.submit() and selected_options and #selected_options == 3,
  "an oversized chat buffer should offer nearby, detached, and cancel choices")
assert(#prompts() == 1, "oversized message must wait for a choice")
choose(selected_options[3])
assert(api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "cancel oversized",
  "cancel must keep the chat draft")
assert(ui.submit())
choose(selected_options[1])
sent = wait_for(2)
local nearby = attachment(sent[2])
assert(nearby.coverage.kind == "nearby" and #nearby.lines <= 3
  and nearby.coverage.end_row - nearby.coverage.start_row == #nearby.lines,
  "explicit narrowing should send only bounded nearby lines with original row coordinates")
assert(api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "", "accepted choice should clear the draft")

api.nvim_set_current_win(source_win)
vim.cmd("normal! gg0v6l\27")
pair.ask()
vim.cmd("stopinsert")
local request_buf = api.nvim_get_current_buf()
no_indicator(request_buf)
press("gA")
no_indicator(request_buf)
api.nvim_buf_set_lines(request_buf, 0, -1, false, { "detached ask" })
press("<CR>")
sent = wait_for(3)
local scope_only = attachment(sent[3])
assert(scope_only.coverage.kind == "scope_only" and scope_only.lines == nil
  and scope_only.scope.kind == "replace" and scope_only.scope.text == "unsaved",
  "detached editor requests must retain their exact selected scope")

api.nvim_set_current_win(source_win)
vim.cmd("normal! gg0v6l\27")
pair.ask()
vim.cmd("stopinsert")
request_buf = api.nvim_get_current_buf()
no_indicator(request_buf)
api.nvim_buf_set_lines(request_buf, 0, -1, false, { "narrow ask" })
press("<CR>")
assert(selected_options and selected_options[1].label == "Send selected lines only",
  "oversized selection request should offer selected lines")
choose(selected_options[1])
sent = wait_for(4)
local selection = attachment(sent[4])
assert(selection.coverage.kind == "selection" and #selection.lines == 1
  and selection.lines[1] == "unsaved line one" and selection.scope.text == "unsaved",
  "selected-line narrowing must preserve the scoped text and live line")

api.nvim_buf_set_lines(source_buf, 0, 1, false, { string.rep("x", 90) })
api.nvim_set_current_win(source_win)
vim.cmd("normal! gg0v$\27")
pair.ask()
vim.cmd("stopinsert")
request_buf = api.nvim_get_current_buf()
no_indicator(request_buf)
press("gA")
api.nvim_buf_set_lines(request_buf, 0, -1, false, { "too wide" })
press("<CR>")
assert(api.nvim_buf_get_lines(request_buf, 0, 1, false)[1] == "too wide" and #prompts() == 4,
  "a detached selection over the limit should remain unsent with its draft intact")
press("q")

vim.ui.select = original_select
assert(vim.fn.readfile(path)[1] == disk[1], "context controls must not save the source")
pair.cancel()
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair context controls tests passed")
