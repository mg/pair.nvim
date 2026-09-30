local M = {}

local defaults = {
  openai = { model = "gpt-5.6-sol", key_env = "OPENAI_API_KEY",
    url = "https://api.openai.com/v1/responses" },
  anthropic = { model = "claude-sonnet-5-5", key_env = "ANTHROPIC_API_KEY",
    url = "https://api.anthropic.com/v1/messages" },
  gemini = { model = "gemini-3.8-flash", key_env = "GEMINI_API_KEY",
    url = "https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse" },
}
M.defaults = defaults

local function definitions(provider, tools)
  local result = {}
  for _, tool in ipairs(tools) do
    if provider == "openai" then
      result[#result + 1] = { type = "function", name = tool.name,
        description = tool.description, parameters = tool.parameters }
    elseif provider == "anthropic" then
      result[#result + 1] = { name = tool.name, description = tool.description,
        input_schema = tool.parameters }
    else
      result[#result + 1] = { name = tool.name, description = tool.description,
        parameters = tool.parameters }
    end
  end
  return result
end

function M.request(provider, model, history, tools)
  local declared = definitions(provider, tools)
  local messages = {}
  if provider == "openai" then
    for _, item in ipairs(history) do
      if item.role == "user" then
        messages[#messages + 1] = { role = "user", content = item.content }
      elseif item.role == "assistant" then
        if type(item.raw) == "table" and vim.islist(item.raw) then
          vim.list_extend(messages, vim.deepcopy(item.raw))
        elseif item.content ~= "" then
          messages[#messages + 1] = { role = "assistant", content = item.content }
        end
      elseif item.role == "tool" then
        messages[#messages + 1] = { type = "function_call_output",
          call_id = item.tool_call_id, output = item.content }
      end
    end
    return { model = model, input = messages, tools = declared, stream = true,
      store = false, include = { "reasoning.encrypted_content" } }
  end
  if provider == "anthropic" then
    local results = {}
    for index, item in ipairs(history) do
      if item.role == "user" then
        messages[#messages + 1] = { role = "user", content = item.content }
      elseif item.role == "assistant" then
        local blocks = type(item.raw) == "table" and item.raw or {}
        if #blocks == 0 then blocks = { { type = "text", text = item.content } } end
        messages[#messages + 1] = { role = "assistant", content = blocks }
      elseif item.role == "tool" then
        results[#results + 1] = { type = "tool_result", tool_use_id = item.tool_call_id,
          content = item.content, is_error = item.is_error == true }
        local next_item = history[index + 1]
        if not next_item or next_item.role ~= "tool" then
          messages[#messages + 1] = { role = "user", content = results }
          results = {}
        end
      end
    end
    return { model = model, max_tokens = 4096, messages = messages,
      tools = declared, stream = true }
  end
  for index, item in ipairs(history) do
    if item.role == "user" then
      messages[#messages + 1] = { role = "user", parts = { { text = item.content } } }
    elseif item.role == "assistant" then
      local raw = type(item.raw) == "table" and item.raw or nil
      messages[#messages + 1] = raw and vim.deepcopy(raw)
        or { role = "model", parts = { { text = item.content } } }
    elseif item.role == "tool" then
      local call
      for previous = index - 1, 1, -1 do
        for _, candidate in ipairs(history[previous].tool_calls or {}) do
          if candidate.id == item.tool_call_id then call = candidate; break end
        end
        if call then break end
      end
      local response = { name = call and call.name or item.name,
        response = item.is_error and { error = item.content } or { output = item.content } }
      if item.provider_id then response.id = item.provider_id end
      local prior = messages[#messages]
      if prior and prior.role == "user" and prior._pair_results then
        prior.parts[#prior.parts + 1] = { functionResponse = response }
      else
        messages[#messages + 1] = { role = "user", parts = { { functionResponse = response } },
          _pair_results = true }
      end
    end
  end
  for _, item in ipairs(messages) do item._pair_results = nil end
  return { contents = messages, tools = { { functionDeclarations = declared } } }
end

function M.new_stream(provider, on_text)
  local state = { text = "", calls = {}, raw = {}, done = false }
  function state:accept(event)
    if type(event) ~= "table" then return end
    if event.error or event.type == "error" then
      self.error = type(event.error) == "table" and event.error.message or event.message
        or "Provider stream failed"
      return
    end
    if provider == "openai" then
      if event.type == "response.output_text.delta" or event.type == "response.refusal.delta" then
        if type(event.delta) == "string" then
          self.text = self.text .. event.delta; on_text(event.delta)
        end
      elseif event.type == "response.output_item.done" and type(event.item) == "table" then
        self.raw[#self.raw + 1] = event.item
        if event.item.type == "function_call" then
          local ok, args = pcall(vim.json.decode, event.item.arguments or "{}")
          self.calls[#self.calls + 1] = { id = event.item.call_id, name = event.item.name,
            arguments = ok and type(args) == "table" and args or {} }
        end
      elseif event.type == "response.completed" then self.done = true
      elseif event.type == "response.incomplete" then
        self.error = "OpenAI response was incomplete"
      elseif event.type == "response.failed" then
        self.error = (event.response and event.response.error and event.response.error.message)
          or "OpenAI response failed"
      end
    elseif provider == "anthropic" then
      if event.type == "content_block_start" and type(event.content_block) == "table" then
        self.raw[(event.index or 0) + 1] = vim.deepcopy(event.content_block)
      elseif event.type == "content_block_delta" and type(event.delta) == "table" then
        local block = self.raw[(event.index or 0) + 1]
        if event.delta.type == "text_delta" and type(event.delta.text) == "string" then
          self.text = self.text .. event.delta.text; on_text(event.delta.text)
          if block then block.text = (block.text or "") .. event.delta.text end
        elseif event.delta.type == "input_json_delta" and block then
          block._pair_json = (block._pair_json or "") .. (event.delta.partial_json or "")
        elseif event.delta.type == "thinking_delta" and block then
          block.thinking = (block.thinking or "") .. (event.delta.thinking or "")
        elseif event.delta.type == "signature_delta" and block then
          block.signature = (block.signature or "") .. (event.delta.signature or "")
        end
      elseif event.type == "content_block_stop" then
        local block = self.raw[(event.index or 0) + 1]
        if block and block.type == "tool_use" then
          local ok, args = pcall(vim.json.decode, block._pair_json or "{}")
          block.input = ok and type(args) == "table" and args or block.input or {}
          block._pair_json = nil
          self.calls[#self.calls + 1] = { id = block.id, name = block.name,
            arguments = block.input }
        end
      elseif event.type == "message_delta" then
        self.stop_reason = event.delta and event.delta.stop_reason
      elseif event.type == "message_stop" then self.done = true end
    else
      local candidate = event.candidates and event.candidates[1]
      local content = candidate and candidate.content
      if content then
        self.raw.role = "model"
        self.raw.parts = self.raw.parts or {}
        for _, part in ipairs(content.parts or {}) do
          self.raw.parts[#self.raw.parts + 1] = vim.deepcopy(part)
          if type(part.text) == "string" and not part.thought then
            self.text = self.text .. part.text; on_text(part.text)
          end
          if type(part.functionCall) == "table" then
            local call = part.functionCall
            self.calls[#self.calls + 1] = { id = call.id or ("gemini_" .. tostring(#self.calls + 1)),
              provider_id = call.id, name = call.name, arguments = call.args or {} }
          end
        end
        if candidate.finishReason then
          self.stop_reason = candidate.finishReason
          self.done = true
        end
      end
    end
  end
  return state
end

return M
