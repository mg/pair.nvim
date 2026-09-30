local uv = vim.uv or vim.loop

local Client = {}
Client.__index = Client

local allowed_tools = {
  view_file = true, grep_search = true, list_dir = true, find_by_name = true,
}

local denied_permissions = {
  "write_file(*)", "command(*)", "mcp(*)", "read_url(*)",
  "execute_url(*)", "unsandboxed(*)",
}

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function prepare_home(cwd)
  local root = vim.fn.stdpath("state") .. "/pair/antigravity/" .. vim.fn.sha256(cwd)
  local cli = root .. "/antigravity-cli"
  local agents = root .. "/config/agents"
  vim.fn.mkdir(cli, "p")
  vim.fn.mkdir(agents, "p")
  for _, dir in ipairs({ root, cli, root .. "/config", agents }) do
    pcall(uv.fs_chmod, dir, 448) -- 0700
  end
  local source = vim.api.nvim_get_runtime_file("config/pair-antigravity-agent.md", false)[1]
  if not source or vim.fn.filereadable(source) ~= 1 then
    return nil, "Pair's Antigravity inspection agent is missing"
  end
  local agent = agents .. "/pair-nvim-readonly.md"
  if vim.fn.writefile(vim.fn.readfile(source), agent) ~= 0 then
    return nil, "Could not install Pair's Antigravity inspection agent"
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
    permissions = { allow = {}, ask = {}, deny = denied_permissions },
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
  return root
end

function Client.new(opts)
  return setmetatable({
    command = opts.command or "agy", model = opts.model, cwd = opts.cwd,
    session_file = opts.session_file, on_update = opts.on_update,
    on_error = opts.on_error, ready = false, output_buffer = "", error_buffer = "",
  }, Client)
end

function Client:_shutdown()
  self.stopping = true
  self.ready = false
  if self.process and not self.process:is_closing() then
    pcall(function() self.process:kill("sigterm") end)
  end
  close(self.stdin)
  close(self.stdout)
  close(self.stderr)
  close(self.process)
  self.stdin, self.stdout, self.stderr, self.process = nil, nil, nil, nil
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
        self:_fail("Antigravity reported a tool outside Pair's inspection set: " .. tostring(name))
        return
      end
      local detail = step.tool_info or {}
      self.on_update({ sessionUpdate = "tool_call", toolCallId = tostring(step.step_index),
        name = name, title = name, kind = "read",
        status = step.state == "DONE" and "completed"
          or step.state == "FAILED" and "failed" or "in_progress",
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
  local home, err = prepare_home(self.cwd)
  if not home then callback(nil, { message = err }); return end
  local args = { "--agent", "pair-nvim-readonly", "--disable-slash-commands",
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
  self.stdin, self.stdout, self.stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local values = vim.fn.environ()
  values.GEMINI_HOME = home
  values.AGY_CLI_DISABLE_AUTO_UPDATE = "true"
  local env = {}
  for key, value in pairs(values) do env[#env + 1] = key .. "=" .. value end
  self.start_callback = callback
  self.process, self.pid = uv.spawn(self.command, {
    args = args, cwd = self.cwd, env = env,
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    vim.schedule(function()
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
    if read_err then vim.schedule(function() self:_fail(tostring(read_err)) end)
    elseif chunk then
      self.output_buffer = self.output_buffer .. chunk
      while true do
        local newline = self.output_buffer:find("\n", 1, true)
        if not newline then break end
        local line = self.output_buffer:sub(1, newline - 1)
        self.output_buffer = self.output_buffer:sub(newline + 1)
        local ok, event = pcall(vim.json.decode, line)
        if not ok then
          vim.schedule(function() self:_fail("Antigravity sent invalid stream JSON") end)
        else
          vim.schedule(function() self:_handle(event) end)
        end
      end
    else
      vim.schedule(function() self:_fail("Antigravity closed its output: " .. self.error_buffer:sub(-500)) end)
    end
  end)
  self.stderr:read_start(function(_, chunk)
    if chunk then self.error_buffer = (self.error_buffer .. chunk):sub(-4000) end
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
  callback(self.model and { { value = self.model, label = self.model } } or {})
end

function Client:set_model(_, callback)
  callback(nil, { message = "Set Antigravity's model in setup().models before starting a conversation" })
end

return Client
