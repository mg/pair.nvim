local uv = vim.uv or vim.loop
local sandbox = require("pair.command_sandbox")

local Client = {}
Client.__index = Client

local allowed_tools = {
  view_file = true, grep_search = true, list_dir = true, find_by_name = true,
  run_command = true, command_status = true, send_command_input = true,
}

local denied_permissions = {
  "write_file(*)", "mcp(*)", "read_url(*)",
  "execute_url(*)",
}

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function prepare_home(cwd)
  local root = vim.fn.stdpath("state") .. "/pair/antigravity/" .. vim.fn.sha256(cwd)
  local gemini = root .. "/.gemini"
  local cli = gemini .. "/antigravity-cli"
  local agents = gemini .. "/config/agents"
  vim.fn.mkdir(cli, "p")
  vim.fn.mkdir(agents, "p")
  for _, dir in ipairs({ root, gemini, cli, gemini .. "/config", agents }) do
    pcall(uv.fs_chmod, dir, 448) -- 0700
  end
  local source = vim.api.nvim_get_runtime_file("config/pair-antigravity-agent.md", false)[1]
  if not source or vim.fn.filereadable(source) ~= 1 then
    return nil, "Pair's Antigravity research agent is missing"
  end
  local agent = agents .. "/pair-nvim-research.md"
  if vim.fn.writefile(vim.fn.readfile(source), agent) ~= 0 then
    return nil, "Could not install Pair's Antigravity research agent"
  end
  pcall(uv.fs_chmod, agent, 384) -- 0600
  local source_home = vim.env.GEMINI_HOME or vim.fn.expand("~/.gemini")
  local token = source_home .. "/antigravity-cli/antigravity-oauth-token"
  local link = cli .. "/antigravity-oauth-token"
  local has_token = vim.fn.filereadable(token) == 1
  if vim.fn.getftype(link) ~= "" then vim.fn.delete(link) end
  if has_token then
    local ok, err = uv.fs_symlink(token, link)
    if not ok then return nil, "Could not link Antigravity CLI login: " .. tostring(err) end
  elseif not vim.env.GEMINI_API_KEY and not vim.env.GOOGLE_API_KEY then
    return nil, "Antigravity CLI login is missing. Sign in with agy, then retry"
  end
  local settings = {
    -- The CLI's permission engine decides which tools run. The outer process
    -- sandbox, inherited by shell children, decides which paths can be written.
    -- "unsandboxed" means outside Antigravity's own terminal sandbox, not
    -- outside Pair's inherited filesystem sandbox. Both grants are necessary
    -- for headless commands; never launch this profile without sandbox.wrap.
    permissions = { allow = { "command(*)", "unsandboxed(*)" }, ask = {}, deny = denied_permissions },
    allowNonWorkspaceAccess = false,
    trustedWorkspaces = { cwd },
    agentMode = "default",
    toolPermission = "request-review",
  }
  local settings_path = cli .. "/settings.json"
  if vim.fn.writefile({ vim.json.encode(settings) }, settings_path) ~= 0 then
    return nil, "Could not write Pair's Antigravity restrictions"
  end
  pcall(uv.fs_chmod, settings_path, 384) -- 0600
  local shared = gemini .. "/config/config.json"
  if vim.fn.writefile({ vim.json.encode({ userSettings = {
    globalPermissionGrants = settings.permissions, permissionGrantsV2Migrated = true,
  } }) }, shared) ~= 0 then
    return nil, "Could not write Pair's Antigravity shared permissions"
  end
  pcall(uv.fs_chmod, shared, 384)
  return root, nil, has_token and (source_home .. "/antigravity-cli") or nil
end

function Client.new(opts)
  return setmetatable({
    command = opts.command or "agy", model = opts.model, cwd = opts.cwd,
    session_file = opts.session_file, on_update = opts.on_update,
    on_error = opts.on_error, ready = false, output_buffer = "", error_buffer = "",
    writable_paths = opts.writable_paths or {},
  }, Client)
end

function Client:_shutdown()
  self.launch_generation = (self.launch_generation or 0) + 1
  self.stopping = true
  self.ready = false
  local switching = self.switching
  self.switching = nil
  if self.process and not self.process:is_closing() then
    pcall(function() self.process:kill("sigterm") end)
  end
  close(self.stdin)
  close(self.stdout)
  close(self.stderr)
  close(self.process)
  self.stdin, self.stdout, self.stderr, self.process = nil, nil, nil, nil
  if switching then switching.callback(nil, { message = "Antigravity model switch was stopped" }) end
end

function Client:_fail(message)
  if self.stopping then return end
  local starting, turn = self.start_callback, self.turn
  self.start_callback, self.turn = nil, nil
  self:_shutdown()
  local err = { message = message }
  if starting then starting(nil, err) end
  if turn then turn(nil, err) end
  if not starting and not turn and self.on_error then self.on_error(message) end
end

