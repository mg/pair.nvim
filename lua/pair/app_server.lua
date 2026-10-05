local uv = vim.uv or vim.loop
local mcp = require("pair.mcp")

local Client = {}
Client.__index = Client

local function close(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function error_message(err)
  if type(err) == "table" then return err.message or vim.inspect(err) end
  return tostring(err)
end

local function message_text(item)
  if type(item.text) == "string" then return item.text end
  local parts = {}
  for _, content in ipairs(item.content or {}) do
    if content.type == "text" and type(content.text) == "string" then
      parts[#parts + 1] = content.text
    end
  end
  return table.concat(parts)
end

function Client.new(opts)
  return setmetatable({
    command = opts.command,
    cwd = opts.cwd,
    session_file = opts.session_file,
    model = opts.model,
    on_update = opts.on_update,
    on_error = opts.on_error,
    ready = false,
    request_id = 0,
    requests = {},
    output_buffer = "",
    error_buffer = "",
  }, Client)
end

function Client:_shutdown()
  self.stopping = true
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
  self.ready = false
end

function Client:_fail(message)
  if self.stopping then return end
  local starting = self.start_callback
  local turn = self.turn
  self.start_callback = nil
  self.turn = nil
  self.requests = {}
  self:_shutdown()
  if starting then starting(nil, { message = message }) end
  if turn then turn.callback(nil, { message = message }) end
  if not starting and not turn and self.on_error then self.on_error(message) end
end

function Client:_write(value)
  if not self.stdin or self.stdin:is_closing() then return false end
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then return false end
  self.stdin:write(encoded .. "\n")
  return true
end

function Client:_request(method, params, callback)
  self.request_id = self.request_id + 1
  local id = self.request_id
  self.requests[id] = callback
  if not self:_write({ id = id, method = method, params = params }) then
    self.requests[id] = nil
    callback(nil, { message = "Could not send " .. method .. " to Codex" })
  end
end

function Client:_remember_session(id)
  self.session_id = id
  local file = io.open(self.session_file, "w")
  if not file then return false end
  file:write(id, "\n")
  file:close()
  pcall(vim.fn.setfperm, self.session_file, "rw-------")
  return true
end

function Client:_new_thread(callback)
  self:_request("thread/start", {
    cwd = self.cwd,
    model = self.model,
    approvalPolicy = "never",
    sandbox = "read-only",
  }, function(result, err)
    if err then callback(nil, err); return end
    local id = result and result.thread and result.thread.id
    if type(id) ~= "string" or not self:_remember_session(id) then
      callback(nil, { message = "Codex started a thread but Pair could not save its session" })
      return
    end
    callback(id, nil, result.thread.model)
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
    self:_write({ id = event.id, error = { code = -32601, message = "Pair does not grant agent permissions" } })
    return
  end
  local params = event.params or {}
  if event.method == "turn/started" and self.turn then
    self.turn.id = params.turn and params.turn.id or self.turn.id
    if self.turn.cancel_requested then self:cancel() end
  elseif event.method == "item/agentMessage/delta" and self.turn then
    if params.threadId == self.session_id and type(params.delta) == "string" then
      self.turn.seen_delta[params.itemId] = true
      self.on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = params.delta } })
    end
  elseif (event.method == "item/started" or event.method == "item/completed") and self.turn then
    local item = type(params.item) == "table" and params.item or {}
    if item.type == "fileChange" then
      self:_fail("Codex reported a direct file change; Pair stopped the session")
    elseif item.type == "commandExecution" then
      self.on_update({ sessionUpdate = "tool_call", id = item.id,
        title = item.command or "Inspecting project", command = item.command,
        status = event.method == "item/started" and "in_progress"
          or (item.exitCode ~= nil and item.exitCode ~= 0) and "failed" or item.status or "completed",
        output = item.aggregatedOutput, exitCode = item.exitCode })
    elseif event.method == "item/completed" and item.type == "agentMessage" and not self.turn.seen_delta[item.id] then
      local text = message_text(item)
      if text ~= "" then self.on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = text } }) end
    end
  elseif event.method == "turn/completed" and self.turn then
    local turn = params.turn or {}
    if params.threadId ~= self.session_id then return end
    local callback = self.turn.callback
    self.turn = nil
    if turn.status == "completed" then
      callback({ stopReason = "end_turn" })
    else
      local turn_error = type(turn.error) == "table" and turn.error.message or nil
      callback(nil, { message = turn_error or ("Codex turn " .. (turn.status or "failed")) })
    end
  end
end

