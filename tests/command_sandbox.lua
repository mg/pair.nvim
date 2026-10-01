vim.opt.rtp:append(vim.fn.getcwd())
local sandbox = require("pair.command_sandbox")
local uv = vim.uv
local root = vim.fn.tempname()
local external = vim.fn.tempname()
vim.fn.mkdir(root .. "/generated", "p")
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.mkdir(external, "p")
vim.fn.writefile({ "original source" }, root .. "/source.txt")
vim.fn.writefile({ "original index" }, root .. "/.git/index")
vim.fn.writefile({ "external" }, external .. "/source.txt")
assert(sandbox.outputs(root, { "generated" }))
for _, path in ipairs({ ".", "../", "/tmp", ".git", "generated/..", "missing", "/" }) do
  assert(not sandbox.outputs(root, { path }), "unsafe output path accepted: " .. path)
end
assert(uv.fs_symlink(root, root .. "/generated/alias"))
assert(not sandbox.outputs(root, { "generated/alias" }), "symlink output directory accepted")
assert(uv.fs_link(root .. "/source.txt", root .. "/generated/hardlink.txt"))
assert(not sandbox.outputs(root, { "generated" }), "hardlink alias could bypass source protection")
vim.fn.delete(root .. "/generated/hardlink.txt")

local engine = sandbox.available()
if engine then
  local python = [[
import os, pathlib, pty, subprocess, sys
master, slave = pty.openpty()
os.close(master)
os.close(slave)
root, external = map(pathlib.Path, sys.argv[1:])
assert (root / 'source.txt').read_text() == 'original source\n'
for file in [root / 'source.txt', root / 'new.txt', root / '.git/index', external / 'source.txt']:
    try:
        file.write_text('must not write')
    except PermissionError:
        pass
    except OSError as error:
        assert error.errno == 30, error # Linux read-only mount
    else:
        raise AssertionError('source write was allowed: ' + str(file))
(root / 'generated/output.txt').write_text('generated')
try:
    (root / 'generated/alias/source.txt').write_text('symlink escape')
except OSError:
    pass
else:
    raise AssertionError('symlink escaped protection')
child = subprocess.run([sys.executable, '-c', 'import pathlib,sys;pathlib.Path(sys.argv[1]).write_text("child write")', str(root / 'source.txt')], capture_output=True)
assert child.returncode != 0, 'child process escaped protection'
print('commands completed')
]]
  local launch = assert(sandbox.wrap("python3", { "-c", python, root, external }, {
    cwd = root, writable_paths = { "generated" },
  }))
  local result = vim.system(vim.list_extend({ launch.command }, launch.args), { text = true }):wait(5000)
  assert(result.code == 0, result.stderr)
  assert(result.stdout == "commands completed\n")
  assert(vim.fn.readfile(root .. "/generated/output.txt")[1] == "generated")
  assert(vim.fn.readfile(root .. "/source.txt")[1] == "original source")
  local no_outputs = assert(sandbox.wrap("python3", { "-c", "import pathlib;pathlib.Path('generated/default.txt').write_text('no')" }, { cwd = root }))
  result = vim.system(vim.list_extend({ no_outputs.command }, no_outputs.args), { cwd = root, text = true }):wait(5000)
  assert(result.code ~= 0 and vim.fn.filereadable(root .. "/generated/default.txt") == 0,
    "default sandbox allowed project output writes")
  assert(not sandbox.wrap("python3", {}, { cwd = root, state_paths = { root } }),
    "agent state granted writes to the workspace")
else
  print("Command execution unavailable on this host; checking fail-closed behavior")
  assert(not sandbox.wrap("python3", {}, { cwd = root }))
end
vim.fn.delete(root, "rf")
vim.fn.delete(external, "rf")
print("Pair command filesystem protection tests passed")
