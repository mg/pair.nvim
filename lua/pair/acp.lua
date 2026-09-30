local uv = vim.uv or vim.loop

local Client = {}
Client.__index = Client

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function error_text(err)
  if type(err) == "table" then return err.message or vim.inspect(err) end
  return tostring(err)
end

function Client.new(opts)
  return setmetatable({
    command = opts.command,
    args = opts.args or {},
    env = opts.env,
    session_meta = opts.session_meta,
    allowed_tool_names = opts.allowed_tool_names,
    allowed_tool_kinds = opts.allowed_tool_kinds,
    required_mode = opts.required_mode,
    model = opts.model,
    cwd = opts.cwd,
    session_file = opts.session_file,
    on_update = opts.on_update,
    on_error = opts.on_error,
    ready = false,
    requests = {},
    request_id = 0,
    output_buffer = "",
    error_buffer = "",
  }, Client)
end

function Client:_write(message)
  if not self.stdin or self.stdin:is_closing() then return false end
  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then return false end
  self.stdin:write(encoded .. "\n")
  return true
end

function Client:_request(method, params, callback)
  self.request_id = self.request_id + 1
  local id = self.request_id
  self.requests[id] = callback
  if not self:_write({ jsonrpc = "2.0", id = id, method = method, params = params }) then
    self.requests[id] = nil
    callback(nil, { message = "Could not send " .. method .. " to ACP agent" })
  end
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
  self.process = nil
  self.stdin = nil
  self.stdout = nil
  self.stderr = nil
end

function Client:_fail(message)
  if self.stopping then return end
  local starting = self.start_callback
  local turn = self.turn
  self.start_callback = nil
  self.turn = nil
  self.requests = {}
  self:_shutdown()
  local err = { message = message }
  if starting then starting(nil, err) end
  if turn then turn(nil, err) end
  if not starting and not turn and self.on_error then self.on_error(message) end
end

function Client:_save_session(id)
  local file = io.open(self.session_file, "w")
  if not file then return false end
  file:write(id, "\n")
  file:close()
  pcall(vim.fn.setfperm, self.session_file, "rw-------")
  self.session_id = id
  self.session_saved = true
  return true
end

function Client:_ready(id, model, restored)
  if type(id) ~= "string" or id == "" then
    self:_fail("ACP agent returned no session ID")
    return
  end
  self.session_id = id
  self.session_saved = restored == true
  self.ready = true
  self.model = model
  local callback = self.start_callback
  self.start_callback = nil
  callback({ sessionId = id, model = model })
end

function Client:_open_session(capabilities)
  local saved
  local file = io.open(self.session_file, "r")
  if file then saved = file:read("*l"); file:close() end
  if saved and saved ~= "" and not capabilities.loadSession then
    self:_fail("ACP agent cannot restore its saved session; use :PairNew to start over")
    return
  end
  local method = saved and saved ~= "" and "session/load" or "session/new"
  local params = { cwd = self.cwd, mcpServers = {} }
  if method == "session/load" then params.sessionId = saved end
  if self.session_meta then params._meta = vim.deepcopy(self.session_meta) end
  self:_request(method, params, function(result, err)
    if err then self:_fail("Could not " .. method .. ": " .. error_text(err)); return end
    local id = method == "session/load" and saved or result and result.sessionId
    if type(id) ~= "string" or id == "" then
      self:_fail("ACP agent returned no session ID")
      return
    end
    self.session_id = id
    local current_model
    self.models = {}
    for _, option in ipairs((result or {}).configOptions or {}) do
      if option.id == "model" then
        if type(option.currentValue) == "string" then current_model = option.currentValue end
        for _, choice in ipairs(option.options or {}) do
          if type(choice.value) == "string" then
            self.models[#self.models + 1] = { value = choice.value,
              label = choice.name or choice.value, description = choice.description }
          end
        end
      end
    end
    local function select_model()
      if not self.model then self:_ready(id, current_model, method == "session/load"); return end
      local found = false
      for _, option in ipairs((result or {}).configOptions or {}) do
        if option.id == "model" then
          for _, choice in ipairs(option.options or {}) do
            if choice.value == self.model then found = true end
          end
        end
      end
      if not found then
        self:_fail("ACP model is not available: " .. self.model)
        return
      end
      self:_request("session/set_config_option", {
        sessionId = id, configId = "model", value = self.model,
      }, function(_, model_err)
        if model_err then self:_fail("Could not select ACP model: " .. error_text(model_err)); return end
        self:_ready(id, self.model, method == "session/load")
      end)
    end
    if not self.required_mode then select_model(); return end
    local modes = (result or {}).modes
    if modes then
      local available = false
      for _, mode in ipairs(modes.availableModes or {}) do
        if mode.id == self.required_mode then available = true end
      end
      if not available then
        self:_fail("ACP agent does not offer required " .. self.required_mode .. " mode")
      elseif modes.currentModeId == self.required_mode then
        select_model()
      else
        self:_request("session/set_mode", { sessionId = id, modeId = self.required_mode }, function(_, mode_err)
          if mode_err then self:_fail("Could not select ACP mode: " .. error_text(mode_err)); return end
          select_model()
        end)
      end
      return
    end
    local found = false
    for _, option in ipairs((result or {}).configOptions or {}) do
      if option.id == "mode" and option.currentValue == self.required_mode then found = true end
    end
    if not found then
      self:_fail("ACP agent did not start in required " .. self.required_mode .. " mode")
      return
    end
    select_model()
  end)
