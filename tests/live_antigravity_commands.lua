-- Opt-in: uses the installed agy CLI and its account in a disposable project.
vim.opt.rtp:append(vim.fn.getcwd())
local Client = require("pair.antigravity")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/generated", "p")
vim.fn.writefile({ "original source" }, root .. "/source.txt")
vim.fn.writefile(vim.split([[
import os, pathlib, tempfile
root = pathlib.Path(__file__).resolve().parent
assert (root / 'source.txt').read_text() == 'original source\n'
try:
    (root / 'source.txt').write_text('unexpected source edit')
except PermissionError:
    pass
except OSError as error:
    assert error.errno == 30
else:
    raise AssertionError('source write was allowed')
(root / 'generated/result.txt').write_text('generated output')
with tempfile.TemporaryFile(mode='w+') as scratch:
    scratch.write('temporary test output')
print('PAIR_COMMAND_CHECK_PASSED')
]], "\n", { plain = true }), root .. "/check.py")
local updates, finished, started = {}, nil, nil
local client = Client.new({ cwd = root, writable_paths = { "generated" },
  session_file = root .. "/session", model = vim.env.PAIR_LIVE_MODEL,
  on_update = function(update)
    updates[#updates + 1] = update
  end,
  on_error = function(message) error(message) end,
})
local ok, failure = pcall(function()
  client:start(function(result, err) started = { result = result, err = err } end)
  assert(vim.wait(5000, function() return started ~= nil end, 20))
  assert(started.result, vim.inspect(started.err))
  client:prompt("Run `python3 " .. root .. "/check.py` once using run_command with Cwd set to " .. root .. ". This disposable test fixture checks that ordinary source writes fail, generated output can be written, and temporary test files work. Report the command's stdout. Do not edit any files yourself.",
    function(result, err) finished = { result = result, err = err } end)
  assert(vim.wait(90000, function() return finished ~= nil end, 50), "Antigravity command timed out")
  assert(finished.result and not finished.err, vim.inspect(finished))
  assert(vim.fn.readfile(root .. "/source.txt")[1] == "original source")
  assert(vim.fn.readfile(root .. "/generated/result.txt")[1] == "generated output")
  local completed, response = nil, ""
  for _, update in ipairs(updates) do
    if update.name == "run_command" and update.status == "completed" then completed = true end
    if update.content then response = response .. update.content.text end
  end
  assert(completed, "No successful command tool event")
  assert(response:find("PAIR_COMMAND_CHECK_PASSED", 1, true), "Agent did not receive the test result")
end)
client:stop()
vim.fn.delete(vim.fn.stdpath("state") .. "/pair/antigravity/" .. vim.fn.sha256(root), "rf")
vim.fn.delete(root, "rf")
assert(ok, failure)
print("Live Antigravity command, generated output, scratch, and source protection checks passed")
