vim.opt.rtp:append(vim.fn.getcwd())
local plugin = vim.fn.getcwd()
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
local fake = root .. "/bin/opencode"
vim.fn.writefile({ "#!/bin/sh", "exec python3 " .. vim.fn.shellescape(plugin .. "/tests/mock_acp.py") .. ' "$@"' }, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")
vim.env.PATH = root .. "/bin:" .. vim.env.PATH
vim.env.PAIR_MOCK_FREE_ERROR = "1"
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.notify = function() end
local pair = require("pair")
local sessions = require("pair.sessions")
pair.setup({ backend = "opencode", keymaps = false })
local record = assert(sessions.current(vim.fn.getcwd(), "opencode"))
local function transcript()
  return vim.inspect(assert(sessions.read_transcript(record)))
end
pair.send("test free access")
assert(vim.wait(4000, function() return transcript():find("external clients", 1, true) end, 10))
assert(transcript():find("opencode auth login", 1, true))
assert(transcript():find(":PairModel", 1, true))
assert(transcript():find(":PairNew will not remove this restriction", 1, true))
pair.model("mock/model")
assert(vim.wait(4000, function() return sessions.read_model(record) == "mock/model" end, 10))
pair.send("provider model access")
assert(vim.wait(4000, function() return transcript():find("hello world", 1, true) end, 10))
vim.fn.delete(root, "rf")
print("Pair OpenCode access guidance tests passed")