end

function Client:list_models(callback)
  if not self.ready then callback(nil, { message = "ACP agent is not ready" }); return end
  callback(vim.deepcopy(self.models or {}))
end

function Client:set_model(value, callback)
  if not self.ready then callback(nil, { message = "ACP agent is not ready" }); return end
  local found = false
  for _, choice in ipairs(self.models or {}) do
    if choice.value == value then found = true; break end
  end
  if not found then callback(nil, { message = "ACP model is not available: " .. value }); return end
  self:_request("session/set_config_option", {
    sessionId = self.session_id, configId = "model", value = value,
  }, function(_, err)
    if err then callback(nil, { message = "Could not select ACP model: " .. error_text(err) }); return end
    self.model = value
    callback(value)
  end)
end

function Client:_handle(event)
  if self.stopping then return end
  if event.id ~= nil and not event.method then
    local callback = self.requests[event.id]
    self.requests[event.id] = nil
    if callback then callback(event.result, event.error) end
    return
  end
  if event.id ~= nil and event.method then
    if event.method == "session/request_permission" then
      local outcome = { outcome = "cancelled" }
      for _, option in ipairs((event.params or {}).options or {}) do
        if option.kind == "reject_once" and type(option.optionId) == "string" then
          outcome = { outcome = "selected", optionId = option.optionId }
          break
        end
      end
      self:_write({ jsonrpc = "2.0", id = event.id, result = { outcome = outcome } })
    else
      self:_write({ jsonrpc = "2.0", id = event.id, error = {
        code = -32601, message = "Pair does not provide agent tools or file writes",
      } })
    end
    return
  end
  if event.method ~= "session/update" then return end
  local params = event.params or {}
  if params.sessionId ~= self.session_id then return end
  local update = type(params.update) == "table" and params.update or {}
  if self.allowed_tool_names and update.sessionUpdate == "tool_call" then
    local allowed = false
    if type(update.name) == "string" then
      for _, name in ipairs(self.allowed_tool_names) do
        if update.name == name then allowed = true; break end
      end
    elseif update.name == nil or update.name == vim.NIL then
      for _, kind in ipairs(self.allowed_tool_kinds or {}) do
        if update.kind == kind then allowed = true; break end
      end
    end
    if not allowed then
      self:_fail("ACP agent reported a tool outside Pair's inspection set: "
        .. tostring(update.name or update.kind))
      return
    end
  end
  if self.required_mode and update.sessionUpdate == "current_mode_update"
      and update.currentModeId ~= self.required_mode then
    self:_fail("ACP agent left required " .. self.required_mode .. " mode")
    return
  end
  if self.required_mode and update.sessionUpdate == "config_option_update" then
    for _, option in ipairs(update.configOptions or {}) do
      if option.id == "mode" and option.currentValue ~= self.required_mode then
        self:_fail("ACP agent left required " .. self.required_mode .. " mode")
        return
      end
    end
  end
  if self.turn and update.sessionUpdate == "tool_call_update" then
    update.sessionUpdate = "tool_call"
    self.on_update(update)
  elseif self.turn and (update.sessionUpdate == "agent_message_chunk" or update.sessionUpdate == "tool_call") then
    self.on_update(update)
  end
