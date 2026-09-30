local uv = vim.uv or vim.loop
local Session = require("pair.direct_session")
local Research = require("pair.research")
local providers = require("pair.direct_providers")

local Client = {}
Client.__index = Client

local function quote(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function key_for(self)
  local value = self.api_key
  if type(value) == "function" then
    local ok, key = pcall(value)
    if not ok then return nil, "API key callback failed" end
    value = key
  end
  if not value then value = vim.env[self.key_env] end
  if type(value) ~= "string" or value == "" then
    return nil, "Missing " .. self.key_env .. " for " .. self.provider
  end
  if value:find("[%c]") then return nil, "API key contains control characters" end
  return value
end

local function save_pointer(path, id)
  local temp = path .. ".tmp." .. tostring(uv.hrtime())
  local fd = uv.fs_open(temp, "w", 384)
  if not fd then return nil, "Could not save direct API session pointer" end
  uv.fs_write(fd, id .. "\n", 0)
  uv.fs_close(fd)
  local ok = uv.fs_rename(temp, path)
  if not ok then uv.fs_unlink(temp); return nil, "Could not save direct API session pointer" end
  return true
end

local function make_parser(accept, on_status)
  local buffer, lines = "", {}
  local function dispatch()
    local data = {}
    for _, line in ipairs(lines) do
      if line:sub(1, 5) == "data:" then data[#data + 1] = vim.trim(line:sub(6)) end
    end
    lines = {}
    if #data > 0 then
      local payload = table.concat(data, "\n")
      if payload ~= "[DONE]" then
        local ok, decoded = pcall(vim.json.decode, payload)
        if ok then accept(decoded) end
      end
    end
  end
  return function(chunk, final)
    buffer = buffer .. (chunk or "")
    while true do
      local index = buffer:find("\n", 1, true)
      if not index then break end
      local line = buffer:sub(1, index - 1):gsub("\r$", "")
      buffer = buffer:sub(index + 1)
      local status = line:match("^PAIR_HTTP_STATUS:(%d%d%d)$")
      if status then on_status(tonumber(status))
      elseif line == "" then dispatch()
      else lines[#lines + 1] = line end
    end
    if final then
      if buffer ~= "" then lines[#lines + 1] = buffer end
      dispatch()
    end
  end
end

local function curl_request(self, body, on_event, done)
  local key, key_err = key_for(self)
  if not key then done(key_err); return end
  local encoded = vim.json.encode(body)
  local path = vim.fn.tempname()
  local fd = uv.fs_open(path, "w", 384)
  if not fd then done("Could not create API request body"); return end
  local written = uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  if written ~= #encoded then uv.fs_unlink(path); done("Could not write API request body"); return end
  local headers = { "header = " .. quote("Content-Type: application/json") }
  if self.provider == "openai" then
    headers[#headers + 1] = "header = " .. quote("Authorization: Bearer " .. key)
  elseif self.provider == "anthropic" then
    headers[#headers + 1] = "header = " .. quote("x-api-key: " .. key)
    headers[#headers + 1] = "header = " .. quote("anthropic-version: 2023-06-01")
  else
    headers[#headers + 1] = "header = " .. quote("x-goog-api-key: " .. key)
  end
  key = nil
  local url = self.endpoint
  if not url then
    url = providers.defaults[self.provider].url
    if self.provider == "gemini" then
      url = string.format(url, vim.uri_encode(self.model, "rfc3986"))
    end
  end
  local http_status, response_head
  local parse = make_parser(on_event, function(status) http_status = status end)
  self.process = vim.system({ "curl", "--disable", "--silent", "--show-error", "--fail-with-body",
    "--no-buffer", "--max-time", "180", "--request", "POST", "--config", "-",
    "--data-binary", "@" .. path,
    "--write-out", "\nPAIR_HTTP_STATUS:%{http_code}\n", url }, {
    cwd = self.cwd, stdin = table.concat(headers, "\n") .. "\n", text = true,
    stdout = function(err, chunk)
      vim.schedule(function()
        if err then return end
        if chunk and not self.stopped then
          response_head = (response_head or "") .. chunk:sub(1, 8192)
          response_head = response_head:sub(1, 8192)
          parse(chunk)
        end
      end)
    end,
    stderr = function() end,
  }, function(result)
    vim.schedule(function()
      uv.fs_unlink(path)
      self.process = nil
      if self.stopped then return end
      parse(nil, true)
      if result.code ~= 0 or (http_status and http_status >= 400) then
        -- Never display provider error bodies: they may include submitted code.
        local body_lower = (response_head or ""):lower()
        if http_status == 401 or http_status == 403 then
          done("API authentication or model access failed (HTTP " .. http_status
            .. "). Check the key and selected model")
        elseif http_status == 429 then
          done("API rate limit or quota reached (HTTP 429). Retry after checking provider quota")
        elseif body_lower:find("context_length_exceeded", 1, true)
          or body_lower:find("context window", 1, true)
          or body_lower:find("too many tokens", 1, true)
          or body_lower:find("input is too long", 1, true) then
          done("Provider context limit reached. Use :PairNew for a fresh conversation;"
            .. " the previous one remains in :PairSessions")
        elseif http_status and http_status >= 500 then
          done("Provider service error (HTTP " .. http_status .. "). Retry later")
        elseif http_status and http_status >= 400 then
          done("API rejected the request (HTTP " .. http_status
            .. "). Check the selected model and provider access")
        elseif result.code == 28 then
          done("API request timed out. Retry or use :PairNew")
        else
          done("API connection failed (curl exit " .. tostring(result.code) .. ")")
        end
      else done(nil) end
    end)
  end)
end

function Client.new(opts)
  return setmetatable({ provider = opts.provider, model = opts.model,
    cwd = opts.cwd, session_file = opts.session_file, api_key = opts.api_key,
    key_env = opts.key_env or providers.defaults[opts.provider].key_env,
    endpoint = opts.endpoint, request = opts.request, on_update = opts.on_update,
    on_error = opts.on_error, ready = false }, Client)
end

function Client:start(callback)
  if not providers.defaults[self.provider] then
    callback(nil, { message = "Unknown direct API provider" }); return
  end
  if not self.request and vim.fn.executable("curl") ~= 1 then
    callback(nil, { message = "curl executable not found" }); return
  end
  local key, key_err = key_for(self)
  if not key then callback(nil, { message = key_err }); return end
  local research, research_err = Research.new({ root = self.cwd })
  if not research then callback(nil, { message = research_err }); return end
  self.research = research
  local file = io.open(self.session_file, "r")
  if file then
    self.session_id = file:read("*l")
    file:close()
    if not self.session_id or not self.session_id:match("^[%da-fA-F%-]+$") then
      callback(nil, { message = "Saved direct API session ID is invalid" }); return
    end
    local session, err = Session.load(self.session_file .. ".json")
    if not session then callback(nil, { message = err }); return end
    self.session = session
  else
    self.session_id = vim.fn.sha256(tostring(uv.hrtime()) .. self.cwd):sub(1, 32)
    self.session = assert(Session.new({ path = self.session_file .. ".json" }))
  end
  self.ready = true
  self.stopped = false
  callback({ sessionId = self.session_id, model = self.model })
end

function Client:prompt(prompt, callback)
  if not self.ready then callback(nil, { message = "Direct API session is not ready" }); return end
  if self.turn then callback(nil, { message = "Direct API turn is already active" }); return end
  local history = self.session:history()
  history[#history + 1] = { role = "user", content = prompt }
  local usage = self.session:usage()
  local projected = #vim.json.encode({ version = 1, messages = history })
  if projected + 64 * 1024 >= usage.max_bytes
    or usage.messages + 8 >= usage.max_messages then
    callback(nil, { message = "Direct API conversation is near its local history limit."
      .. " Use :PairNew to start a fresh conversation; the previous one remains"
      .. " available through :PairSessions" })
    return
  end
  local turn = { callback = callback, history = history, rounds = 0 }
  self.turn = turn
  local function finish(result, err)
    if self.turn ~= turn then return end
    self.turn = nil
    callback(result, err and { message = err } or nil)
  end
  local function run()
    if self.turn ~= turn then return end
    turn.rounds = turn.rounds + 1
    if turn.rounds > 8 then finish(nil, "Direct API research limit reached"); return end
    local stream = providers.new_stream(self.provider, function(delta)
      if self.turn == turn and type(delta) == "string" and delta ~= "" then
        self.on_update({ sessionUpdate = "agent_message_chunk",
          content = { type = "text", text = delta } })
      end
    end)
    local body = providers.request(self.provider, self.model, turn.history, self.research:tools())
    local transport = self.request or function(_, payload, accept, done)
      curl_request(self, payload, accept, done)
    end
    transport(self, body, function(event)
      if self.turn == turn then stream:accept(event) end
    end, function(err)
      if self.turn ~= turn then return end
      if err or stream.error then finish(nil, err or stream.error); return end
      if not stream.done then finish(nil, "Provider stream ended without completion"); return end
      if self.provider == "anthropic" and stream.stop_reason
        and stream.stop_reason ~= "end_turn" and stream.stop_reason ~= "tool_use" then
        finish(nil, "Anthropic stopped: " .. stream.stop_reason); return
      end
      if self.provider == "gemini" and stream.stop_reason
        and stream.stop_reason ~= "STOP" then
        finish(nil, "Gemini stopped: " .. stream.stop_reason); return
      end
      local assistant = { role = "assistant", content = stream.text,
        tool_calls = #stream.calls > 0 and stream.calls or nil, raw = stream.raw }
      turn.history[#turn.history + 1] = assistant
      if #stream.calls > 0 then
        if stream.text ~= "" then
          self.on_update({ sessionUpdate = "agent_message_reset" })
        end
        for index, call in ipairs(stream.calls) do
          if self.provider == "gemini" and not call.provider_id then
            call.id = "gemini_" .. tostring(#self.session.messages + 1) .. "_"
              .. tostring(turn.rounds) .. "_" .. tostring(index)
          end
          if type(call.name) ~= "string" or type(call.arguments) ~= "table"
            or type(call.id) ~= "string" then
            finish(nil, "Provider returned an invalid research call"); return
          end
          local called, result = pcall(self.research.call, self.research,
            call.name, call.arguments)
          if not called then result = { ok = false, error = "Research tool failed" } end
          self.on_update({ sessionUpdate = "tool_call", toolCallId = call.id,
            title = call.name, kind = "read", status = "completed",
            output = result.ok and result.content or result.error })
          turn.history[#turn.history + 1] = { role = "tool", tool_call_id = call.id,
            provider_id = call.provider_id, name = call.name, is_error = not result.ok,
            content = result.ok and result.content or result.error }
        end
        run()
      else
        local candidate = assert(Session.new({ path = self.session.path }))
        for _, item in ipairs(turn.history) do
          local ok, append_err = candidate:append(item)
          if not ok then
            finish(nil, append_err .. ". Use :PairNew for a fresh conversation;"
              .. " the previous one remains in :PairSessions")
            return
          end
        end
        local saved, save_err = candidate:save()
        if not saved then finish(nil, save_err); return end
        local pointer, pointer_err = save_pointer(self.session_file, self.session_id)
        if not pointer then finish(nil, pointer_err); return end
        self.session = candidate
        local current_usage = candidate:usage()
        if not self.warned_limit and (current_usage.bytes >= current_usage.max_bytes * 0.75
          or current_usage.messages >= current_usage.max_messages * 0.75) then
          self.warned_limit = true
          self.on_update({ sessionUpdate = "pair_notice",
            text = "Direct API conversation is nearing its local history limit."
              .. " Use :PairNew when ready; you can reopen this chat with :PairSessions." })
        end
        finish({ stopReason = "end_turn" })
      end
    end)
  end
  run()
end

function Client:cancel()
  if self.process then self.process:kill(15) end
  local turn = self.turn
  self.turn = nil
  if turn then turn.callback({ stopReason = "cancelled" }) end
end

function Client:stop()
  self.stopped = true
  self.ready = false
  if self.process then self.process:kill(15) end
  self.process = nil
  self.turn = nil
end

function Client:list_models(callback)
  local models = {
    openai = { "gpt-5.6-sol", "gpt-5-mini", "gpt-4.1-mini" },
    anthropic = { "claude-sonnet-5-5", "claude-haiku-4-5-20251001", "claude-opus-5-5" },
    gemini = { "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-2.5-flash" },
  }
  local choices, seen = {}, {}
  for _, value in ipairs(models[self.provider] or {}) do
    choices[#choices + 1] = { value = value, label = value, default = value == self.model }
    seen[value] = true
  end
  if not seen[self.model] then
    choices[#choices + 1] = { value = self.model, label = self.model, default = true }
  end
  callback(choices)
end

function Client:set_model(model, callback)
  if type(model) ~= "string" or not model:match("^[%w_.%-]+$") then
    callback(nil, { message = "Invalid model ID" }); return
  end
  self.model = model
  callback(model)
end

return Client
