-- Opt-in Copilot ACP check. Uses a configured Copilot account or BYOK provider and a temporary workspace.
vim.opt.rtp:append(vim.fn.getcwd())

local model = vim.env.PAIR_LIVE_MODEL
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
pair.setup({ backend = "copilot", models = model and { copilot = model } or {}, keymaps = false })
vim.v.errmsg = ""
local base = vim.fn.stdpath("state") .. "/pair/" .. vim.fn.sha256(root) .. ".copilot"
local report = { backend = "copilot", model = model, disk_unchanged = false }

local function wait_for(test, label)
  assert(vim.wait(90000, test, 50), "Timed out: " .. label)
end
local function transcript(record)
  return assert(sessions.read_transcript(record))
end
local function has_agent_text(record, needle)
  for _, entry in ipairs(transcript(record)) do
    if entry.role == "Agent" and entry.text:find(needle, 1, true) then return true end
  end
  return false
end
local function ready()
  local header = vim.fn.bufnr("pair://header")
  return header ~= -1 and table.concat(api.nvim_buf_get_lines(header, 0, -1, false), " "):find("Ready", 1, true) ~= nil
end
local function source() api.nvim_set_current_win(source_win) end

local ok, failure = pcall(function()
  local first = assert(sessions.current(root, "copilot"))
  pair.send("Reply with the exact first line of the attached editor snapshot, and nothing else.")
  wait_for(function() return has_agent_text(first, live) end, "live chat with unsaved buffer")
  wait_for(ready, "live chat completion")
  report.chat = true

  source()
  vim.cmd("normal! gg0V\27")
  pair.ask("Reply with the exact selected line in the editor snapshot, and nothing else.")
  wait_for(function()
    local count = 0
    for _, entry in ipairs(transcript(first)) do
      if entry.role == "Agent" and entry.text:find(live, 1, true) then count = count + 1 end
    end
    return count >= 2
  end, "live Ask with unsaved selection")
  wait_for(ready, "live Ask completion")
  edit.dismiss_answer()
  report.ask = true

  source()
  vim.cmd("normal! gg0V\27")
  pair.change("Replace the selected Lua line with exactly: local value = 8")
  wait_for(function() return edit.pending() ~= nil or has_agent_text(first, "Agent did not return a valid replacement") end,
    "live Change proposal")
  assert(edit.pending(), "Copilot did not return a usable Change proposal")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local value = 8", "unexpected Change proposal")
  assert(edit.reject(), "could not reject live Change proposal")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == live, "Reject did not restore the unsaved line")
  report.change = true

  source()
  api.nvim_win_set_cursor(source_win, { 2, 0 })
  pair.here("Insert exactly this Lua line at the cursor, followed by a newline: local doubled = value * 2")
  wait_for(function() return edit.pending() ~= nil or has_agent_text(first, "Agent did not return a valid replacement") end,
    "live Insert proposal")
  assert(edit.pending(), "Copilot did not return a usable Insert proposal")
  assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local doubled = value * 2", "unexpected Insert proposal")
  assert(edit.accept(), "could not accept live Insert proposal")
  report.insert = true

  source()
  local before_long = #transcript(first)
  pair.send("Write 80 short numbered lines explaining Lua local variables. Keep each line distinct.")
  wait_for(function()
    for index, entry in ipairs(transcript(first)) do
      if index > before_long and entry.role == "Agent" and entry.text ~= "…"
        and entry.text:find("1", 1, true) then return true end
    end
  end, "live streamed chat before cancellation")
  pair.cancel()
  wait_for(function()
    for _, entry in ipairs(transcript(first)) do
      if entry.text:find("Request cancelled", 1, true) then return true end
    end
  end, "live cancellation")
  report.cancel = true

  pair.new_session()
  local second = assert(sessions.current(root, "copilot"))
  assert(second.id ~= first.id)
  local selected
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if item.id == first.id then selected = item; break end
    end
    callback(selected)
  end
  pair.pick_session()
  wait_for(function() return sessions.current(root, "copilot").id == first.id end,
    "live Copilot session/load")
  report.resume = true
  source()
  pair.send("Reply with exactly READY.")
  wait_for(function() return has_agent_text(first, "READY") end, "live follow-up after resume")
  wait_for(ready, "resumed Copilot turn completion")
  report.follow_up = true

  local marker = root .. "/agent-write-attempt.txt"
  local before = #transcript(first)
  source()
  pair.send("For a safety check, try to create this file using an agent tool, then report whether the tool allowed it: "
    .. marker .. ". Do not return a Pair code proposal.")
  wait_for(function()
    for index, entry in ipairs(transcript(first)) do
      if index > before and entry.role == "Agent" and entry.text ~= "…" then return true end
    end
  end, "live write-attempt response")
  wait_for(ready, "live write-attempt completion")
  assert(vim.fn.filereadable(marker) == 0, "Copilot wrote a file despite Pair's restricted permissions")
  report.write_tools = {}
  for index, entry in ipairs(transcript(first)) do
    if index > before and entry.role == "Tool" then
      report.write_tools[#report.write_tools + 1] = { name = entry.text, status = entry.status }
    end
  end
  report.write_blocked = true
end)

if edit.pending() then pcall(edit.reject) end
pair.cancel()
report.disk_unchanged = vim.fn.readfile(path)[1] == disk
report.editor_kept_insert = api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local doubled = value * 2"
if ok and (not report.disk_unchanged or not report.editor_kept_insert) then
  ok, failure = false, "Copilot changed the disk file or lost the accepted editor insertion"
end
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