end

function Client:start(callback)
  if vim.fn.executable(self.command) ~= 1 then
    callback(nil, { message = "ACP agent executable not found: " .. self.command })
    return
  end
  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)
  local env
  if self.env then
    local values = vim.fn.environ()
    for key, value in pairs(self.env) do values[key] = value end
    env = {}
    for key, value in pairs(values) do env[#env + 1] = key .. "=" .. value end
  end
  self.process, self.pid = uv.spawn(self.command, {
    args = self.args,
    cwd = self.cwd,
    env = env,
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    vim.schedule(function()
      if not self.stopping then
        self:_fail("ACP agent exited (code " .. code .. ", signal " .. signal .. "): " .. self.error_buffer:sub(-500))
      end
    end)
  end)
  if not self.process then
    close(self.stdin)
    close(self.stdout)
    close(self.stderr)
    self.stdin, self.stdout, self.stderr = nil, nil, nil
    callback(nil, { message = "Could not launch ACP agent: " .. tostring(self.pid) })
    return
  end
  self.start_callback = callback
  self.stdout:read_start(function(read_err, chunk)
    if read_err then
      vim.schedule(function() self:_fail(error_text(read_err)) end)
    elseif chunk then
      self.output_buffer = self.output_buffer .. chunk
      while true do
        local newline = self.output_buffer:find("\n", 1, true)
        if not newline then break end
        local line = self.output_buffer:sub(1, newline - 1)
        self.output_buffer = self.output_buffer:sub(newline + 1)
        local ok, event = pcall(vim.json.decode, line)
        if ok and type(event) == "table" then
          vim.schedule(function() self:_handle(event) end)
        end
      end
    else
      vim.schedule(function() self:_fail("ACP agent closed its output: " .. self.error_buffer:sub(-500)) end)
    end
  end)
  self.stderr:read_start(function(_, chunk)
    if chunk then self.error_buffer = (self.error_buffer .. chunk):sub(-4000) end
  end)
  self:_request("initialize", {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
    clientInfo = { name = "pair.nvim", version = "0.1.0" },
  }, function(result, err)
    if err then self:_fail("ACP initialization failed: " .. error_text(err)); return end
    if not result or result.protocolVersion ~= 1 then
      self:_fail("ACP agent does not support protocol version 1")
      return
    end
    self:_open_session(result.agentCapabilities or {})
  end)
  vim.defer_fn(function()
    if self.start_callback then self:_fail("Timed out starting ACP agent") end
  end, 30000)
end

function Client:prompt(prompt, callback)
  if not self.ready then callback(nil, { message = "ACP agent is not ready" }); return end
  if self.turn then callback(nil, { message = "An ACP turn is already running" }); return end
  self.turn = callback
  self:_request("session/prompt", {
    sessionId = self.session_id,
    prompt = { { type = "text", text = prompt } },
  }, function(result, err)
    if not self.turn then return end
    self.turn = nil
    if err then callback(nil, err); return end
    if not self.session_saved and not self:_save_session(self.session_id) then
      callback(nil, { message = "ACP agent answered but Pair could not save its session" })
      return
    end
    callback(result or { stopReason = "end_turn" })
  end)
end

function Client:cancel()
  if self.turn and self.session_id then
    self:_write({ jsonrpc = "2.0", method = "session/cancel", params = { sessionId = self.session_id } })
  end
end

function Client:stop()
  self:_shutdown()
end

function Client:reset()
  self:_shutdown()
  self.session_id = nil
  os.remove(self.session_file)
end

return Client