function Client:_save_session()
  local file = io.open(self.session_file, "w")
  if not file then return false end
  file:write(self.session_id, "\n")
  file:close()
  pcall(vim.fn.setfperm, self.session_file, "rw-------")
  self.session_saved = true
  return true
end

function Client:_handle(event)
  if self.stopping or type(event) ~= "table" then return end
  if event.event == "init" then
    local id = event.conversation_id
    if type(id) ~= "string" or not id:match("^[%da-fA-F%-]+$") then
      self:_fail("Antigravity returned an invalid conversation ID")
      return
    end
    if self.resuming and id ~= self.resuming then
      self:_fail("Antigravity resumed a different conversation")
      return
    end
    self.session_id = id
    return
  end
  if event.event == "step_update" then
    local step = event.step_update or {}
    if step.step_type == "agent_response" and self.turn and type(step.text_delta) == "string" then
      self.turn_text = self.turn_text .. step.text_delta
      self.on_update({ sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = step.text_delta } })
    elseif step.step_type == "tool" then
      local name = step.tool_name
      if not allowed_tools[name] then
        self:_fail("Antigravity reported a tool outside Pair's research set: " .. tostring(name))
        return
      end
      local detail = step.tool_info or {}
      local command = type(detail.parameters) == "table" and detail.parameters.CommandLine or nil
      local command_tool = name == "run_command" or name == "command_status" or name == "send_command_input"
      self.on_update({ sessionUpdate = "tool_call", toolCallId = tostring(step.step_index),
        name = name, title = command or name, command = command,
        kind = command_tool and "execute" or "read",
        status = step.state == "DONE" and "completed"
          or (step.state == "FAILED" or step.state == "ERROR") and "failed" or "in_progress",
        error = detail.error,
        output = type(detail.output) == "string" and detail.output or nil })
    end
    return
  end
  if event.event == "result" and self.turn then
    local result = event.result or {}
    local callback = self.turn
    self.turn = nil
    if result.status ~= "SUCCESS" then
      callback(nil, { message = result.error or "Antigravity turn ended: " .. tostring(result.status) })
      return
    end
    if self.turn_text == "" and type(result.response) == "string" and result.response ~= "" then
      self.on_update({ sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = result.response } })
    end
    if not self.session_id then
      callback(nil, { message = "Antigravity answered without a conversation ID" })
      return
    end
    if not self.session_saved and not self:_save_session() then
      callback(nil, { message = "Antigravity answered but Pair could not save its conversation" })
      return
    end
    callback({ stopReason = "end_turn" })
  end
end

