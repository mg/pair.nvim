vim.opt.rtp:append(vim.fn.getcwd())
local Client = require("pair.direct_api")
local Providers = require("pair.direct_providers")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "live value" }, root .. "/main.lua")

local function events(provider, call)
  if provider == "openai" then
    if call then return {
      { type = "response.output_item.done", item = { type = "function_call", name = "read_file",
        call_id = "call_a", arguments = '{"path":"main.lua"}' } },
      { type = "response.completed" },
    } end
    return { { type = "response.output_text.delta", delta = "The live value is here." },
      { type = "response.output_item.done", item = { type = "message", role = "assistant",
        content = { { type = "output_text", text = "The live value is here." } } } },
      { type = "response.completed" } }
  end
  if provider == "anthropic" then
    if call then return {
      { type = "content_block_start", index = 0,
        content_block = { type = "thinking", thinking = "" } },
      { type = "content_block_delta", index = 0,
        delta = { type = "thinking_delta", thinking = "Inspect the file." } },
      { type = "content_block_delta", index = 0,
        delta = { type = "signature_delta", signature = "opaque-signature" } },
      { type = "content_block_stop", index = 0 },
      { type = "content_block_start", index = 1,
        content_block = { type = "tool_use", id = "toolu_a", name = "read_file", input = {} } },
      { type = "content_block_delta", index = 1,
        delta = { type = "input_json_delta", partial_json = '{"path":"main.lua"}' } },
      { type = "content_block_stop", index = 1 }, { type = "message_stop" },
    } end
    return { { type = "content_block_start", index = 0,
        content_block = { type = "text", text = "" } },
      { type = "content_block_delta", index = 0,
        delta = { type = "text_delta", text = "The live value is here." } },
      { type = "content_block_stop", index = 0 }, { type = "message_stop" } }
  end
  if call then return { { candidates = { { content = { role = "model", parts = {
    { functionCall = { name = "read_file", args = { path = "main.lua" } },
      thoughtSignature = "opaque" } } }, finishReason = "STOP" } } } } end
  return { { candidates = { { content = { role = "model", parts = {
    { text = "The live " } } } } } },
    { candidates = { { content = { role = "model", parts = {
      { text = "value is here." } } }, finishReason = "STOP" } } } }
end

for _, provider in ipairs({ "openai", "anthropic", "gemini" }) do
  local pointer = root .. "/" .. provider .. ".session"
  local requests, updates = {}, {}
  local function request(_, body, accept, done)
    requests[#requests + 1] = body
    if #requests == 1 then
      if provider == "openai" then
        assert(body.store == false and body.include[1] == "reasoning.encrypted_content")
        assert(body.tools[1].type == "function")
      elseif provider == "anthropic" then
        assert(body.tools[1].input_schema and body.max_tokens)
      else
        assert(body.tools[1].functionDeclarations[1].name == "list_files")
      end
    else
      local encoded = vim.json.encode(body)
      assert(encoded:find("live value", 1, true), provider .. " lost tool result")
      if provider == "gemini" then assert(encoded:find("opaque", 1, true)) end
      if provider == "anthropic" then assert(encoded:find("opaque-signature", 1, true)) end
    end
    for _, event in ipairs(events(provider, #requests == 1)) do accept(event) end
    done()
  end
  local client = Client.new({ provider = provider, model = Providers.defaults[provider].model,
    cwd = root, session_file = pointer, api_key = "test-key", request = request,
    on_update = function(update) updates[#updates + 1] = update end })
  local started, start_err
  client:start(function(value, err) started, start_err = value, err end)
  assert(started and not start_err)
  local answer, answer_err
  client:prompt("Inspect main.lua", function(value, err) answer, answer_err = value, err end)
  assert(answer and answer.stopReason == "end_turn", vim.inspect(answer_err))
  assert(#requests == 2)
  assert(vim.fn.filereadable(pointer) == 1)
  assert(vim.fn.filereadable(pointer .. ".json") == 1)
  local text, tools = "", 0
  for _, update in ipairs(updates) do
    if update.sessionUpdate == "agent_message_chunk" then text = text .. update.content.text end
    if update.sessionUpdate == "tool_call" then tools = tools + 1 end
  end
  assert(text == "The live value is here." and tools == 1)
  local restored = Client.new({ provider = provider, model = Providers.defaults[provider].model,
    cwd = root, session_file = pointer, api_key = "test-key", request = request,
    on_update = function() end })
  local resumed
  restored:start(function(value) resumed = value end)
  assert(resumed and resumed.sessionId == started.sessionId)
  assert(#restored.session:history() == 4)
  assert(restored.session:history()[3].content == "live value\n")
  local continued, continued_err
  restored:prompt("What did you find?", function(value, err)
    continued, continued_err = value, err
  end)
  assert(continued and continued.stopReason == "end_turn", vim.inspect(continued_err))
  assert(#requests == 3 and #restored.session:history() == 6)
  client:stop(); restored:stop()
end

local held
local cancelled = Client.new({ provider = "openai", model = "gpt-4.1-mini",
  cwd = root, session_file = root .. "/cancel.session", api_key = "test-key",
  request = function(_, _, accept, done) held = { accept, done } end,
  on_update = function() end })
cancelled:start(function(value) assert(value) end)
local reason
cancelled:prompt("long request", function(value) reason = value and value.stopReason end)
cancelled:cancel()
assert(reason == "cancelled")
held[1]({ type = "response.completed" }); held[2]()
assert(vim.fn.filereadable(root .. "/cancel.session") == 0)
local Session = require("pair.direct_session")
local limit_path = root .. "/limit.session"
local limited = assert(Session.new({ path = limit_path .. ".json" }))
for _ = 1, 10 do
  assert(limited:append({ role = "user", content = string.rep("x", 102000) }))
  assert(limited:append({ role = "assistant", content = string.rep("y", 102000) }))
end
assert(limited:save())
vim.fn.writefile({ "abc123" }, limit_path)
local called = false
local limit_client = Client.new({ provider = "openai", model = "gpt-4.1-mini",
  cwd = root, session_file = limit_path, api_key = "test-key",
  request = function() called = true end, on_update = function() end })
limit_client:start(function(value) assert(value) end)
local limit_error
limit_client:prompt("one more turn", function(_, err) limit_error = err end)
assert(limit_error and limit_error.message:find(":PairNew", 1, true) and not called)
vim.fn.delete(root, "rf")
print("Pair direct API mock tests passed")
