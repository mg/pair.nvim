-- Opt-in: uses the existing agy login and account quota in a temporary project.
vim.opt.rtp:append(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
vim.fn.writefile({ "local value = 1" }, root .. "/sample.lua")
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/sample.lua"))
local nonce = "PAIR_SWITCH_" .. vim.fn.sha256(root):sub(1, 12)
local pair = require("pair")
local Client = require("pair.antigravity")
local handle = Client._handle
local reported_models = {}
function Client:_handle(event)
  if event.event == "init" then reported_models[#reported_models + 1] = (event.init or {}).model end
  handle(self, event)
end
local sessions = require("pair.sessions")
local prefs = require("pair.preferences")
pair.setup({ backend = "antigravity", keymaps = false })
local failures = {}
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then failures[#failures + 1] = message end
end
local function wait(test, label)
  assert(vim.wait(90000, function() return #failures > 0 or test() end, 25), label)
  assert(#failures == 0, table.concat(failures, "\n"))
end
local function ready()
  local header = vim.fn.bufnr("pair://header")
  return header ~= -1 and table.concat(vim.api.nvim_buf_get_lines(header, 0, -1, false), " "):find("Ready", 1, true)
end
local record = assert(sessions.current(root, "antigravity"))
pair.chat()
local catalog
vim.ui.select = function(items, _, callback)
  catalog = items
  callback(nil)
end
local ok, failure = pcall(function()
  pair.model()
  wait(function() return catalog ~= nil end, "live model catalog")
  local function find(value)
    for _, choice in ipairs(catalog) do if choice.value == value then return choice.value end end
  end
  local first = find(vim.env.PAIR_LIVE_MODEL or "gemini-3.8-flash-low") or catalog[1].value
  local second = find(vim.env.PAIR_LIVE_SECOND_MODEL or "gemini-3.8-flash-medium")
  if not second or second == first then
    for _, choice in ipairs(catalog) do if choice.value ~= first then second = choice.value; break end end
  end
  assert(second and second ~= first, "account must offer at least two models")
  pair.model(first)
  wait(function() return sessions.read_model(record) == first and ready() end, "select first model")
  pair.send("Remember this secret token for our conversation: " .. nonce .. ". Reply only with OK.")
  wait(function() return vim.fn.filereadable(record.session) == 1 and ready() end, "first live turn")
  local id = vim.fn.readfile(record.session)[1]
  assert(reported_models[#reported_models] == first, "CLI did not report the first selected model")
  pair.model(second)
  wait(function() return sessions.read_model(record) == second and ready() end, "switch model")
  assert(vim.fn.readfile(record.session)[1] == id, "model switch changed the conversation ID")
  pair.send("What token did I ask you to remember in my previous message? Reply with only that token.")
  wait(function()
    for _, entry in ipairs(assert(sessions.read_transcript(record))) do
      if entry.role == "Agent" and entry.text:find(nonce, 1, true) and ready() then return true end
    end
  end, "same conversation recall after model switch")
  assert(reported_models[#reported_models] == second, "CLI did not report the second selected model")
  assert(prefs.read().backend == "antigravity" and prefs.read().models.antigravity == second)
  pair.new_session()
  local fresh = assert(sessions.current(root, "antigravity"))
  assert(fresh.id ~= record.id)
  local selected
  vim.ui.select = function(items, options, callback)
    for _, item in ipairs(items) do
      if options.format_item(item):sub(1, 3) == "●" then selected = item.value end
    end
    callback(nil)
  end
  pair.model()
  wait(function() return selected ~= nil end, "model after PairNew")
  assert(selected == second, "PairNew forgot the selected model")
  assert(vim.fn.readfile(root .. "/sample.lua")[1] == "local value = 1")
  print(vim.json.encode({ catalog_count = #catalog, first_model = first, second_model = second,
    same_conversation = true, recall = true, pairnew_model = selected, source_unchanged = true }))
end)
vim.cmd("doautocmd VimLeavePre")
vim.fn.delete(root, "rf")
if not ok then error(failure) end
