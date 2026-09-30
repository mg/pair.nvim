vim.opt.rtp:append(vim.fn.getcwd())
vim.o.columns = 160

local api = vim.api
local plugin_root = vim.fn.getcwd()
local root = vim.fn.tempname()
local trace = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/sample.lua"))
local source_win = api.nvim_get_current_win()
local pair = require("pair")
pair.setup({
  backend = "mock", keymaps = false,
  agents = { mock = {
    kind = "acp", command = "python3", args = { plugin_root .. "/tests/mock_acp.py" },
    env = { PAIR_MOCK_TRACE = trace, PAIR_MOCK_START_DELAY = "0.4" },
    required_mode = "plan", restricted = true,
  } },
})

local function header()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_name(buf) == "pair://header" then
      return api.nvim_buf_get_lines(buf, 0, 1, false)[1], win, buf
    end
  end
  return ""
end

local function wait_status(needle)
  local seen = {}
  assert(vim.wait(3000, function()
    local line = header()
    seen[line] = true
    return line:find(needle, 1, true) ~= nil
  end, 10), "expected header status " .. needle .. "; saw " .. vim.inspect(vim.tbl_keys(seen)))
end

local function trace_count(method)
  if vim.fn.filereadable(trace) == 0 then return 0 end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(trace)) do if line == method then count = count + 1 end end
  return count
end

pair.chat()
local title, header_win, header_buf = header()
assert(title:find("Pair Chat", 1, true) and title:find("mock", 1, true)
  and title:find("Ready", 1, true), "idle header should identify the backend")
assert(api.nvim_win_get_height(header_win) == 1, "status must keep the existing one-row header")
api.nvim_set_current_win(source_win)
pair.send("status tool")
wait_status("Connecting")
pair.send("queued status")
assert(header():find("2 queued", 1, true), "startup should show both waiting requests")
wait_status("Chat: inspecting")
title = header()
assert(title:find("mock/default", 1, true) and title:find("1 queued", 1, true)
  and title:find("[Cancel]", 1, true), "running header should show model, action, queue, and cancel: " .. title)
assert(api.nvim_get_current_win() == source_win, "status updates must not steal source focus")
assert(trace_count("session/prompt") == 1, "second turn must remain queued")
api.nvim_win_set_width(header_win, 33)
api.nvim_exec_autocmds("WinResized", {})
title = header()
assert(title:find("mock/", 1, true) and title:find("Chat", 1, true)
  and title:find("1q", 1, true) and title:find("[X]", 1, true),
  "narrow headers should retain backend, model, action, queue, and cancel: " .. title
    .. " width=" .. api.nvim_win_get_width(header_win))

api.nvim_set_current_win(header_win)
api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
assert(vim.wait(3000, function()
  return header():find("Reconn", 1, true) ~= nil
    and not header():find("[Cancel]", 1, true) and not header():find("[X]", 1, true)
end, 10), "header Enter should cancel active work and show reconnection state")
assert(trace_count("session/prompt") == 1, "cancel should discard the queued turn")
assert(api.nvim_get_current_win() == header_win, "completion should preserve the user's current pane")
local mappings = api.nvim_buf_get_keymap(header_buf, "n")
local mouse_control = false
for _, mapping in ipairs(mappings) do
  if mapping.lhs == "<LeftMouse>" then mouse_control = true end
end
assert(mouse_control, "header should expose a clickable cancel control")

pair.new_session()
api.nvim_set_current_win(source_win)
pair.send("cancel during startup")
wait_status("Start")
api.nvim_set_current_win(header_win)
api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
assert(vim.wait(3000, function() return header():find("Ready", 1, true) ~= nil end, 10),
  "cancel should stop backend startup and restore ready status")
vim.wait(500)
assert(trace_count("session/prompt") == 1, "startup cancellation should not send a late prompt")

pair.backend("codex")
title = header()
assert(title:find("codex", 1, true) and title:find("Ready", 1, true)
  and not title:find("mock/default", 1, true), "switching backends should update header status")

pair.new_session()
local state_base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root)
for _, suffix in ipairs({ ".mock", "" }) do
  vim.fn.delete(state_base .. suffix .. ".records", "rf")
  vim.fn.delete(state_base .. suffix .. ".sessions.json")
end
vim.fn.delete(trace)
vim.fn.delete(root, "rf")
print("Pair turn status tests passed")