function Client:start(callback)
  if vim.fn.executable(self.command) ~= 1 then
    callback(nil, { message = "Antigravity CLI executable not found: " .. self.command })
    return
  end
  local home, err, login_state = prepare_home(self.cwd)
  if not home then callback(nil, { message = err }); return end
  local args = { "--agent", "pair-nvim-research", "--disable-slash-commands",
    "--input-format", "stream-json", "--output-format", "stream-json" }
  if self.model then vim.list_extend(args, { "--model", self.model }) end
  local file = io.open(self.session_file, "r")
  if file then
    local saved = file:read("*l")
    file:close()
    if type(saved) ~= "string" or not saved:match("^[%da-fA-F%-]+$") then
      callback(nil, { message = "Saved Antigravity conversation ID is invalid" })
      return
    end
    self.resuming = saved
    self.session_id = saved
    vim.list_extend(args, { "--conversation", saved })
  end
  local scratch = home .. "/scratch"
  vim.fn.mkdir(scratch, "p")
  pcall(uv.fs_chmod, scratch, 448)
  local state_paths = { home }
  if login_state then state_paths[#state_paths + 1] = login_state end
  local launch, launch_err = sandbox.wrap(self.command, args, {
    cwd = self.cwd, writable_paths = self.writable_paths, state_paths = state_paths,
  })
  if not launch then callback(nil, { message = launch_err }); return end
  self.stopping = false
  self.output_buffer, self.error_buffer = "", ""
  self.launch_generation = (self.launch_generation or 0) + 1
  local generation = self.launch_generation
  self.stdin, self.stdout, self.stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local values = vim.fn.environ()
  -- agy 1.2.14 ignores GEMINI_HOME and resolves settings, agents, and login
  -- relative to HOME. Isolate its actual home, not just a Gemini env variable.
  values.HOME = home
  values.GEMINI_HOME = home .. "/.gemini"
  values.PWD = uv.fs_realpath(self.cwd) or self.cwd
  values.AGY_CLI_DISABLE_AUTO_UPDATE = "true"
  values.TMPDIR, values.TMP, values.TEMP = scratch, scratch, scratch
  values.PYTHONDONTWRITEBYTECODE = "1"
  local env = {}
  for key, value in pairs(values) do env[#env + 1] = key .. "=" .. value end
  self.launch_env, self.state_paths = values, state_paths
  local function schedule(action)
    vim.schedule(function()
      if self.launch_generation == generation then action() end
    end)
  end
  self.start_callback = callback
  self.process, self.pid = uv.spawn(launch.command, {
    args = launch.args, cwd = self.cwd, env = env,
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    schedule(function()
      if self.switching then
        local switching = self.switching
        self.switching = nil
        self:_shutdown()
        self.model = switching.value
        self:start(function(session, start_err)
          switching.callback(session and self.model or nil, start_err)
        end)
        return
      end
      if not self.stopping then
        self:_fail("Antigravity CLI exited (code " .. code .. ", signal " .. signal .. "): "
          .. self.error_buffer:sub(-500))
      end
    end)
  end)
  if not self.process then
    self:_fail("Could not launch Antigravity CLI: " .. tostring(self.pid))
    return
  end
  self.stdout:read_start(function(read_err, chunk)
    if self.launch_generation ~= generation then return end
    if read_err then schedule(function() self:_fail(tostring(read_err)) end)
    elseif chunk then
      self.output_buffer = self.output_buffer .. chunk
      while true do
        local newline = self.output_buffer:find("\n", 1, true)
        if not newline then break end
        local line = self.output_buffer:sub(1, newline - 1)
        self.output_buffer = self.output_buffer:sub(newline + 1)
        local ok, event = pcall(vim.json.decode, line)
        if not ok then
          schedule(function() self:_fail("Antigravity sent invalid stream JSON") end)
        else
          schedule(function() self:_handle(event) end)
        end
      end
    else
      schedule(function() self:_fail("Antigravity closed its output: " .. self.error_buffer:sub(-500)) end)
    end
  end)
  self.stderr:read_start(function(_, chunk)
    if chunk and self.launch_generation == generation then
      self.error_buffer = (self.error_buffer .. chunk):sub(-4000)
    end
  end)
  -- Headless Antigravity emits `init` only after its first stdin prompt.
  self.ready = true
  self.start_callback = nil
  callback({ sessionId = self.session_id or "pending", model = self.model })
end

function Client:prompt(prompt, callback)
  if not self.ready then callback(nil, { message = "Antigravity is not ready" }); return end
  if self.turn then callback(nil, { message = "An Antigravity turn is already running" }); return end
  self.turn = callback
  self.turn_text = ""
  local ok, encoded = pcall(vim.json.encode,
    { event = "user", message = { content = prompt } })
  if not ok or not self.stdin or self.stdin:is_closing() then
    self.turn = nil
    callback(nil, { message = "Could not send prompt to Antigravity" })
    return
  end
  self.stdin:write(encoded .. "\n")
end

function Client:cancel()
  if self.turn and self.process and not self.process:is_closing() then
    pcall(function() self.process:kill("sigint") end)
  end
end

function Client:stop() self:_shutdown() end

function Client:reset()
  self:_shutdown()
  os.remove(self.session_file)
end

function Client:list_models(callback)
  if not self.ready then callback(nil, { message = "Antigravity is not ready" }); return end
  local launch, err = sandbox.wrap(self.command, { "models" }, {
    cwd = self.cwd, writable_paths = self.writable_paths, state_paths = self.state_paths,
  })
  if not launch then callback(nil, { message = err }); return end
  local generation = self.launch_generation
  local command = { launch.command }
  vim.list_extend(command, launch.args)
  vim.system(command, { cwd = self.cwd, env = self.launch_env, text = true, timeout = 15000 }, function(result)
    vim.schedule(function()
      if self.launch_generation ~= generation or not self.ready then
        callback(nil, { message = "Antigravity changed while listing models; try again" })
        return
      end
      if result.code ~= 0 then
        callback(nil, { message = "Could not list Antigravity models: "
          .. vim.trim((result.stderr or ""):sub(-500)) })
        return
      end
      local choices = {}
      for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local value, label = line:match("^([%w._%-]+)%s+(.+)$")
        if value then choices[#choices + 1] = { value = value, label = vim.trim(label) } end
      end
      self.models = choices
      callback(choices)
    end)
  end)
end

function Client:set_model(value, callback)
  if not self.ready or self.turn or self.switching then
    callback(nil, { message = "Finish the Antigravity request before changing models" })
    return
  end
  local found = false
  for _, choice in ipairs(self.models or {}) do
    if choice.value == value then found = true end
  end
  if not found then callback(nil, { message = "Antigravity model is not available: " .. tostring(value) }); return end
  if self.model == value then callback(value); return end
  -- The headless CLI selects its model at launch. Wait for its old process to
  -- exit, then resume the saved conversation with the new --model argument.
  self.switching = { value = value, callback = callback }
  self.stopping, self.ready = true, false
  local process = self.process
  local ok, err = process:kill("sigterm")
  if not ok then
    self.switching = nil
    self.stopping, self.ready = false, true
    callback(nil, { message = "Could not stop Antigravity to switch models: " .. tostring(err) })
    return
  end
  vim.defer_fn(function()
    if self.switching and self.process == process and not process:is_closing() then
      pcall(function() process:kill("sigkill") end)
    end
  end, 2500)
end

return Client
