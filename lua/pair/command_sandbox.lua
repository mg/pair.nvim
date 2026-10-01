local uv = vim.uv or vim.loop
local M = {}

local function within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function check_output_tree(path, budget, depth)
  if depth > 64 then return nil, "Choose a shallower output directory (maximum depth: 64)" end
  local scan, err = uv.fs_scandir(path)
  if not scan then return nil, "Cannot inspect command output directory: " .. tostring(err) end
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then return true end
    budget.left = budget.left - 1
    if budget.left < 0 then return nil, "Choose a narrower output directory (inspection limit: 10000 entries)" end
    if name == ".git" then return nil, "Command output directories cannot contain Git metadata" end
    local child = path .. "/" .. name
    local stat = uv.fs_lstat(child)
    if not stat then return nil, "Command output directory changed during inspection" end
    if stat.type == "file" and stat.nlink > 1 then
      return nil, "Command output directories cannot contain hard-linked files: " .. child
    end
    if stat.type == "directory" then
      local ok, child_err = check_output_tree(child, budget, depth + 1)
      if not ok then return nil, child_err end
    end
  end
end

function M.available()
  if vim.fn.has("macunix") == 1 and vim.fn.executable("/usr/bin/sandbox-exec") == 1 then
    return "seatbelt"
  end
  if uv.os_uname().sysname == "Linux" and vim.fn.executable("bwrap") == 1 then
    return "bubblewrap"
  end
  return nil, "Protected commands require macOS sandbox-exec or Linux bubblewrap (bwrap)"
end

-- Resolve once before launching. Never grant a workspace root, Git metadata,
-- or a symlink that redirects an output directory to some other location.
function M.outputs(cwd, paths)
  local root = uv.fs_realpath(cwd)
  if not root then return nil, "Command workspace does not exist" end
  local outputs = {}
  if type(paths) ~= "table" or not vim.islist(paths) then
    return nil, "commands.writable_paths must be a list of relative output directories"
  end
  for _, path in ipairs(paths) do
    if type(path) ~= "string" or path == "" or path:find("[%c]")
      or path:sub(1, 1) == "/" then
      return nil, "Command output paths must be relative directories inside the workspace"
    end
    local parts = vim.split(path, "/", { plain = true, trimempty = true })
    local current = root
    for _, part in ipairs(parts) do
      if part == "." or part == ".." or part == ".git" then
        return nil, "Command output paths cannot include '.', '..', or '.git'"
      end
      current = current .. "/" .. part
      local stat = uv.fs_lstat(current)
      if not stat or stat.type ~= "directory" then
        return nil, "Create the command output directory first (no symlinks): " .. path
      end
    end
    local resolved = uv.fs_realpath(current)
    if not resolved or resolved == root or not within(resolved, root) then
      return nil, "Command output paths must not grant the whole workspace"
    end
    local safe, tree_err = check_output_tree(resolved, { left = 10000 }, 0)
    if not safe then return nil, tree_err end
    outputs[#outputs + 1] = resolved
  end
  return outputs
end

function M.wrap(command, args, opts)
  local engine, err = M.available()
  if not engine then return nil, err end
  local root = uv.fs_realpath(opts.cwd)
  local outputs, output_err = M.outputs(opts.cwd, opts.writable_paths or {})
  if not outputs then return nil, output_err end
  local writable = vim.deepcopy(outputs)
  for _, path in ipairs(opts.state_paths or {}) do
    local real = uv.fs_realpath(path)
    if not real or within(real, root) or within(root, real) then
      return nil, "Agent state and temporary directories must be outside the workspace: " .. path
    end
    writable[#writable + 1] = real
  end
  local executable = vim.fn.exepath(command)
  if executable == "" then return nil, "Command executable not found: " .. command end
  if engine == "seatbelt" then
    local rules = { "(version 1)", "(allow default)", "(deny file-write*)" }
    for _, path in ipairs(writable) do
      rules[#rules + 1] = "(allow file-write* (subpath " .. vim.json.encode(path) .. "))"
    end
    rules[#rules + 1] = '(allow file-write* (literal "/dev/null") (literal "/dev/tty"))'
    rules[#rules + 1] = '(allow file-write* (literal "/dev/ptmx") (regex #"^/dev/(ttys|pty)[a-zA-Z0-9]+$"))'
    -- Also protect nested repositories inside an approved output directory.
    rules[#rules + 1] = '(deny file-write* (regex #"/\\.git(/|$)"))'
    local wrapped = { "-p", table.concat(rules, "\n"), executable }
    vim.list_extend(wrapped, args)
    return { command = "/usr/bin/sandbox-exec", args = wrapped, engine = engine }
  end
  local wrapped = { "--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc",
    "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev" }
  for _, path in ipairs(writable) do
    vim.list_extend(wrapped, { "--bind", path, path })
  end
  local git = root .. "/.git"
  if uv.fs_stat(git) then vim.list_extend(wrapped, { "--ro-bind", git, git }) end
  vim.list_extend(wrapped, { "--chdir", root, "--", executable })
  vim.list_extend(wrapped, args)
  return { command = vim.fn.exepath("bwrap"), args = wrapped, engine = engine }
end

return M
