local uv = vim.uv or vim.loop
local api = vim.api

local Research = {}
Research.__index = Research

local defaults = {
  max_file_bytes = 64 * 1024,
  max_output_bytes = 32 * 1024,
  max_files = 200,
  max_scan = 2000,
  max_depth = 16,
  max_matches = 80,
}

local function error_result(message)
  return { ok = false, error = message }
end

local function cap(text, limit)
  if #text <= limit then return text, false end
  return text:sub(1, limit) .. "\n… [truncated]", true
end

local function line_text(lines, endofline)
  local text = table.concat(lines, "\n")
  return endofline and text .. "\n" or text
end

function Research.new(opts)
  opts = opts or {}
  local root = type(opts.root) == "string" and uv.fs_realpath(opts.root) or nil
  if not root or not uv.fs_stat(root) or uv.fs_stat(root).type ~= "directory" then
    return nil, "Research workspace must be an existing directory"
  end
  local limits = vim.tbl_extend("force", defaults, opts.limits or {})
  for name, value in pairs(limits) do
    if type(value) ~= "number" or value < 1 or value > 1000000 then
      return nil, "Invalid research limit: " .. name
    end
  end
  return setmetatable({ root = root, limits = limits }, Research)
end

function Research:_path(relative, allow_missing)
  if type(relative) ~= "string" or relative == "" or #relative > 1024
    or relative:sub(1, 1) == "/" or relative:find("\\", 1, true)
    or relative:find("[%c]") then
    return nil, "Path must be a short relative workspace path"
  end
  local parts = {}
  for part in relative:gmatch("[^/]+") do
    if part == ".." or part == "." or part:sub(1, 1) == "." or part == "" then
      return nil, "Hidden paths and path traversal are unavailable"
    end
    parts[#parts + 1] = part
  end
  if #parts == 0 then return nil, "Path must name a file or directory" end
  local normalized = table.concat(parts, "/")
  if normalized ~= relative then return nil, "Path must use normalized separators" end
  local current = self.root
  for index, part in ipairs(parts) do
    current = current .. "/" .. part
    local stat = uv.fs_lstat(current)
    if stat and stat.type == "link" then return nil, "Symlink paths are unavailable" end
    if not stat and (not allow_missing or index < #parts) then
      return nil, "Path does not exist in the workspace"
    end
    if stat and index < #parts and stat.type ~= "directory" then
      return nil, "Path parent is not a directory"
    end
  end
  return current, normalized
end

function Research:_buffers()
  local overlays = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = api.nvim_buf_get_name(buf)
      local canonical = uv.fs_realpath(name)
      if not canonical and name ~= "" then
        local parent = uv.fs_realpath(vim.fn.fnamemodify(name, ":h"))
        if parent then canonical = parent .. "/" .. vim.fn.fnamemodify(name, ":t") end
      end
      if canonical and canonical:sub(1, #self.root + 1) == self.root .. "/" then
        local relative = canonical:sub(#self.root + 2)
        local path = self:_path(relative, true)
        if path then overlays[relative] = buf end
      end
    end
  end
  return overlays
end

function Research:_read(relative, overlays)
  local path, normalized = self:_path(relative, true)
  if not path then return nil, normalized end
  local buf = overlays[normalized]
  if buf then
    local tick = api.nvim_buf_get_changedtick(buf)
    local text = line_text(api.nvim_buf_get_lines(buf, 0, -1, false), vim.bo[buf].endofline)
    if api.nvim_buf_get_changedtick(buf) ~= tick then return nil, "Buffer changed during inspection" end
    if #text > self.limits.max_file_bytes then return nil, "File exceeds research size limit" end
    if text:find("%z") then return nil, "Binary files are unavailable" end
    return { path = normalized, content = text, source = "buffer", changedtick = tick }
  end
  local stat = uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then return nil, "Path is not a regular file" end
  if stat.size > self.limits.max_file_bytes then return nil, "File exceeds research size limit" end
  local file = io.open(path, "rb")
  if not file then return nil, "Cannot read file" end
  local text = file:read(self.limits.max_file_bytes + 1)
  file:close()
  if not text or #text > self.limits.max_file_bytes then return nil, "File exceeds research size limit" end
  if text:find("%z") then return nil, "Binary files are unavailable" end
  return { path = normalized, content = text, source = "disk" }
end

function Research:_files(prefix, overlays)
  local files, seen, scanned, truncated = {}, {}, 0, false
  local function visit(dir, relative, depth)
    if depth > self.limits.max_depth or truncated then truncated = true; return end
    local scan = uv.fs_scandir(dir)
    if not scan then return end
    while true do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then break end
      scanned = scanned + 1
      if scanned > self.limits.max_scan then truncated = true; break end
      if name:sub(1, 1) ~= "." and not name:find("[%c]") and kind ~= "link" then
        local child = relative == "" and name or relative .. "/" .. name
        if kind == "directory" then
          visit(dir .. "/" .. name, child, depth + 1)
        elseif kind == "file" and not seen[child] then
          if #files >= self.limits.max_files then truncated = true; break end
          files[#files + 1], seen[child] = child, true
          if #files >= self.limits.max_files then truncated = true; break end
        end
      end
      if truncated then break end
    end
  end
  local base, relative = self.root, ""
  if prefix and prefix ~= "" then
    base, relative = self:_path(prefix, true)
    if not base then return nil, relative end
    local stat = uv.fs_lstat(base)
    if stat and stat.type == "file" then return { relative }, false end
    if stat and stat.type ~= "directory" then return nil, "Prefix is not a directory" end
  end
  local live = {}
  for name in pairs(overlays) do
    if relative == "" or name:sub(1, #relative + 1) == relative .. "/"
      or name == relative then live[#live + 1] = name end
  end
  table.sort(live)
  for _, name in ipairs(live) do
    if #files >= self.limits.max_files then truncated = true; break end
    files[#files + 1], seen[name] = name, true
  end
  if uv.fs_stat(base) then visit(base, relative, 0) end
  table.sort(files)
  if #files > self.limits.max_files then
    while #files > self.limits.max_files do files[#files] = nil end
    truncated = true
  end
  return files, truncated
end

function Research:tools()
  return {
    { name = "list_files", description = "List visible workspace files", parameters = {
      type = "object", properties = { prefix = { type = "string" } }, additionalProperties = false } },
    { name = "read_file", description = "Read a workspace file, using an open Neovim buffer when present",
      parameters = { type = "object", properties = { path = { type = "string" } },
        required = { "path" }, additionalProperties = false } },
    { name = "search_text", description = "Search literal text in workspace files and open buffers",
      parameters = { type = "object", properties = { query = { type = "string" },
        prefix = { type = "string" } }, required = { "query" }, additionalProperties = false } },
    { name = "git_status", description = "Inspect read-only git status",
      parameters = { type = "object", properties = {}, additionalProperties = false } },
    { name = "git_diff", description = "Inspect an unstaged git diff without external diff tools",
      parameters = { type = "object", properties = { path = { type = "string" } },
        required = { "path" }, additionalProperties = false } },
  }
end

function Research:_git(command, path)
  if path then
    local checked, err = self:_path(path, true)
    if not checked then return error_result(err) end
  end
  local args = { "git", "-c", "core.fsmonitor=false", "-c", "core.pager=cat",
    "-c", "color.ui=false" }
  vim.list_extend(args, command)
  if path then vim.list_extend(args, { "--", path }) end
  if vim.fn.executable("git") ~= 1 then return error_result("Git is unavailable") end
  local chunks, size, truncated, stream_error = {}, 0, false, false
  local ok, proc = pcall(vim.system, args, { cwd = self.root, text = true,
    env = { GIT_OPTIONAL_LOCKS = "0", GIT_PAGER = "cat" },
    stdout = function(read_err, chunk)
      if read_err then stream_error = true; return end
      if not chunk or size >= self.limits.max_output_bytes then
        if chunk then truncated = true end
        return
      end
      local available = self.limits.max_output_bytes - size
      chunks[#chunks + 1] = chunk:sub(1, available)
      size = size + math.min(#chunk, available)
      if #chunk > available then truncated = true end
    end,
  })
  if not ok then return error_result("Could not start git inspection") end
  local result = proc:wait(3000)
  if stream_error then return error_result("Could not read git output") end
  if result.code ~= 0 then
    return error_result(result.code == 124 and "Git inspection timed out" or "Git inspection failed")
  end
  local content = table.concat(chunks)
  if truncated then content = content .. "\n… [truncated]" end
  return { ok = true, content = content, truncated = truncated }
end

function Research:call(name, args)
  if type(args) ~= "table" then
    return error_result("Tool arguments must be an object")
  end
  local schemas = {}
  for _, tool in ipairs(self:tools()) do schemas[tool.name] = tool end
  local schema = schemas[name]
  if not schema then return error_result("Tool is unavailable") end
  for key in pairs(args) do
    if not schema.parameters.properties[key] then return error_result("Unknown tool argument") end
  end
  local overlays = self:_buffers()
  if name == "read_file" then
    local item, err = self:_read(args.path, overlays)
    if not item then return error_result(err) end
    if #item.content > self.limits.max_output_bytes then
      return error_result("File exceeds research output limit")
    end
    return { ok = true, content = item.content, path = item.path,
      source = item.source, changedtick = item.changedtick }
  end
  if name == "list_files" then
    local files, truncated = self:_files(args.prefix, overlays)
    if not files then return error_result(truncated) end
    local content, clipped = cap(table.concat(files, "\n"), self.limits.max_output_bytes)
    return { ok = true, content = content, truncated = truncated or clipped }
  end
  if name == "search_text" then
    if type(args.query) ~= "string" or args.query == "" or #args.query > 200 then
      return error_result("Search query must be 1–200 bytes")
    end
    local files, truncated = self:_files(args.prefix, overlays)
    if not files then return error_result(truncated) end
    local matches = {}
    for _, path in ipairs(files) do
      local item = self:_read(path, overlays)
      if item then
        local row = 0
        for line in (item.content .. "\n"):gmatch("(.-)\n") do
          row = row + 1
          if line:find(args.query, 1, true) then
            matches[#matches + 1] = path .. ":" .. row .. ":" .. line:sub(1, 240)
            if #matches >= self.limits.max_matches then truncated = true; break end
          end
        end
      end
      if #matches >= self.limits.max_matches then break end
    end
    local content, clipped = cap(table.concat(matches, "\n"), self.limits.max_output_bytes)
    return { ok = true, content = content, truncated = truncated or clipped }
  end
  if name == "git_status" then
    return self:_git({ "status", "--short", "--untracked-files=no" })
  end
  if type(args.path) ~= "string" then return error_result("Git diff needs a file path") end
  return self:_git({ "diff", "--no-ext-diff", "--no-textconv", "--no-color" }, args.path)
end

return Research
