local uv = vim.uv or vim.loop
local Client = {}
Client.__index = Client
local inspection = { read = true, grep = true, find = true, ls = true }

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function model_name(model)
  if type(model) == "table" and type(model.provider) == "string" and type(model.id) == "string" then
    return model.provider .. "/" .. model.id
  end
end

function Client.new(opts)
  return setmetatable({ command = opts.command, cwd = opts.cwd, model = opts.model,
    session_file = opts.session_file, on_update = opts.on_update, on_error = opts.on_error,
    requests = {}, request_id = 0, output_buffer = "", error_buffer = "", ready = false }, Client)
end

function Client:_write(message)
  if not self.stdin or self.stdin:is_closing() then return false end
  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then return false end
  self.stdin:write(encoded .. "\n")
  return true
end

function Client:_request(kind, params, callback)
  self.request_id = self.request_id + 1
  local id = tostring(self.request_id)
  local message = vim.tbl_extend("force", params or {}, { id = id, type = kind })
  self.requests[id] = callback
  if not self:_write(message) then
    self.requests[id] = nil
    callback(nil, { message = "Could not send " .. kind .. " to Pi" })
  end
end

function Client:stop()
  self.stopping, self.ready = true, false
  if self.process and not self.process:is_closing() then
    pcall(function() self.process:kill("sigterm") end)
  end
  close(self.stdin); close(self.stdout); close(self.stderr); close(self.process)
  self.stdin, self.stdout, self.stderr, self.process = nil, nil, nil, nil
end

function Client:_fail(message)
  if self.stopping then return end
  local starting, turn, requests = self.start_callback, self.turn, self.requests
  self.start_callback, self.turn, self.requests = nil, nil, {}
  self:stop()
  local err = { message = message }
  if starting then starting(nil, err) end
  if turn then turn(nil, err) end
  -- Do not strand model-picker callbacks on an unexpected process exit.
  if not starting and not turn then
    for _, callback in pairs(requests) do callback(nil, err) end
    if self.on_error then self.on_error(message) end
  end
end

function Client:list_models(callback)
  self:_request("get_available_models", {}, function(data, err)
    if err then callback(nil, err); return end
    local choices = {}
    for _, model in ipairs((data or {}).models or {}) do
      local value = model_name(model)
      if value then choices[#choices + 1] = { value = value, label = model.name or value,
        description = model.provider } end
    end
    callback(choices)
  end)
end

function Client:set_model(value, callback)
  local provider, id = value:match("^([^/]+)/(.+)$")
  if not provider then callback(nil, { message = "Pi models must use provider/model-id" }); return end
  self:_request("set_model", { provider = provider, modelId = id }, function(data, err)
    if err then callback(nil, err); return end
    self.model = model_name(data) or value
    callback(self.model)
  end)
end

function Client:_finish()
  if not self.turn or self.finishing then return end
  self.finishing = true
  local turn = self.turn
  self:_request("get_state", {}, function(state, err)
    if self.turn ~= turn then return end
    if err then self:_fail(err.message); return end
    local path = state and state.sessionFile
    if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
      self:_fail("Pi did not persist its session; use :PairNew to start over"); return
    end
    local file = io.open(self.session_file, "w")
    if not file then self:_fail("Pi answered but Pair could not save its session"); return end
    file:write(path, "\n"); file:close()
    pcall(vim.fn.setfperm, self.session_file, "rw-------")
    pcall(vim.fn.setfperm, path, "rw-------")
    self.session_id = path
    local callback = self.turn
    self.turn, self.finishing = nil, nil
    if self.turn_error and not self.cancelled then callback(nil, { message = self.turn_error })
    else callback({ stopReason = self.cancelled and "cancelled" or self.stop_reason or "end_turn" }) end
  end)
end

function Client:_handle(event)
  if self.stopping then return end
  if event.type == "response" then
    local callback = self.requests[event.id]
    self.requests[event.id] = nil
    if callback then
      callback(event.data, event.success ~= true and { message = tostring(event.error or "Pi command failed") } or nil)
    end
    return
  end
  if not self.turn then return end
  if event.type == "message_update" then
    local update = event.assistantMessageEvent or {}
    if update.type == "text_delta" and type(update.delta) == "string" then
      self.on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = update.delta } })
    end
  elseif event.type == "message_end" and type(event.message) == "table" and event.message.role == "assistant" then
    local message = event.message
    self.turn_error = message.stopReason == "error" and (message.errorMessage or "Pi provider failed") or nil
    self.stop_reason = message.stopReason == "aborted" and "cancelled"
      or message.stopReason == "length" and "max_tokens" or nil
  elseif event.type:match("^tool_execution_") then
    if not inspection[event.toolName] then
      self:_fail("Pi reported a tool outside Pair's inspection set: " .. tostring(event.toolName)); return
    end
    self.on_update({ sessionUpdate = "tool_call", toolCallId = event.toolCallId, title = event.toolName,
      status = event.type == "tool_execution_end" and (event.isError and "failed" or "completed") or "in_progress",
      output = (event.result or event.partialResult or {}).content })
  elseif event.type == "auto_retry_start" then
    self.turn_error = nil
    self.on_update({ sessionUpdate = "agent_message_reset" })
  elseif event.type == "auto_retry_end" and event.success == false then
    self.turn_error = event.finalError or "Pi retry failed"
  elseif event.type == "agent_settled" then
    self:_finish()
  end
