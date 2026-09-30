vim.opt.rtp:append(vim.fn.getcwd())
local port = assert(vim.env.PAIR_TEST_HTTP_PORT)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.cmd("cd " .. vim.fn.fnameescape(root))
root = vim.fn.getcwd()
local path = root .. "/sample.lua"
vim.fn.writefile({ "disk copy" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
local api = vim.api
local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local pair = require("pair")
local sessions = require("pair.sessions")
local edit = require("pair.edit")
pair.setup({ backend = "openai_api", keymaps = false,
  api_keys = { openai = "test-key", anthropic = "test-key", gemini = "test-key" },
  api_endpoints = {
    openai = "http://127.0.0.1:" .. port .. "/openai",
    anthropic = "http://127.0.0.1:" .. port .. "/anthropic",
    gemini = "http://127.0.0.1:" .. port .. "/gemini",
  },
  models = { openai_api = "gpt-4.1-mini", anthropic_api = "claude-sonnet-5-5",
    gemini_api = "gemini-3.8-flash" },
})
local function source() api.nvim_set_current_win(source_win) end
local function wait_for(test, label)
  assert(vim.wait(5000, test, 10), label)
end

for _, backend in ipairs({ "openai_api", "anthropic_api", "gemini_api" }) do
  if backend ~= "openai_api" then pair.backend(backend) end
  source()
  api.nvim_buf_set_lines(source_buf, 0, -1, false,
    { "local original = true", "local second = 2", "return second" })
  local record = assert(sessions.current(root, backend))
  local function transcript_has(fragment)
    local entries = assert(sessions.read_transcript(record))
    for _, entry in ipairs(entries) do
      if entry.text:find(fragment, 1, true) then return true end
    end
  end
  pair.send("hello")
  wait_for(function() return transcript_has("Hello from HTTP") end, backend .. " chat")
  wait_for(function() return vim.fn.filereadable(record.session) == 1 end,
    backend .. " completed chat")
  local model = backend == "openai_api" and "gpt-4.1-mini"
    or backend == "anthropic_api" and "claude-sonnet-5-5" or "gemini-3.8-flash"
  pair.model(model)
  wait_for(function() return sessions.read_model(record) == model end, backend .. " model")
  source()
  vim.cmd("normal! gg0V\27")
  pair.ask("Explain this line")
  wait_for(function() return transcript_has("Mock answer") end, backend .. " Ask")
  source()
  vim.cmd("normal! gg0V\27")
  pair.change("Change this line")
  wait_for(function() return edit.pending() ~= nil end, backend .. " Change")
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local changed = true")
  assert(edit.reject())
  assert(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == "local original = true")
  source()
  api.nvim_win_set_cursor(source_win, { 2, 0 })
  pair.here("Add a helper")
  wait_for(function() return edit.pending() ~= nil end, backend .. " Insert")
  assert(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "local helper = true")
  assert(edit.accept())
  assert(vim.fn.readfile(path)[1] == "disk copy")
  if backend == "openai_api" then
    pair.new_session()
    assert(sessions.current(root, backend).id ~= record.id)
    local selected, choose
    vim.ui.select = function(items, _, callback) selected, choose = items, callback end
    pair.pick_session()
    assert(selected and choose)
    local previous
    for _, item in ipairs(selected) do
      if item.id == record.id then previous = item end
    end
    assert(previous)
    choose(previous)
    wait_for(function() return sessions.current(root, backend).id == record.id end,
      "direct API session picker restore")
    local history_path = record.session .. ".json"
    local previous_count = #assert(require("pair.direct_session").load(history_path)):history()
    source()
    pair.send("continue")
    wait_for(function()
      local session = require("pair.direct_session").load(history_path)
      return session and #session:history() > previous_count
    end, "restored direct API turn saved")
  end
end
vim.fn.delete(root, "rf")
print("Pair direct API editor workflow tests passed")