function Client:start(callback)
  if vim.fn.executable(self.command) ~= 1 then
    callback(nil, { message = "Codex executable not found: " .. self.command })
    return
  end
  local disabled, err = mcp.disabled_servers(self.command, self.cwd)
  if not disabled then callback(nil, { message = err }); return end
  self.disabled_servers = disabled
  local args = { "app-server", "--stdio", "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"' }
  mcp.add_disabled_features(args)
  for _, name in ipairs(disabled) do
    args[#args + 1] = "-c"
    args[#args + 1] = "mcp_servers." .. name .. ".enabled=false"
  end
  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)
  self.process, self.pid = uv.spawn(self.command, {
    args = args,
    cwd = self.cwd,
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    vim.schedule(function()
      if not self.stopping then
        self:_fail("Codex app-server exited (code " .. code .. ", signal " .. signal .. "): " .. self.error_buffer:sub(-500))
      end
    end)
  end)
  if not self.process then
    close(self.stdin)
    close(self.stdout)
    close(self.stderr)
    self.stdin, self.stdout, self.stderr = nil, nil, nil
    callback(nil, { message = "Could not launch Codex app-server: " .. tostring(self.pid) })
    return
  end
  self.start_callback = callback
  self.stdout:read_start(function(read_err, chunk)
    if read_err then
      vim.schedule(function() self:_fail(error_message(read_err)) end)
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
      vim.schedule(function() self:_fail("Codex app-server closed its output: " .. self.error_buffer:sub(-500)) end)
    end
  end)
  self.stderr:read_start(function(_, chunk)
    if chunk then self.error_buffer = (self.error_buffer .. chunk):sub(-4000) end
  end)
  self:_request("initialize", { clientInfo = { name = "pair_nvim", title = "Pair.nvim", version = "0.1.1" } }, function(_, init_err)
    if init_err then self:_fail(error_message(init_err)); return end
    self:_write({ method = "initialized", params = {} })
    local file = io.open(self.session_file, "r")
    local saved_id
    if file then saved_id = file:read("*l"); file:close() end
    if saved_id and saved_id ~= "" then
      self:_request("thread/resume", {
        threadId = saved_id,
        cwd = self.cwd,
        model = self.model,
        approvalPolicy = "never",
        sandbox = "read-only",
      }, function(result, resume_err)
        if resume_err then self:_fail("Could not resume Pair session: " .. error_message(resume_err)); return end
        local id = result and result.thread and result.thread.id
        if id ~= saved_id then self:_fail("Codex resumed a different session than Pair requested"); return end
        self.session_id = id
        self.ready = true
        local start_callback = self.start_callback
        self.start_callback = nil
        start_callback({ sessionId = id, model = self.model or (result.thread and result.thread.model) })
      end)
    else
      self:_new_thread(function(id, thread_err, thread_model)
        if thread_err then self:_fail(error_message(thread_err)); return end
        self.ready = true
        local start_callback = self.start_callback
        self.start_callback = nil
        start_callback({ sessionId = id, model = self.model or thread_model })
      end)
    end
  end)
  vim.defer_fn(function()
    if self.start_callback then self:_fail("Timed out starting Codex app-server") end
  end, 30000)
end

function Client:prompt(prompt, callback)
  if not self.ready or not self.process then
    callback(nil, { message = "Codex app-server is not ready" })
    return
  end
  if self.turn then
    callback(nil, { message = "A Codex turn is already running" })
    return
  end
  local disabled, err = mcp.disabled_servers(self.command, self.cwd)
  if not disabled then callback(nil, { message = err }); return end
  if not vim.deep_equal(disabled, self.disabled_servers) then
    callback(nil, { message = "Codex MCP configuration changed; restart Neovim before continuing Pair" })
    return
  end
  local function begin()
    self.turn = { callback = callback, seen_delta = {} }
    self:_request("turn/start", {
      threadId = self.session_id,
      input = { { type = "text", text = prompt } },
      cwd = self.cwd,
      approvalPolicy = "never",
      sandboxPolicy = { type = "readOnly" },
      model = self.model,
    }, function(result, turn_err)
      if not self.turn then return end
      if turn_err then
        self.turn = nil
        callback(nil, { message = error_message(turn_err) })
        return
      end
      self.turn.id = result and result.turn and result.turn.id or self.turn.id
      if self.turn.cancel_requested then self:cancel() end
    end)
  end
  if self.session_id then
    begin()
  else
    self:_new_thread(function(_, thread_err)
      if thread_err then callback(nil, { message = error_message(thread_err) }); return end
      begin()
    end)
  end
end

function Client:list_models(callback)
  if not self.ready then callback(nil, { message = "Codex app-server is not ready" }); return end
  local choices = {}
  local seen = {}
  local function page(cursor)
    self:_request("model/list", { cursor = cursor, includeHidden = false }, function(result, err)
      if err then callback(nil, { message = "Could not list Codex models: " .. error_message(err) }); return end
      for _, item in ipairs((result or {}).data or {}) do
        local id = item.model or item.id
        if type(id) == "string" and not seen[id] and item.hidden ~= true then
          seen[id] = true
          choices[#choices + 1] = { value = id, label = item.displayName or id,
            description = item.description, default = item.isDefault == true }
        end
      end
      if result and type(result.nextCursor) == "string" and result.nextCursor ~= "" then
        page(result.nextCursor)
      else
        callback(choices)
      end
    end)
  end
  page(nil)
end

function Client:set_model(value, callback)
  self:list_models(function(choices, err)
    if err then callback(nil, err); return end
    for _, choice in ipairs(choices) do
      if choice.value == value then
        self.model = value
        callback(value)
        return
      end
    end
    callback(nil, { message = "Codex model is not available: " .. value })
  end)
end

function Client:cancel()
  if not self.turn then return end
  self.turn.cancel_requested = true
  if self.turn.id and not self.turn.interrupt_sent then
    self.turn.interrupt_sent = true
    self:_request("turn/interrupt", { threadId = self.session_id, turnId = self.turn.id }, function(_, err)
      if err then self:_fail("Could not cancel Codex turn: " .. error_message(err)) end
    end)
  end
end

function Client:stop()
  self:_shutdown()
end

function Client:reset()
  self.session_id = nil
  os.remove(self.session_file)
end

return Client