end

function Client:start(callback)
  if vim.fn.executable(self.command) ~= 1 then
    callback(nil, { message = "Pi executable not found: " .. self.command }); return
  end
  local saved
  local file = io.open(self.session_file, "r")
  if file then saved = file:read("*l"); file:close() end
  if saved and (saved == "" or vim.fn.filereadable(saved) ~= 1) then
    callback(nil, { message = "Pi saved session not found; use :PairNew to start over" }); return
  end
  local dir = self.session_file .. ".pi"
  vim.fn.mkdir(dir, "p", 448)
  local args = { "--mode", "rpc", "--tools", "read,grep,find,ls", "--no-extensions",
    "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve", "--session-dir", dir }
  if saved then args[#args + 1] = "--session"; args[#args + 1] = saved end
  self.start_callback = callback
  self.stdin, self.stdout, self.stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  self.process, self.pid = uv.spawn(self.command, { args = args, cwd = self.cwd,
    stdio = { self.stdin, self.stdout, self.stderr } }, function(code, signal)
    vim.schedule(function()
      self:_fail("Pi exited (code " .. code .. ", signal " .. signal .. "): " .. self.error_buffer:sub(-500))
    end)
  end)
  if not self.process then self:_fail("Could not launch Pi: " .. tostring(self.pid)); return end
  self.stdout:read_start(function(err, chunk)
    if err then vim.schedule(function() self:_fail(tostring(err)) end)
    elseif chunk then
      self.output_buffer = self.output_buffer .. chunk
      while true do
        local newline = self.output_buffer:find("\n", 1, true)
        if not newline then break end
        local line = self.output_buffer:sub(1, newline - 1)
        self.output_buffer = self.output_buffer:sub(newline + 1)
        local ok, event = pcall(vim.json.decode, line)
        vim.schedule(function()
          if ok and type(event) == "table" and type(event.type) == "string" then self:_handle(event)
          else self:_fail("Invalid JSON record from Pi") end
        end)
      end
    else vim.schedule(function() self:_fail("Pi closed its output: " .. self.error_buffer:sub(-500)) end) end
  end)
  self.stderr:read_start(function(_, chunk)
    if chunk then self.error_buffer = (self.error_buffer .. chunk):sub(-4000) end
  end)
  self:_request("get_state", {}, function(state, err)
    if err then self:_fail(err.message); return end
    if not state or type(state.sessionFile) ~= "string" or (saved and state.sessionFile ~= saved) then
      self:_fail("Pi could not restore its saved session; use :PairNew to start over"); return
    end
    self.session_id = state.sessionFile
    local function ready(model)
      self.model, self.ready = model, true
      local done = self.start_callback
      self.start_callback = nil
      done({ sessionId = self.session_id, model = model })
    end
    if self.model then
      self:set_model(self.model, function(model, model_err)
        if model_err then self:_fail(model_err.message) else ready(model) end
      end)
    else ready(model_name(state.model)) end
  end)
  vim.defer_fn(function()
    if self.start_callback then self:_fail("Timed out starting Pi RPC") end
  end, 30000)
end

function Client:prompt(prompt, callback)
  if not self.ready then callback(nil, { message = "Pi is not ready" }); return end
  if self.turn then callback(nil, { message = "A Pi turn is already running" }); return end
  self.turn, self.cancelled, self.turn_error, self.stop_reason = callback, false, nil, nil
  self:_request("prompt", { message = prompt }, function(data, err)
    if self.turn ~= callback then return end
    if err then local done = self.turn; self.turn = nil; done(nil, err)
    elseif data and data.disposition == "handled" then self:_finish() end
  end)
end

function Client:cancel()
  if not self.turn then return end
  self.cancelled = true
  local turn = self.turn
  self:_request("abort", {}, function(_, err)
    if self.turn ~= turn then return end
    if err then self:_fail(err.message) else self:_finish() end
  end)
end

function Client:reset()
  self:stop()
  self.session_id = nil
  os.remove(self.session_file)
end

return Client
