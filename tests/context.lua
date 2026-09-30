vim.opt.rtp:append(vim.fn.getcwd())

local api = vim.api
local context = require("pair.context")
local path = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "saved version" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = api.nvim_get_current_buf()
local buffer_path = api.nvim_buf_get_name(buf)
vim.bo[buf].filetype = "lua"
api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved version", "second line" })

local first = assert(context.capture(buf))
assert(first.buf == buf and first.path == buffer_path and first.label == buffer_path,
  "named buffers should retain their Neovim path")
assert(first.filetype == "lua" and first.modified and type(first.endofline) == "boolean",
  "snapshot should capture buffer metadata")
assert(first.changedtick == api.nvim_buf_get_changedtick(buf), "snapshot should record the buffer version")
assert(vim.deep_equal(first.lines, { "unsaved version", "second line" }),
  "snapshot must read unsaved text from Neovim")
assert(first.scope == nil, "chat snapshots should not invent an editor scope")
assert(vim.fn.readfile(path)[1] == "saved version", "snapshot must not save the buffer")

api.nvim_buf_set_lines(buf, 0, 1, false, { "newer version" })
assert(first.lines[1] == "unsaved version", "submitted snapshot must stay fixed after more edits")
local second = assert(context.capture(buf))
assert(second.lines[1] == "newer version" and second.changedtick ~= first.changedtick,
  "the next request should capture the newer buffer")

local target = {
  kind = "replace", buf = buf, path = buffer_path, changedtick = second.changedtick,
  start_row = 0, start_col = 0, end_row = 0, end_col = 5, original = "newer",
}
local selected = assert(context.capture(buf, target))
assert(selected.scope.kind == "replace" and selected.scope.start_row == 0
  and selected.scope.end_row == 0 and selected.scope.end_col == 5
  and selected.scope.text == "newer", "characterwise scope should preserve its exact byte range")
target.linewise = true
target.end_row = 1
local linewise = assert(context.capture(buf, target))
assert(linewise.scope.linewise and linewise.scope.end_row == 2 and linewise.scope.end_col == 0,
  "linewise scopes should normalize to an exclusive end")
target.kind = "insert"
target.linewise = false
target.end_row = 0
target.end_col = 0
target.original = nil
local inserted = assert(context.capture(buf, target))
assert(inserted.scope.kind == "insert" and inserted.scope.start_row == inserted.scope.end_row,
  "insertion scope should be a zero-width position")

api.nvim_buf_set_lines(buf, 0, 1, false, { "changed again" })
local stale, stale_err = context.capture(buf, target)
assert(not stale and stale_err:find("changed while composing", 1, true),
  "an editor action must reject a target changed before submission")

local unnamed = api.nvim_create_buf(true, false)
api.nvim_buf_set_lines(unnamed, 0, -1, false, { "unnamed draft" })
local draft = assert(context.capture(unnamed))
assert(draft.path == nil and draft.label == "[No Name]" and draft.lines[1] == "unnamed draft",
  "unnamed source buffers should still be captured")

local special = api.nvim_create_buf(false, true)
vim.bo[special].buftype = "nofile"
assert(not context.capture(special), "Pair input and other special buffers must be excluded")
api.nvim_buf_delete(unnamed, { force = true })
assert(not context.capture(unnamed), "a closed buffer must not be captured")

vim.fn.delete(path)
print("Pair context snapshot tests passed")
