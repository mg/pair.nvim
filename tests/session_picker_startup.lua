vim.opt.rtp:append(vim.fn.getcwd())

local plugin_root = vim.fn.getcwd()
local root, trace = vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()

local sessions = require("pair.sessions")
local record = assert(sessions.current(root, "mock"))
assert(sessions.save_transcript(record.transcript, {
  { role = "You", text = "earlier conversation" },
  { role = "Agent", text = "saved answer" },
}))
vim.fn.writefile({ "mock-session" }, record.session)

local pair = require("pair")
pair.setup({
  backend = "mock", keymaps = false,
  agents = { mock = {
    kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_TRACE = trace }, required_mode = "plan", restricted = true,
  } },
})
pair.chat()

local function pane(name)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == "pair://" .. name then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end

assert(pane("chat"):find("earlier conversation", 1, true)
  and pane("header"):find("Reconnect", 1, true),
  "startup transcript should be marked as awaiting agent reconnection")

local original_select = vim.ui.select
local options, choose
vim.ui.select = function(items, _, callback) options, choose = items, callback end
pair.pick_session()
assert(#options == 1 and options[1].active,
  "the active record should be offered for reconnection")
choose(options[1])
assert(vim.wait(4000, function()
  return pane("header"):find("Ready", 1, true) ~= nil
end), "choosing the active record should verify its saved agent session")
assert(pane("chat"):find("earlier conversation", 1, true)
  and assert(sessions.current(root, "mock")).id == record.id,
  "reconnection should retain the same transcript and record")
local loaded = 0
for _, method in ipairs(vim.fn.readfile(trace)) do
  if method == "session/load" then loaded = loaded + 1 end
end
assert(loaded == 1, "active session reconnection should use session/load")

vim.ui.select = original_select
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".mock"
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair startup session reconnection tests passed")
