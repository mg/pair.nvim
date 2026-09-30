vim.opt.rtp:append(vim.fn.getcwd())
vim.g.mapleader = " "

local api = vim.api
local plugin_root = vim.fn.getcwd()
local root, trace, calls = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
local path = root .. "/sample.lua"
vim.fn.writefile({ "saved on disk" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local original = { "local alpha = 1", "local beta = 2", "return alpha + beta" }
api.nvim_buf_set_lines(source_buf, 0, -1, false, original)

local pair = require("pair")
local edit = require("pair.edit")
pair.setup({
  backend = "mock", keymaps = true,
  agents = { mock = {
    kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_PROMPT_TRACE = trace, PAIR_MOCK_TRACE = calls },
    required_mode = "plan", restricted = true,
  } },
})

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(40)
end

local function prompts()
  if vim.fn.filereadable(trace) == 0 then return {} end
  local result = {}
  for _, line in ipairs(vim.fn.readfile(trace)) do result[#result + 1] = vim.json.decode(line) end
  return result
end

local function wait_for(count)
  assert(vim.wait(4000, function() return #prompts() >= count end), "expected prompt " .. count)
  return prompts()[count]
end

local function snapshot(prompt)
  return vim.json.decode(assert(prompt:match("<editor_snapshot_json>\n(.-)\n</editor_snapshot_json>")))
end

local function at_source()
  assert(api.nvim_win_is_valid(source_win))
  api.nvim_set_current_win(source_win)
end

local function assert_prompt()
  assert(vim.bo.filetype == "pairprompt", "expected the small Pair request window")
end

-- Visual character selection through the actual mapping, then an empty submit and cancellation.
at_source()
press("gg0v4l<leader>pa")
assert_prompt()
press("<CR>")
assert_prompt()
assert(#prompts() == 0, "empty request must not reach the agent")
press("idraft<Esc>")
assert(api.nvim_buf_get_lines(0, 0, 1, false)[1] == "draft", "cancel check needs a real draft")
press("q")
assert(vim.wait(1000, function() return api.nvim_get_current_win() == source_win end),
  "cancelling a draft should return to the source")
assert(#prompts() == 0, "cancelled draft must not reach the agent")
press("gg0v4l<leader>pa")
assert_prompt()
press("iwhy this?<CR>")
local ask = snapshot(wait_for(1))
assert(ask.scope.kind == "replace" and ask.scope.text == "local"
  and ask.scope.start_col == 0 and ask.scope.end_col == 5,
  "Visual Ask mapping must send the exact character selection")
assert(ask.modified and ask.lines[1] == original[1], "Ask must send the unsaved buffer")
assert(vim.wait(4000, function()
  local ns = api.nvim_get_namespaces()["pair.nvim.answer"]
  return ns and #api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, {}) > 0
end), "Ask answer should appear in the source buffer")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), original),
  "Ask must not change the source")

-- Chat first, then a selected change: both requests should use one backend session.
at_source()
pair.chat()
vim.cmd("stopinsert")
assert(vim.bo.filetype == "pairinput")
press("iif I change alpha, what else should I inspect?<Esc>")
press("<CR>")
local chat = snapshot(wait_for(2))
assert(chat.scope == nil and chat.lines[1] == original[1], "chat must include the live source")
at_source()
press("gg0Vj<leader>pe")
assert_prompt()
press("ipair-test-change<CR>")
local change = snapshot(wait_for(3))
assert(change.scope.linewise and change.scope.text == original[1] .. "\n" .. original[2]
  and change.scope.start_row == 0 and change.scope.end_row == 2,
  "Visual Change mapping must preserve the complete selected lines")
assert(vim.wait(4000, function() return edit.pending() ~= nil end), "Change should show a proposal")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
  { "local changed = true", original[3] }), "preview must replace only the selected lines")
assert(edit.reject())
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), original),
  "rejection must restore the selected lines")
