vim.opt.rtp:append(vim.fn.getcwd())

local api = vim.api
local plugin_root = vim.fn.getcwd()
local root = vim.fn.tempname()
local trace = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/sample.lua"
vim.fn.writefile({ "disk version" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win = api.nvim_get_current_win()
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved version", "local second = 2" })

local pair = require("pair")
pair.setup({
  backend = "mock",
  keymaps = false,
  agents = {
    mock = {
      kind = "acp",
      command = "python3",
      args = { plugin_root .. "/tests/mock_acp.py" },
      env = { PAIR_MOCK_PROMPT_TRACE = trace },
      required_mode = "plan",
      restricted = true,
    },
  },
})

local function prompts()
  if vim.fn.filereadable(trace) == 0 then return {} end
  local result = {}
  local lines = vim.fn.readfile(trace)
  for index, line in ipairs(lines) do
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok then
      if index == #lines then break end -- The mock may still be appending this line.
      error("Invalid completed mock prompt trace line " .. index)
    end
    result[#result + 1] = decoded
  end
  return result
end

local function wait_for(count)
  local observed
  assert(vim.wait(4000, function()
    observed = prompts()
    return #observed >= count
  end), "expected " .. count .. " prompts")
  return observed
end

local function attachment(prompt)
  local json = assert(prompt:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>"),
    "prompt should contain a delimited snapshot")
  return vim.json.decode(json)
end

pair.send("first chat")
local sent = wait_for(1)
local first = attachment(sent[1])
assert(first.path == path and first.modified and first.lines[1] == "unsaved version"
  and first.lines[2] == "local second = 2" and first.scope == nil,
  "chat must send the full unsaved source buffer")
assert(sent[1]:find("newer than the saved file", 1, true), "modified snapshot must take priority over disk")
assert(sent[1]:find("</editor_snapshot_json>\n\nfirst chat", 1, true),
  "the user's instruction must remain outside the serialized source attachment")
assert(vim.fn.readfile(path)[1] == "disk version", "Pair must not save the source buffer")

api.nvim_buf_set_lines(buf, 0, 1, false, { "newer version" })
pair.send("second chat")
sent = wait_for(2)
assert(attachment(sent[1]).lines[1] == "unsaved version" and attachment(sent[2]).lines[1] == "newer version",
  "each turn must use its own submission-time snapshot")

api.nvim_set_current_win(source_win)
vim.cmd("normal! gg0v2l\27")
pair.ask("why this selection")
sent = wait_for(3)
local asked = attachment(sent[3])
assert(asked.lines[1] == "newer version" and asked.scope.kind == "replace"
  and asked.scope.start_row == 0 and asked.scope.start_col == 0
  and asked.scope.end_row == 0 and asked.scope.end_col == 3
  and asked.scope.text == "new", "Ask must include full live text and exact selected scope")

api.nvim_set_current_win(source_win)
vim.cmd("normal! gg0v2l\27")
pair.change("replace this selection")
sent = wait_for(4)
local changed = attachment(sent[4])
assert(changed.scope.kind == "replace" and changed.scope.text == "new"
  and changed.lines[2] == "local second = 2", "Change must use the same snapshot contract")

api.nvim_set_current_win(source_win)
api.nvim_win_set_cursor(source_win, { 2, 0 })
pair.here("insert at this point")
sent = wait_for(5)
local inserted = attachment(sent[5])
assert(inserted.scope.kind == "insert" and inserted.scope.start_row == 1
  and inserted.scope.start_col == 0 and inserted.scope.end_row == 1
  and inserted.scope.end_col == 0 and inserted.lines[1] == "newer version",
  "Insert must include a zero-width byte position and the full live buffer")

pair.send("slow reply")
wait_for(6)
api.nvim_buf_set_lines(buf, 0, 1, false, { "queued version" })
pair.send("queued chat")
api.nvim_buf_set_lines(buf, 0, 1, false, { "later version" })
sent = wait_for(7)
assert(attachment(sent[7]).lines[1] == "queued version",
  "queued turns must not read a later buffer version when dispatched")
assert(vim.fn.readfile(path)[1] == "disk version", "no prompt path should write the buffer")

pair.cancel()
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair shared prompt context tests passed")
