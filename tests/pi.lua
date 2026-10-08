vim.opt.rtp:append(vim.fn.getcwd())
local Pi = require("pair.pi")
local backends = require("pair.backends")
local spec = assert(backends.resolve("pi", { models = { pi = "mock/other" } }))
assert(spec.kind == "pi" and spec.command == "pi" and spec.model == "mock/other")
assert(vim.tbl_contains(backends.names({}), "pi"))
local pointer = vim.fn.tempname()
local updates = {}
local opts = { command = vim.fn.getcwd() .. "/tests/mock_pi.py", cwd = vim.fn.getcwd(),
  session_file = pointer, model = "mock/other", on_update = function(u) updates[#updates + 1] = u end }
local function wait(fn)
  assert(vim.wait(3000, fn, 10), "Pi RPC timed out")
end
local function start(client)
  local done
  client:start(function(result, err) done = { result = result, err = err } end)
  wait(function() return done end)
  return done
end
local function prompt(client, message)
  local done
  client:prompt(message, function(result, err) done = { result = result, err = err } end)
  wait(function() return done end)
  return done
end
local client = Pi.new(opts)
local opened = start(client)
assert(opened.result and opened.result.model == "mock/other", vim.inspect(opened))
assert(vim.fn.filereadable(pointer) == 0, "startup must not save a pointer to an empty session")
local choices
client:list_models(function(result) choices = result end)
wait(function() return choices end)
assert(#choices == 2 and choices[2].value == "mock/other")
local answer
client:prompt("hello", function(result, err) answer = { result = result, err = err } end)
wait(function() return #updates >= 3 end)
assert(not answer, "agent_end is not completion")
wait(function() return answer end)
assert(answer.result and answer.result.stopReason == "end_turn", vim.inspect(answer))
assert(updates[1].status == "in_progress" and updates[2].status == "completed")
assert(updates[3].content.text == "hello π\u{2028}world")
local saved = vim.fn.readfile(pointer)[1]
assert(saved == opened.result.sessionId)
updates = {}
assert(prompt(client, "retry").result)
assert(updates[2].sessionUpdate == "agent_message_reset" and updates[3].content.text == "recovered")
assert(prompt(client, "error").err.message == "Authentication required")
assert(prompt(client, "reject").err.message == "Prompt rejected")
local cancelled
client:prompt("cancel", function(result, err) cancelled = { result = result, err = err } end)
client:cancel()
wait(function() return cancelled end)
assert(cancelled.result.stopReason == "cancelled", vim.inspect(cancelled))
client:stop()
client = Pi.new(opts)
assert(start(client).result.sessionId == saved, "restoration must retain the saved session path")
assert(prompt(client, "unsafe").err.message:find("outside Pair's inspection set", 1, true))
assert(not client.ready)
client = Pi.new(opts)
assert(start(client).result)
local exited = prompt(client, "exit")
assert(exited.err and not client.ready, "an unexpected exit must fail the turn")
vim.fn.delete(saved)
client = Pi.new(opts)
assert(start(client).err.message:find("saved session not found", 1, true))
vim.fn.delete(pointer)
vim.fn.delete(pointer .. ".pi", "rf")
print("Pair Pi RPC tests passed")
