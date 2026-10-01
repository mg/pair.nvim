vim.opt.rtp:append(vim.fn.getcwd())
if not require("pair.command_sandbox").available() then
  print("Antigravity model checks require a filesystem sandbox")
  return
end
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/bin", "p")
vim.fn.mkdir(root .. "/generated", "p")
vim.fn.writefile({ "source unchanged" }, root .. "/source.txt")
local fake = root .. "/bin/agy"
vim.fn.writefile(vim.fn.readfile("tests/mock_antigravity.py"), fake)
vim.fn.setfperm(fake, "rwxr-xr-x")
local home = vim.fn.stdpath("state") .. "/pair/antigravity/" .. vim.fn.sha256(root)
vim.fn.mkdir(home .. "/scratch", "p")
local trace = home .. "/scratch/launch.jsonl"
vim.env.GEMINI_API_KEY = "mock-key"
vim.env.PAIR_AGY_TRACE = trace
local errors = {}
local client = require("pair.antigravity").new({
  command = fake, cwd = root, session_file = root .. "/session",
  writable_paths = { "generated" }, on_update = function() end,
  on_error = function(err) errors[#errors + 1] = err end,
})
local function wait(test, label)
  assert(vim.wait(4000, test, 10), label)
end
local started
client:start(function(session, err) started = { session = session, err = err } end)
assert(started.session and not started.err)
wait(function() return vim.fn.filereadable(trace) == 1 and #vim.fn.readfile(trace) > 0 end,
  "initial process launch")
local choices
client:list_models(function(items, err) assert(not err, vim.inspect(err)); choices = items end)
wait(function() return choices ~= nil end, "catalog")
assert(#choices == 2 and choices[2].label == "Second model")
local function switch(model)
  local done
  client:set_model(model, function(selected, err) done = { selected = selected, err = err } end)
  wait(function() return done ~= nil end, "model switch")
  assert(done.selected == model and not done.err, vim.inspect(done))
  assert(client.ready and client.model == model)
end
local function prompt(text)
  local done
  client:prompt(text, function(result, err) done = { result = result, err = err } end)
  wait(function() return done ~= nil end, "prompt after switching")
  assert(done.result and not done.err, vim.inspect(done))
end
switch("mock-first") -- A picker can change the model before the first prompt.
prompt("pair-test-read")
local id = client.session_id
switch("mock-second")
assert(client.session_id == id, "model switch lost the saved conversation")
prompt("pair-test-write-command")
prompt("pair-test-generate")
assert(vim.fn.readfile(root .. "/source.txt")[1] == "source unchanged")
assert(vim.fn.readfile(root .. "/generated/output.txt")[1] == "generated")
local rejected
client:set_model("unavailable", function(_, err) rejected = err end)
assert(rejected and client.model == "mock-second" and client.ready)
client.launch_env.PAIR_AGY_MODELS_FAIL = "1"
local catalog_error
client:list_models(function(_, err) catalog_error = err end)
wait(function() return catalog_error ~= nil end, "catalog failure")
assert(catalog_error.message:find("catalog unavailable", 1, true))
client.launch_env.PAIR_AGY_MODELS_FAIL = nil
assert(client.ready, "catalog failure must not stop the conversation")
local cancelled
client:set_model("mock-first", function(_, err) cancelled = err end)
client:stop()
assert(cancelled and cancelled.message:find("stopped", 1, true))
vim.wait(50, function() return false end, 10)
assert(not client.ready and #errors == 0, "stale process events changed the stopped client")
local launches = vim.fn.readfile(trace)
assert(#launches == 3)
local last = vim.json.decode(launches[3])
assert(last.args[vim.fn.index(last.args, "--model") + 2] == "mock-second")
assert(last.args[vim.fn.index(last.args, "--conversation") + 2] == id)
vim.fn.delete(home, "rf")
vim.fn.delete(root, "rf")
print("Pair Antigravity model switching tests passed")
