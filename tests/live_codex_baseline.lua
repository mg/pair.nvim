-- Opt-in live Codex check. Contacts the account, uses quota, and only opens a temporary workspace.
vim.opt.rtp:append(vim.fn.getcwd())

local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/sample.lua"
local nonce = vim.fn.sha256(root):sub(1, 8)
local disk = "local value = 0 -- PAIR_DISK_" .. nonce
local live = "local value = 7 -- PAIR_EDITOR_" .. nonce
vim.fn.writefile({ disk, "return value" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source_buf, 0, 1, false, { live })

local pair = require("pair")
local edit = require("pair.edit")
local sessions = require("pair.sessions")
pair.setup({ keymaps = false })
vim.v.errmsg = ""
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root)
local report = { backend = "codex", disk_unchanged = false }

local function wait_for(test, label)
  assert(vim.wait(90000, test, 50), "Timed out: " .. label)
end
local function transcript(record)
  return assert(sessions.read_transcript(record))
end
local function has_text(record, needle)
  for _, entry in ipairs(transcript(record)) do
    if entry.text:find(needle, 1, true) then return true end
  end
  return false
end
local function source() api.nvim_set_current_win(source_win) end
local function ready()
  local header = vim.fn.bufnr("pair://header")
  return header ~= -1 and table.concat(api.nvim_buf_get_lines(header, 0, -1, false), " "):find("Ready", 1, true) ~= nil
end

local ok, failure = pcall(function()
  local first = assert(sessions.current(root, "codex"))
  source()
  vim.cmd("normal! gg0V\27")
  pair.change("The selected Lua line declares value as 7. Replace it with exactly: local value = 8")
  wait_for(function() return edit.pending() ~= nil or has_text(first, "Agent did not return a valid replacement") end,
    "live Change proposal")
  assert(edit.pending(), "Codex did not return a usable Change proposal")
  local proposed = api.nvim_buf_get_lines(source_buf, 0, 1, false)[1]
  assert(proposed == "local value = 8", "unexpected Change proposal: " .. proposed)
  report.change = true
  assert(edit.reject(), "could not reject live Change proposal")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == live,
    "Reject did not restore the unsaved line")

  source()
  api.nvim_win_set_cursor(source_win, { 2, 0 })
  pair.here("Insert exactly this Lua line at the cursor, followed by a newline: local doubled = value * 2")
  wait_for(function() return edit.pending() ~= nil or has_text(first, "Agent did not return a valid replacement") end,
    "live Insert proposal")
  assert(edit.pending(), "Codex did not return a usable Insert proposal")
  local inserted = api.nvim_buf_get_lines(source_buf, 1, 2, false)[1]
  assert(inserted == "local doubled = value * 2", "unexpected Insert proposal: " .. inserted)
  report.insert = true
  assert(edit.accept(), "could not accept live Insert proposal")

  source()
  pair.send("Write 80 short numbered lines explaining Lua local variables. Keep each line distinct.")
  wait_for(function()
    for _, entry in ipairs(transcript(first)) do
      if entry.role == "Agent" and entry.text ~= "…" then return true end
    end
  end, "live streamed chat before cancellation")
  pair.cancel()
  wait_for(function() return has_text(first, "Request cancelled") end, "live cancellation")
  report.cancel = true

  pair.new_session()
  local second = assert(sessions.current(root, "codex"))
  assert(second.id ~= first.id)
  local selected
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if item.id == first.id then selected = item; break end
    end
    callback(selected)
  end
  pair.pick_session()
  wait_for(function() return sessions.current(root, "codex").id == first.id end,
    "live Codex thread resume")
  report.resume = true
  source()
  pair.send("Reply with exactly READY.")
  wait_for(function()
    for _, entry in ipairs(transcript(first)) do
      if entry.role == "Agent" and entry.text:find("READY", 1, true) then return true end
    end
  end, "live follow-up on resumed thread")
  wait_for(ready, "resumed Codex turn completion")
  report.follow_up = true

  local marker = root .. "/agent-write-attempt.txt"
  local before = #transcript(first)
  source()
  pair.send("For a sandbox check, try to run this shell command, then report whether it succeeded: printf test > "
    .. marker .. ". Do not use Pair's editor proposal path for this check.")
  wait_for(function()
    for index, entry in ipairs(transcript(first)) do
      if index > before and entry.role == "Agent" and entry.text ~= "…" then return true end
    end
  end, "live write-attempt response")
  wait_for(ready, "live write-attempt turn completion")
  assert(vim.fn.filereadable(marker) == 0, "Codex wrote a file despite Pair's read-only settings")
  report.write_blocked = true
end)

if edit.pending() then pcall(edit.reject) end
pair.cancel()
report.disk_unchanged = vim.fn.readfile(path)[1] == disk
report.editor_kept_insert = api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local doubled = value * 2"
if vim.v.errmsg ~= "" then
  report.nvim_error = vim.v.errmsg
  ok, failure = false, "Neovim reported an asynchronous error: " .. vim.v.errmsg
end
if not ok then report.error = tostring(failure) end
vim.fn.delete(base .. ".records", "rf")
vim.fn.delete(base .. ".sessions.json")
vim.fn.delete(root, "rf")
print(vim.json.encode(report))
assert(ok, tostring(failure))
