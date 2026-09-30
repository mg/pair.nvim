vim.opt.rtp:append(vim.fn.getcwd())
local api = vim.api
local edit = require("pair.edit")
local source = api.nvim_get_current_buf()
local source_win = api.nvim_get_current_win()
local function lines(buf) return api.nvim_buf_get_lines(buf or source, 0, -1, false) end
local function reset(value)
  if edit.pending() then assert(edit.accept()) end
  api.nvim_set_current_win(source_win)
  api.nvim_buf_set_lines(source, 0, -1, false, value)
end

reset({ "alpha", "beta", "gamma" })
local before = lines()
api.nvim_win_set_cursor(source_win, { 2, 0 })
local target = edit.insertion()
assert(edit.show(target, "helper()\n"))
vim.cmd("undo")
assert(vim.deep_equal(lines(), before), "one undo should remove only Pair's proposal")
assert(vim.wait(500, function() return not edit.pending() end, 10),
  "undoing a proposal should clear its stale review controls")
vim.cmd("redo")
assert(lines()[2] == "helper()" and not edit.pending(),
  "redo should remain the user's normal editor action after undo")

reset({ "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "helper()\n"))
vim.cmd("undo")
vim.cmd("redo")
assert(vim.wait(500, function() return not edit.pending() end, 10),
  "undo should clear review even if the user redoes before the scheduled cleanup")
assert(lines()[2] == "helper()", "rapid redo should remain under the user's control")

reset({ "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "helper()\n"))
api.nvim_buf_set_lines(source, 0, 1, false, { "later user edit" })
vim.cmd("undo")
vim.wait(30)
assert(edit.pending() and lines()[2] == "helper()" and lines()[1] == "alpha",
  "undoing a later user edit should keep the proposal under review")
vim.cmd("undo")
assert(vim.wait(500, function() return not edit.pending() end, 10),
  "the next undo should remove the proposal and its controls")

reset({ "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "helper()\n"))
api.nvim_buf_set_lines(source, 0, 1, false, { "user edited alpha" })
local edited = lines()
assert(not edit.reject(), "Reject should refuse to overwrite a later user edit")
assert(vim.deep_equal(lines(), edited), "a refused Reject must not mutate any buffer line")
assert(edit.accept() and vim.deep_equal(lines(), edited), "Accept should keep the user's later edits")

reset({ "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
api.nvim_buf_set_lines(source, 0, 1, false, { "new alpha" })
local stale = lines()
assert(not edit.show(target, "late code"), "a changed target must reject a stale proposal")
assert(vim.deep_equal(lines(), stale) and not edit.pending(),
  "a stale proposal must leave the buffer alone")

local closed = api.nvim_create_buf(true, false)
api.nvim_buf_set_lines(closed, 0, -1, false, { "temporary" })
local closed_target = {
  kind = "insert", buf = closed, path = "", start_row = 0, start_col = 0,
  end_row = 0, end_col = 0, changedtick = api.nvim_buf_get_changedtick(closed),
}
api.nvim_buf_delete(closed, { force = true })
assert(not edit.show(closed_target, "late code"), "closed target should not receive a proposal")
local unloaded = api.nvim_create_buf(true, false)
api.nvim_buf_set_lines(unloaded, 0, -1, false, { "temporary" })
local unloaded_target = {
  kind = "insert", buf = unloaded, path = "", start_row = 0, start_col = 0,
  end_row = 0, end_col = 0, changedtick = api.nvim_buf_get_changedtick(unloaded),
}
api.nvim_buf_delete(unloaded, { unload = true, force = true })
assert(api.nvim_buf_is_valid(unloaded) and not api.nvim_buf_is_loaded(unloaded))
assert(not edit.show(unloaded_target, "late code"),
  "an unloaded target should reject a late proposal")

reset({ "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "pending()\n"))
api.nvim_buf_delete(source, { force = true })
assert(not edit.pending(), "closing a buffer should clear its proposal controls")

local fresh = api.nvim_create_buf(true, false)
api.nvim_win_set_buf(source_win, fresh)
api.nvim_buf_set_lines(fresh, 0, -1, false, { "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "saved()\n"))
vim.cmd("vsplit")
local reopened_win = api.nvim_get_current_win()
api.nvim_win_close(source_win, true)
source_win = reopened_win
api.nvim_set_current_win(source_win)
api.nvim_win_set_cursor(source_win, { 1, 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("j", true, false, true), "x", false)
vim.wait(30)
assert(api.nvim_get_current_win() ~= source_win and edit.pending().choice == 1,
  "controls should follow the proposal when its original source window closes")
api.nvim_feedkeys(api.nvim_replace_termcodes("k", true, false, true), "x", false)
vim.wait(30)
assert(api.nvim_get_current_win() == source_win, "leaving controls should return to the remaining source window")
local path = vim.fn.tempname() .. ".lua"
api.nvim_buf_set_name(fresh, path)
vim.cmd("write")
assert(not edit.pending() and table.concat(vim.fn.readfile(path), "|"):find("saved()", 1, true),
  "saving should accept the visible proposal")
vim.fn.delete(path)

api.nvim_buf_set_lines(fresh, 0, -1, false, { "alpha", "beta", "gamma" })
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "saved after edit()\n"))
api.nvim_buf_set_lines(fresh, 0, 1, false, { "user's later edit" })
vim.cmd("write")
local saved = table.concat(vim.fn.readfile(path), "|")
assert(not edit.pending() and saved:find("user's later edit", 1, true)
  and saved:find("saved after edit()", 1, true),
  "save-to-accept should keep both the proposal and later user edits")
vim.fn.delete(path)

api.nvim_buf_set_lines(fresh, 0, -1, false,
  { string.rep("a very long source line ", 8), "tail" })
vim.cmd("vsplit")
local spare_win = api.nvim_get_current_win()
api.nvim_win_set_buf(spare_win, api.nvim_create_buf(false, true))
api.nvim_win_set_width(source_win, 30)
api.nvim_set_option_value("wrap", true, { win = source_win })
api.nvim_set_current_win(source_win)
api.nvim_win_set_cursor(source_win, { 2, 0 })
target = edit.insertion()
assert(edit.show(target, "wrapped()\n", nil, string.rep("reason with several words ", 5)))
local ns = api.nvim_get_namespaces()["pair.nvim.control"]
local marks = api.nvim_buf_get_extmarks(fresh, ns, 0, -1, { details = true })
local controls = marks[1][4].virt_lines
local last = controls[#controls]
local control_text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, last))
assert(vim.fn.strdisplaywidth(control_text) <= api.nvim_win_get_width(source_win) - 4,
  "Accept, Reject, and Diff should fit in a narrow wrapped source pane")
assert(#controls > 2, "long rationale should wrap above the controls")
api.nvim_feedkeys(api.nvim_replace_termcodes("j", true, false, true), "x", false)
vim.wait(30)
assert(api.nvim_get_current_win() ~= source_win and edit.pending().choice == 1,
  "j should focus compact controls in a narrow wrapped pane")
api.nvim_win_set_width(source_win, 25)
api.nvim_exec_autocmds("WinResized", {})
vim.wait(30)
assert(api.nvim_get_current_win() ~= source_win and edit.pending().choice == 1,
  "resizing while controls are focused should keep the same review choice")
api.nvim_feedkeys(api.nvim_replace_termcodes("d", true, false, true), "x", false)
vim.wait(30)
assert(#api.nvim_list_tabpages() == 2, "d should open the diff from compact controls")
assert(edit.close_diff(), "compact diff should return to review")
assert(edit.reject(), "wrapped proposal should remain rejectable")
api.nvim_win_close(spare_win, true)

print("Pair proposal review edge tests passed")
