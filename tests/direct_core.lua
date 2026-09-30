vim.opt.rtp:append(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.writefile({ "saved marker", "return true" }, root .. "/src/main.lua")
vim.fn.writefile({ "secret" }, root .. "/.env")
local outside = vim.fn.tempname()
vim.fn.writefile({ "outside marker" }, outside)
assert((vim.uv or vim.loop).fs_symlink(outside, root .. "/src/outside"))
local large = io.open(root .. "/src/large.txt", "wb")
large:write(string.rep("x", 70000)); large:close()
local binary = io.open(root .. "/src/binary.bin", "wb")
binary:write("a\0b"); binary:close()
vim.fn.system({ "git", "-C", root, "init", "-q" })
vim.fn.system({ "git", "-C", root, "add", "src/main.lua" })
vim.fn.system({ "git", "-C", root, "-c", "user.name=Pair Test", "-c",
  "user.email=pair@example.test", "commit", "-qm", "baseline" })
vim.fn.writefile({ "saved marker", "return false" }, root .. "/src/main.lua")
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/src/main.lua"))
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, 1, false, { "live marker" })
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/src/new.lua"))
api.nvim_buf_set_lines(0, 0, -1, false, { "new live marker" })

local Research = require("pair.research")
local research = assert(Research.new({ root = root }))
local names = {}
for _, tool in ipairs(research:tools()) do names[tool.name] = true end
assert(names.list_files and names.read_file and names.search_text and names.git_status
  and names.git_diff and names.write_file == nil and names.run_command == nil)
local read = research:call("read_file", { path = "src/main.lua" })
assert(read.ok and read.source == "buffer" and read.content:find("live marker", 1, true)
  and not read.content:find("saved marker", 1, true))
assert(research:call("read_file", { path = "src/new.lua" }).content:find("new live marker", 1, true))
local listed = research:call("list_files", {})
assert(listed.ok and listed.content:find("src/new.lua", 1, true)
  and not listed.content:find(".env", 1, true)
  and not listed.content:find("outside", 1, true))
local search = research:call("search_text", { query = "live marker" })
assert(search.ok and search.content:find("src/main.lua:1:live marker", 1, true)
  and not search.content:find("saved marker", 1, true))
for _, path in ipairs({ "../outside", "/etc/passwd", ".env", "src/outside", "src/../.env",
  "src/binary.bin", "src/large.txt" }) do
  assert(not research:call("read_file", { path = path }).ok, "unsafe read passed: " .. path)
end
assert(not research:call("read_file", { path = "src/main.lua", extra = true }).ok)
assert(not research:call("write_file", { path = "src/main.lua" }).ok)
assert(not research:call("search_text", { query = string.rep("x", 201) }).ok)
local status = research:call("git_status", {})
assert(status.ok and status.content:find("src/main.lua", 1, true))
local diff = research:call("git_diff", { path = "src/main.lua" })
assert(diff.ok and diff.content:find("return false", 1, true))
assert(not research:call("git_diff", { path = "../outside" }).ok)
assert(not research:call("git_diff", {}).ok)
local limited = assert(Research.new({ root = root, limits = { max_output_bytes = 8 } }))
assert(not limited:call("read_file", { path = "src/main.lua" }).ok)
assert(limited:call("list_files", {}).truncated)
assert(limited:call("git_status", {}).truncated)
local one_file = assert(Research.new({ root = root, limits = { max_files = 1 } }))
assert(one_file:call("search_text", { query = "live marker" }).content
  :find("src/main.lua:1:live marker", 1, true), "live buffers should win a small file budget")

local Session = require("pair.direct_session")
local state = root .. "/direct.json"
local session = assert(Session.new({ path = state }))
assert(session:append({ role = "user", content = "Inspect the code" }))
assert(session:append({ role = "assistant", content = "", tool_calls = {
  { id = "call-1", name = "read_file", arguments = { path = "src/main.lua" } },
} }))
assert(not session:append({ role = "user", content = "Too early" }))
assert(not session:append({ role = "tool", tool_call_id = "unknown", content = "bad" }))
assert(session:append({ role = "tool", tool_call_id = "call-1", content = read.content }))
assert(session:append({ role = "assistant", content = "The live marker is present." }))
assert(not session:append({ role = "assistant", content = "", tool_calls = {
  { id = "call-1", name = "read_file", arguments = {} },
} }))
assert(session:save())
local restored = assert(Session.load(state))
assert(#restored:history() == 4 and next(restored:pending()) == nil)
local copied = restored:history()
copied[1].content = "tampered"
assert(restored:history()[1].content == "Inspect the code")
vim.bo[buf].modified = false
vim.fn.delete(root, "rf")
vim.fn.delete(outside)
print("Pair direct research core tests passed")
