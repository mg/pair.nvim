local M = {}

local presets = {
  openai_api = { kind = "direct", provider = "openai" },
  anthropic_api = { kind = "direct", provider = "anthropic" },
  gemini_api = { kind = "direct", provider = "gemini" },
  codex = { kind = "codex", command = "codex" },
  claude = {
    kind = "acp",
    command = "claude-agent-acp",
    args = {},
    required_mode = "plan",
    allowed_tool_names = { "Read", "Glob", "Grep" },
    session_meta = { claudeCode = { options = {
      allowDangerouslySkipPermissions = false,
      settingSources = {},
      strictMcpConfig = true,
      mcpServers = {},
      plugins = {},
      tools = { "Read", "Glob", "Grep" },
      disallowedTools = { "Bash", "Write", "Edit", "NotebookEdit", "Agent", "Task",
        "WebFetch", "WebSearch", "Skill" },
    } } },
  },
  copilot = {
    kind = "acp",
    command = "copilot",
    args = { "--acp", "--stdio", "--available-tools=view,glob,grep",
      "--disable-builtin-mcps", "--no-custom-instructions", "--no-auto-update",
      "--no-experimental", "--no-remote-export" },
    allowed_tool_names = { "view", "glob", "grep" },
    allowed_tool_kinds = { "read" },
  },
  gemini = {
    kind = "acp",
    command = "gemini",
    args = { "--acp", "--approval-mode", "plan", "--extensions", "none",
      "--allowed-mcp-server-names", "__pair_no_mcp__" },
    required_mode = "plan",
    allowed_tool_names = { "read_file", "list_directory", "glob", "grep_search" },
  },
  antigravity = {
    kind = "antigravity",
    command = "agy",
  },
  opencode = {
    kind = "acp",
    command = "opencode",
    args = { "acp", "--pure" },
    env = {
      -- OpenCode applies permission rules in JSON key order. Keep the catch-all
      -- first; Lua table encoding can otherwise put it after the read allows.
      OPENCODE_PERMISSION = '{"*":"deny","read":"allow","glob":"allow","grep":"allow","list":"allow"}',
      OPENCODE_CONFIG_CONTENT = vim.json.encode({
        default_agent = "plan", snapshot = false, share = "disabled",
      }),
    },
    required_mode = "plan",
  },
}

local function gemini_restrictions()
  local system_dir
  if vim.fn.has("macunix") == 1 then
    system_dir = "/Library/Application Support/GeminiCli"
  elseif vim.fn.has("win32") == 1 then
    system_dir = (vim.env.ProgramData or "C:\\ProgramData") .. "/gemini-cli"
  else
    system_dir = "/etc/gemini-cli"
  end
  if vim.fn.filereadable(system_dir .. "/settings.json") == 1
    or #vim.fn.globpath(system_dir .. "/policies", "*.toml", false, true) > 0 then
    return nil, "Gemini has system settings or policies that Pair cannot safely override"
  end
  local settings = vim.api.nvim_get_runtime_file("config/pair-gemini-settings.json", false)[1]
  local policy = vim.api.nvim_get_runtime_file("config/pair-gemini-policy.toml", false)[1]
  if not settings or vim.fn.filereadable(settings) ~= 1
    or not policy or vim.fn.filereadable(policy) ~= 1 then
    return nil, "Pair's Gemini read-only settings or policy file is missing"
  end
  return { settings = settings, policy = policy }
end

function M.names(config)
  local names = { "codex", "claude", "copilot", "gemini", "antigravity", "opencode",
    "openai_api", "anthropic_api", "gemini_api" }
  for name in pairs(config.agents or {}) do
    if not presets[name] then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

function M.resolve(name, config)
  if type(name) ~= "string" or not name:match("^[%w_-]+$") then
    return nil, "Pair backend names must contain only letters, digits, underscores, or hyphens"
  end
  local custom = not presets[name] and (config.agents or {})[name]
  local spec = presets[name] or custom
  if not spec then return nil, "Unknown Pair backend: " .. name end
  if spec.kind == "direct" and presets[name] then
    local provider = spec.provider
    local defaults = require("pair.direct_providers").defaults[provider]
    local key = (config.api_keys or {})[provider]
    if key ~= nil and type(key) ~= "string" and type(key) ~= "function" then
      return nil, "Direct API key for " .. provider .. " must be a string or callback"
    end
    local endpoint = (config.api_endpoints or {})[provider]
    if endpoint ~= nil and (type(endpoint) ~= "string" or endpoint:find("[%c]") or not (
      endpoint:match("^https://[%w%.%-]+[:/]?")
      or endpoint:match("^http://127%.0%.0%.1:%d+/?")
      or endpoint:match("^http://localhost:%d+/?"))) then
      return nil, "Direct API endpoint for " .. provider .. " must use HTTPS or loopback HTTP"
    end
    return { kind = "direct", provider = provider,
      model = (config.models or {})[name] or defaults.model,
      key_env = defaults.key_env, api_key = key, endpoint = endpoint }
  end
  if type(spec.command) ~= "string" or spec.command == "" then
    return nil, "Pair backend " .. name .. " needs a command"
  end
  if spec.kind == "codex" then
    return { kind = "codex", command = name == "codex" and config.command or spec.command,
      model = (config.models or {})[name] }
  end
  if spec.kind == "antigravity" then
    return { kind = "antigravity", command = spec.command,
      model = (config.models or {})[name] }
  end
  if spec.kind ~= "acp" or type(spec.args) ~= "table" then
    return nil, "Pair backend " .. name .. " needs kind = 'acp' and an args list"
  end
  for _, arg in ipairs(spec.args) do
    if type(arg) ~= "string" then return nil, "ACP arguments must be strings" end
  end
  if custom and spec.restricted ~= true then
    return nil, "Custom ACP backend " .. name .. " requires restricted = true and a read-only tool configuration"
  end
  local args = vim.deepcopy(spec.args)
  local env = vim.deepcopy(spec.env)
  if name == "gemini" then
    local restrictions, err = gemini_restrictions()
    if not restrictions then return nil, err end
    args[#args + 1] = "--admin-policy"
    args[#args + 1] = restrictions.policy
    env = env or {}
    env.GEMINI_CLI_SYSTEM_SETTINGS_PATH = restrictions.settings
  end
  return {
    kind = "acp", command = spec.command, args = args,
    env = env, required_mode = spec.required_mode,
    session_meta = vim.deepcopy(spec.session_meta),
    allowed_tool_names = vim.deepcopy(spec.allowed_tool_names),
    allowed_tool_kinds = vim.deepcopy(spec.allowed_tool_kinds),
    model = (config.models or {})[name], custom = type(custom) == "table",
  }
end

return M
