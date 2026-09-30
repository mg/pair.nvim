vim.opt.rtp:append(vim.fn.getcwd())
local api = vim.api
local edit = require("pair.edit")
local pair = require("pair")
pair.setup({ keymaps = false })

local function press(key)
  api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "x", false)
  vim.wait(30)
end

local function diff_sides()
  local sides = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local title = api.nvim_get_option_value("winbar", { win = win })
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
    if title:find("Original", 1, true) then sides.original = { win = win, lines = lines }
    elseif title:find("Proposed", 1, true) then sides.proposed = { win = win, lines = lines } end
  end
  assert(sides.original and sides.proposed, "diff tab should show original and proposed sides")
  assert(vim.wo[sides.original.win].diff and vim.wo[sides.proposed.win].diff,
    "both scratch windows should use Vim's diff highlighting")
  return sides
end

api.nvim_buf_set_lines(0, 0, -1, false, { "zero", "one", "two", "three", "four", "five", "six" })
api.nvim_win_set_cursor(0, { 4, 0 })
local target = edit.insertion()
local source_win = api.nvim_get_current_win()
local source_lines = api.nvim_buf_get_lines(0, 0, -1, false)
assert(edit.show(target, "helper()\n", nil, "A small helper"))
local applied_lines = api.nvim_buf_get_lines(0, 0, -1, false)
assert(api.nvim_get_current_win() == source_win)
vim.cmd("PairDiff")
assert(#api.nvim_list_tabpages() == 2, ":PairDiff should open a focused review tab")
local sides = diff_sides()
assert(table.concat(sides.original.lines, "|") == "zero|one|two|three|four|five|six",
  "original side should include three lines of context on either side")
assert(table.concat(sides.proposed.lines, "|") == "zero|one|two|helper()|three|four|five|six",
  "proposed side should show the inserted code and surrounding context")
assert(not vim.bo[api.nvim_win_get_buf(sides.original.win)].modifiable
  and not vim.bo[api.nvim_win_get_buf(sides.proposed.win)].modifiable,
  "diff scratch buffers should not be editable")
assert(vim.deep_equal(api.nvim_buf_get_lines(target.buf, 0, -1, false), applied_lines),
  "opening the diff should not alter the source buffer")
press("q")
assert(#api.nvim_list_tabpages() == 1 and api.nvim_get_current_win() == source_win,
  "q should return to the original source window")
for _, buf in ipairs(api.nvim_list_bufs()) do
  assert(not api.nvim_buf_get_name(buf):find("pair://diff/", 1, true),
    "closing the diff should wipe its scratch buffers")
end
assert(edit.pending() and api.nvim_win_get_cursor(source_win)[1] == 3,
  "closing the diff should keep the pending proposal and review cursor")
vim.cmd("PairDiff")
vim.cmd("PairDiff")
assert(#api.nvim_list_tabpages() == 1 and api.nvim_get_current_win() == source_win,
  ":PairDiff should toggle the review tab without resolving the proposal")

press("j")
assert(api.nvim_get_current_win() ~= source_win and edit.pending().choice == 1)
press("l")
assert(edit.pending().choice == 2)
local control_win = api.nvim_get_current_win()
press("d")
assert(#api.nvim_list_tabpages() == 2, "d from the inline controls should open the diff")
press("<Esc>")
assert(api.nvim_get_current_win() == control_win and edit.pending().choice == 2,
  "closing the diff should restore the focused Reject choice")
press("<CR>")
assert(not edit.pending() and vim.deep_equal(api.nvim_buf_get_lines(target.buf, 0, -1, false), source_lines),
  "Reject should still work after reviewing the diff")

api.nvim_win_set_cursor(source_win, { 4, 0 })
vim.cmd("normal! V\27")
target = assert(edit.selection())
assert(edit.show(target, "THREE"))
assert(edit.diff())
sides = diff_sides()
assert(table.concat(sides.original.lines, "|"):find("three", 1, true),
  "replacement diff should retain original code")
assert(table.concat(sides.proposed.lines, "|"):find("THREE", 1, true),
  "replacement diff should show proposed code")
vim.cmd("tabclose")
assert(api.nvim_get_current_win() == source_win and edit.pending(),
  ":tabclose should restore source focus without resolving the proposal")
assert(edit.accept())

api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta", "gamma", "delta", "epsilon" })
api.nvim_win_set_cursor(source_win, { 2, 1 })
vim.cmd("normal! v2l\27")
target = assert(edit.selection())
assert(edit.show(target, "ETA"))
assert(edit.diff())
sides = diff_sides()
assert(sides.original.lines[2] == "beta" and sides.proposed.lines[2] == "bETA",
  "character replacement diff should show complete original and proposed lines")
assert(edit.close_diff() and edit.reject(), "character diff should close without affecting rejection")

api.nvim_win_set_cursor(source_win, { 3, 0 })
vim.cmd("normal! V\27")
target = assert(edit.selection())
assert(edit.show(target, ""))
assert(edit.diff())
sides = diff_sides()
assert(table.concat(sides.original.lines, "|"):find("gamma", 1, true)
  and not table.concat(sides.proposed.lines, "|"):find("gamma", 1, true),
  "deletion diff should show the removed line and its surrounding context")
assert(edit.close_diff() and edit.reject(), "deletion diff should leave Reject available")

api.nvim_win_set_cursor(source_win, { 4, 0 })
target = edit.insertion()
assert(edit.show(target, "another()\n"))
local snapshot = vim.deepcopy(edit.pending().diff_after)
api.nvim_buf_set_lines(target.buf, 0, 1, false, { "edited since proposal" })
assert(edit.diff())
sides = diff_sides()
assert(vim.deep_equal(sides.proposed.lines, snapshot),
  "diff should show the proposed snapshot when the source has since changed")
assert(api.nvim_get_option_value("winbar", { win = sides.proposed.win }):find("source buffer changed", 1, true),
  "diff should disclose later source edits")
assert(edit.accept(), "accept should close an open diff and keep the edited buffer")
assert(#api.nvim_list_tabpages() == 1 and api.nvim_get_current_win() == source_win,
  "accept should clean up the review tab")

api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "closing()\n"))
assert(edit.diff())
api.nvim_buf_delete(target.buf, { force = true })
assert(vim.wait(500, function() return not edit.pending() and #api.nvim_list_tabpages() == 1 end, 10),
  "closing the source buffer during diff review should clean up the proposal and diff tab")

print("Pair proposal diff tests passed")
