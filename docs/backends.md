# Backend setup

Use `:PairBackends` to choose a backend, or `:PairBackend {name}` to set one directly. The picker checks startup before switching the visible conversation; the direct command connects on your next message. Each workspace and backend has separate history.

Set a default in your config:

```lua
require("pair").setup({ backend = "codex" })
```

Use `:PairModel` to choose a model or `:PairModel model-id` to enter one. Availability depends on your account. See [TRANSPORT.md](../TRANSPORT.md) for tested versions, account routes, and tool restrictions.

## CLI agents

| Backend name | Executable | Setup |
| --- | --- | --- |
| `codex` | `codex` | Sign in with `codex login`. Pair uses app-server and the existing CLI login. |
| `antigravity` | `agy` | Install and sign in through Antigravity CLI. |
| `copilot` | `copilot` | Install `@github/copilot` and sign in through its CLI. BYOK is unverified in Pair. |
| `opencode` | `opencode` | Use `opencode auth login` to configure a provider. The tested route is OpenRouter with `openrouter/openai/gpt-4.1-mini`. |
| `claude` | `claude-agent-acp` | Install `@agentclientprotocol/claude-agent-acp`, then run `claude-agent-acp --cli auth login`. Authenticated Pair workflows remain unverified. |
| `gemini` | `gemini` | Legacy experimental route. The personal Google login tested here was rejected; eligible enterprise or paid API-key routes still need testing. |

All executables must be on Neovim's `PATH`. Antigravity also requires macOS `sandbox-exec` or Linux `bubblewrap` (`bwrap`). Other CLI presets use the CLI's read-only sandbox or inspection tool settings. See [SECURITY.md](../SECURITY.md).

For the tested OpenCode model:

```lua
require("pair").setup({
  backend = "opencode",
  models = { opencode = "openrouter/openai/gpt-4.1-mini" },
})
```

OpenCode's default free model refused ACP requests in testing. Other provider/model routes remain unverified. Antigravity does not report a model catalog; set `models.antigravity` before starting a conversation if needed. The optional older Codex transport, `transport = "exec"`, does not offer the same streaming or verified session restoration as app-server.

## Commands and generated output

Antigravity can run commands, tests, and builds. Pair launches its process and shell children in a filesystem sandbox: source files stay read-only, and temporary files use a private `$TMPDIR`. Commands that need to write inside the project require explicit output directories:

```lua
require("pair").setup({
  backend = "antigravity",
  commands = { writable_paths = { "build", "generated" } },
})
```

Create those directories first. Paths are relative to Neovim's working directory and apply whenever that configuration is used. Pair rejects workspace-root grants, traversal, symlink directories, hard-linked output files, and directories containing Git metadata. Choose only folders whose contents the agent may create, replace, or delete. Generated output goes straight to disk, without proposal review; ordinary source changes still use Ask/Change/Insert proposals.

Commands operate on saved files, even though prompts and inspection prefer unsaved buffers. Save changes before asking the agent to test them. A command failure appears in expandable tool activity and does not end the conversation. Pair does not retry outside its filesystem sandbox.

This configuration currently applies to Antigravity. Codex can run tests within its own read-only sandbox, but does not use these writable output grants. ACP presets and direct APIs still expose inspection tools only. Unsupported platforms cannot start Antigravity with command permissions; `:checkhealth pair` reports the dependency.

## Direct provider APIs

These experimental backends need `curl` and a key in Neovim's environment:

| Backend name | Environment variable |
| --- | --- |
| `openai_api` | `OPENAI_API_KEY` |
| `anthropic_api` | `ANTHROPIC_API_KEY` |
| `gemini_api` | `GEMINI_API_KEY` |

They use provider API billing separately from chat or CLI subscriptions. Pair's mock and local HTTP checks pass; authenticated provider workflows still need validation.

```lua
require("pair").setup({ backend = "openai_api" })
```

A credential manager can supply the key through a callback:

```lua
require("pair").setup({
  backend = "openai_api",
  api_keys = { openai = function() return your_key_lookup() end },
})
```

Pair reads credentials when needed and does not save them. Keys reach `curl` through stdin rather than process arguments; request bodies use temporary files with owner-only permissions. Direct APIs expose bounded file listing, reading, search, and git inspection. File reads prefer loaded Neovim buffers, including unsaved edits. They have no arbitrary shell or file-write tool.

History is limited locally to 2 MiB or 400 messages. Pair warns near that limit and asks for `:PairNew` before it fills; provider context limits may arrive sooner. Older transcripts remain available through `:PairSessions`.

## Custom ACP agents

Configure the agent's own tool restrictions before using this experimental option:

```lua
require("pair").setup({
  agents = {
    research_agent = {
      kind = "acp",
      command = "/path/to/agent",
      args = { "--acp", "--your-read-only-tool-flags" },
      restricted = true,
    },
  },
})
```

`restricted = true` declares that you configured inspection-only tools. Pair cannot enforce that declaration inside another process. Pair denies ACP permission requests and offers no client filesystem-write or terminal tools. Agents need `session/load` to restore conversations.

## Local development

Point lazy.nvim at your checkout:

```lua
{
  dir = "/path/to/pair.nvim",
  config = function() require("pair").setup() end,
}
```

Or add the checkout to `runtimepath` and call `require("pair").setup()`. Set `keymaps = false` to define your own mappings or `command = "/path/to/codex"` to choose a Codex executable. Use `:checkhealth pair` for diagnostics and `:help pair` for commands, context controls, and session behavior.