local methods = vim.fn.readfile(calls)
local sessions = 0
for _, method in ipairs(methods) do if method == "session/new" then sessions = sessions + 1 end end
assert(sessions == 1, "chat and buffer requests should share the same agent session")

-- Insert here through the Normal mapping, with the cursor between two lines.
at_source()
api.nvim_win_set_cursor(source_win, { 2, 0 })
press("<leader>pi")
assert_prompt()
press("ipair-test-insert<CR>")
local insertion = snapshot(wait_for(4))
assert(insertion.scope.kind == "insert" and insertion.scope.start_row == 1
  and insertion.scope.start_col == 0 and insertion.scope.end_row == 1
  and insertion.scope.end_col == 0, "Insert mapping must send the exact cursor position")
assert(vim.wait(4000, function() return edit.pending() ~= nil end), "Insert should show a proposal")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
  { original[1], "local helper = true", original[2], original[3] }),
  "insert preview must appear at the requested position")
assert(edit.accept())

-- An explicit Ex range must select its own lines, even after a different Visual selection.
at_source()
press("gg0v4l<Esc>")
vim.cmd("2,3PairAsk explain these lines")
local ranged = snapshot(wait_for(5))
assert(ranged.scope.start_row == 1 and ranged.scope.end_row == 3
  and ranged.scope.text == "local helper = true\nlocal beta = 2",
  "explicit PairAsk ranges must not reuse stale Visual marks")

at_source()
press("gg0v4l:PairAsk visual command<CR>")
local visual_command = snapshot(wait_for(6))
assert(visual_command.scope.text == "local" and visual_command.scope.start_row == 0
  and visual_command.scope.end_row == 0 and visual_command.scope.end_col == 5,
  "typing a Pair command from Visual mode must preserve character bounds")

at_source()
vim.cmd("2,3PairChange pair-test-change")
local ranged_change = snapshot(wait_for(7))
assert(ranged_change.scope.linewise and ranged_change.scope.start_row == 1
  and ranged_change.scope.end_row == 3, "explicit Change range must be linewise")
assert(vim.wait(4000, function() return edit.pending() ~= nil end), "ranged Change should show a proposal")
assert(vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
  { original[1], "local changed = true", original[3] }),
  "ranged Change preview must affect only its requested lines")
assert(edit.reject())

at_source()
api.nvim_win_set_cursor(source_win, { 2, 0 })
press("<leader>pi")
assert_prompt()
press("iunwanted helper<Esc>")
press("q")
assert(vim.wait(1000, function() return api.nvim_get_current_win() == source_win end),
  "cancelled Insert prompt should return to the source")
assert(#prompts() == 7 and not edit.pending(),
  "cancelled Insert prompt must not create an agent request or proposal")

-- A characterwise scope ends after the whole UTF-8 character, not its first byte.
at_source()
api.nvim_buf_set_lines(source_buf, 0, 1, false, { "local café = 1" })
api.nvim_win_set_cursor(source_win, { 1, 9 })
press("v<Esc>")
local unicode = assert(edit.selection())
assert(unicode.original == "é" and unicode.start_col == 9 and unicode.end_col == 11,
  "UTF-8 Visual selection should include the complete final character")
api.nvim_win_set_cursor(source_win, { 1, 9 })
press("vh<Esc>")
unicode = assert(edit.selection())
assert(unicode.original == "fé" and unicode.start_col == 8 and unicode.end_col == 11,
  "backward UTF-8 selection should preserve both selected characters")
vim.o.selection = "exclusive"
api.nvim_win_set_cursor(source_win, { 1, 9 })
press("vh<Esc>")
unicode = assert(edit.selection())
assert(unicode.original == "f" and unicode.start_col == 8 and unicode.end_col == 9,
  "exclusive Visual selection should omit its upper endpoint")
vim.o.selection = "inclusive"

assert(vim.fn.readfile(path)[1] == "saved on disk", "requests and previews must not save the file")
pair.cancel()
vim.fn.delete(trace)
vim.fn.delete(calls)
vim.fn.delete(root, "rf")
print("Pair real input path tests passed")
