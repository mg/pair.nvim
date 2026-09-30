vim.opt.rtp:append(vim.fn.getcwd())
local port = assert(vim.env.PAIR_TEST_HTTP_PORT)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
for _, provider in ipairs({ "openai", "anthropic", "gemini" }) do
  local chunks = {}
  local client = require("pair.direct_api").new({ provider = provider,
    model = provider == "openai" and "gpt-4.1-mini" or "claude-sonnet-5-5",
    cwd = root, session_file = root .. "/" .. provider .. ".session", api_key = "test-key",
    endpoint = "http://127.0.0.1:" .. port .. "/" .. provider,
    on_update = function(update)
      if update.sessionUpdate == "agent_message_chunk" then
        chunks[#chunks + 1] = update.content.text
      end
    end })
  client:start(function(value, err) assert(value, vim.inspect(err)) end)
  local result, failure
  client:prompt("Say hello", function(value, err) result, failure = value, err end)
  assert(vim.wait(5000, function() return result or failure end, 10), "HTTP request timed out")
  assert(result and result.stopReason == "end_turn", vim.inspect(failure))
  assert(#chunks == 2 and table.concat(chunks) == "Hello from HTTP")
  assert(vim.fn.filereadable(root .. "/" .. provider .. ".session") == 1)
  client:stop()
end
for _, item in ipairs({
  { route = "context", marker = "context limit" },
  { route = "auth", marker = "authentication" },
  { route = "quota", marker = "quota" },
  { route = "server", marker = "service error" },
}) do
  local client = require("pair.direct_api").new({ provider = "openai",
    model = "gpt-4.1-mini", cwd = root,
    session_file = root .. "/error-" .. item.route,
    api_key = "test-key",
    endpoint = "http://127.0.0.1:" .. port .. "/openai/" .. item.route,
    on_update = function() end })
  client:start(function(value) assert(value) end)
  local failure
  client:prompt("trigger error", function(_, err) failure = err end)
  assert(vim.wait(5000, function() return failure end, 10))
  assert(failure.message:find(item.marker, 1, true), failure.message)
  assert(not failure.message:find("context window exceeded", 1, true)
    or item.route == "context")
  client:stop()
end
vim.fn.delete(root, "rf")
print("Pair direct API HTTP streaming tests passed")
