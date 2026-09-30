vim.opt.rtp:append(vim.fn.getcwd())

local path = vim.fn.getcwd() .. "/tests/mock_codex.py"
local root, pointer, params = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.setenv("PAIR_MOCK_CODEX_PARAMS", params)
local client = require("pair.app_server").new({
  command = path, cwd = root, session_file = pointer,
  on_update = function() end, on_error = function(message) error(message) end,
})

local started, start_err
client:start(function(session, err) started, start_err = session, err end)
assert(vim.wait(4000, function() return started or start_err end, 20), "Codex mock should start")
assert(started and not start_err, "Codex mock startup should succeed")

local choices, list_err
client:list_models(function(list, err) choices, list_err = list, err end)
assert(vim.wait(4000, function() return choices or list_err end, 20), "Codex models should be listed")
assert(choices and #choices == 2 and choices[2].value == "mock-codex-alt", "Codex list should expose values")

local rejected
client:set_model("not-in-catalog", function(_, err) rejected = err end)
assert(vim.wait(4000, function() return rejected end, 20), "unsupported model should be rejected")
assert(rejected.message:find("not available", 1, true), "unsupported model should explain itself")

local selected
client:set_model("mock-codex-alt", function(model, err) assert(not err); selected = model end)
assert(vim.wait(4000, function() return selected end, 20), "alternate model should select")
local finished
client:prompt("hello", function(result, err) assert(not err); finished = result end)
assert(vim.wait(4000, function() return finished end, 20), "turn should finish")
local sent = false
for _, line in ipairs(vim.fn.readfile(params)) do
  local entry = vim.json.decode(line)
  if entry.method == "turn/start" and entry.params.model == "mock-codex-alt" then sent = true end
end
assert(sent, "selected Codex model should be sent on the next turn")
client:stop()
vim.fn.delete(pointer)
vim.fn.delete(params)
vim.fn.delete(root, "rf")
print("Pair Codex model picker tests passed")
