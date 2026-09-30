local uv = vim.uv or vim.loop

local Session = {}
Session.__index = Session

local max_messages = 400
local max_bytes = 2 * 1024 * 1024

local function valid_message(item)
  if type(item) ~= "table" or type(item.role) ~= "string" then return false end
  if item.role == "user" then return type(item.content) == "string" end
  if item.role == "assistant" then
    if type(item.content) ~= "string" then return false end
    if item.tool_calls == nil then return true end
    if type(item.tool_calls) ~= "table" or not vim.islist(item.tool_calls) then return false end
    for _, call in ipairs(item.tool_calls) do
      if type(call) ~= "table" or type(call.id) ~= "string"
        or type(call.name) ~= "string" or type(call.arguments) ~= "table" then return false end
    end
    return true
  end
  if item.role == "tool" then
    return type(item.content) == "string" and type(item.tool_call_id) == "string"
  end
  return false
end

local function pending(messages)
  local open = {}
  for _, item in ipairs(messages) do
    for _, call in ipairs(item.tool_calls or {}) do open[call.id] = true end
    if item.role == "tool" then open[item.tool_call_id] = nil end
  end
  return open
end

function Session.new(opts)
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then
    return nil, "Direct session needs a state path"
  end
  return setmetatable({ path = opts.path, messages = {}, version = 1 }, Session)
end

function Session.load(path)
  local file = io.open(path, "rb")
  if not file then return nil, "Direct session is missing" end
  local raw = file:read(max_bytes + 1)
  file:close()
  if not raw or #raw > max_bytes then return nil, "Direct session exceeds size limit" end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" or decoded.version ~= 1
    or type(decoded.messages) ~= "table" or not vim.islist(decoded.messages)
    or #decoded.messages > max_messages then
    return nil, "Direct session is invalid"
  end
  local session = setmetatable({ path = path, messages = {}, version = 1 }, Session)
  for _, item in ipairs(decoded.messages) do
    local appended = session:append(item)
    if not appended then return nil, "Direct session has an invalid message sequence" end
  end
  return session
end

function Session:append(item)
  if not valid_message(item) then return nil, "Invalid direct session message" end
  if #self.messages >= max_messages then return nil, "Direct session reached its message limit" end
  local open = pending(self.messages)
  if item.role == "tool" then
    if not open[item.tool_call_id] then return nil, "Unknown or completed tool call" end
  elseif next(open) then
    return nil, "Complete pending tool calls before another message"
  end
  if item.role == "assistant" and item.tool_calls then
    local ids = {}
    for _, prior in ipairs(self.messages) do
      for _, call in ipairs(prior.tool_calls or {}) do ids[call.id] = true end
    end
    for _, call in ipairs(item.tool_calls) do
      if ids[call.id] or call.id == "" or call.name == "" then
        return nil, "Invalid or duplicate tool call"
      end
      ids[call.id] = true
    end
  end
  local copy = vim.deepcopy(item)
  self.messages[#self.messages + 1] = copy
  local encoded = vim.json.encode({ version = 1, messages = self.messages })
  if #encoded > max_bytes then
    self.messages[#self.messages] = nil
    return nil, "Direct session reached its size limit"
  end
  return true
end

function Session:history()
  return vim.deepcopy(self.messages)
end

function Session:usage()
  return { messages = #self.messages,
    bytes = #vim.json.encode({ version = 1, messages = self.messages }),
    max_messages = max_messages, max_bytes = max_bytes }
end

function Session:pending()
  return vim.deepcopy(pending(self.messages))
end

function Session:save()
  local encoded = vim.json.encode({ version = 1, messages = self.messages })
  if #encoded > max_bytes then return nil, "Direct session reached its size limit" end
  local temp = self.path .. ".tmp." .. tostring(uv.hrtime())
  local fd, err = uv.fs_open(temp, "w", 384) -- 0600 from creation
  if not fd then return nil, err end
  local written, write_err = uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  if written ~= #encoded then os.remove(temp); return nil, write_err end
  local moved, move_err = os.rename(temp, self.path)
  if not moved then os.remove(temp); return nil, move_err end
  return true
end

return Session
