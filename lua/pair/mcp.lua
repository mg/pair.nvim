local M = {}

M.disabled_features = { "plugins", "apps", "hooks", "multi_agent", "browser_use", "computer_use" }

function M.add_disabled_features(args)
  for _, feature in ipairs(M.disabled_features) do
    args[#args + 1] = "--disable"
    args[#args + 1] = feature
  end
end

function M.disabled_servers(command, cwd)
  local listed = vim.system({ command, "mcp", "list", "--json" }, { cwd = cwd, text = true }):wait(10000)
  if listed.code ~= 0 then
    return nil, "Could not inspect Codex MCP configuration; refusing to start without a read-only tool boundary"
  end
  local ok, servers = pcall(vim.json.decode, listed.stdout)
  if not ok or type(servers) ~= "table" then
    return nil, "Could not parse Codex MCP configuration; refusing to start"
  end
  local disabled = {}
  for _, server in ipairs(servers) do
    if type(server.name) == "string" and server.enabled then
      if not server.name:match("^[%w_-]+$") then
        return nil, "Cannot safely disable MCP server with unsupported name: " .. server.name
      end
      disabled[#disabled + 1] = server.name
    end
  end
  table.sort(disabled)
  return disabled
end

return M
