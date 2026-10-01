# Pair.nvim

Code with an AI agent while staying hands-on in Neovim.

Chat about your project, ask about selected code, or request a change exactly where you want it. Chat and editor actions share one agent session. Proposed code appears in your unsaved buffer for you to inspect, accept, or reject.

**A note from the creator**

>I like coding with agents, but I missed being hands-on with the code.
>I noticed my knowledge of the codebase regressing.
>I built Pair to keep the conversation, research assistance, and code
>speed while giving me more control over what gets written and where.


https://github.com/user-attachments/assets/9a9e2d46-a3fb-4e9d-bd27-d2c2546eff8c

Pair is an early preview. Some backends still need live testing.

## Install

Requires **Neovim 0.11+** and a signed-in agent CLI, or `curl` and a provider API key.

With lazy.nvim:

```lua
{
  "sampsn/pair.nvim",
  config = function()
    require("pair").setup()
  end,
}
```

Pair uses Codex by default. Install the `codex` CLI and sign in with `codex login`.

For other backends or a local checkout, see [backend setup](docs/backends.md).

## Use

| Action | Command | Default key |
| --- | --- | --- |
| Toggle chat | `:PairChat` | `<leader>pc` |
| Ask about selected code | `:PairAsk` | Visual `<leader>pa` |
| Change selected code | `:PairChange` | Visual `<leader>pe` |
| Insert code at the cursor | `:PairHere` | `<leader>pi` |
| Accept / reject a proposal | `:PairAccept` / `:PairReject` | `<leader>py` / `<leader>pn` |
| View the proposal diff | `:PairDiff` | `<leader>pv` |
| Dismiss an inline answer | `:PairDismiss` | `<leader>pd` |
| Start a new chat | `:PairNew` | `<leader>pr` |
| Resume a chat | `:PairSessions` | `<leader>pS` |
| Choose an action | `:PairActions` | `<leader>pp` |

**Chat:** Use normal Vim motions in the input. `Enter` adds a line in Insert mode and sends in Normal mode. Scroll up to read earlier output while a response streams. Use `:PairCancel` to stop a request.

**Buffer requests:** Ask, Change, and Insert open a small prompt window. `Enter` submits; `Esc` followed by `q` cancels. Ask answers appear beside the code. Changes appear in the unsaved buffer with Accept, Reject, and Diff controls. Saving accepts the visible code.

**Context:** Pair sends the current buffer, including unsaved edits, by default. In a Pair input, `gC` previews the attachment and `gA` toggles the full-buffer attachment.

## Backends

Use `:PairBackends` to switch agents and `:PairModel` to choose a model. Each backend has its own conversation history.

Pair remembers your last backend and selected model for each backend across restarts and `:PairNew`. Set `remember_selection = false` to use your configured defaults at startup.

| Backend | Validation |
| --- | --- |
| Codex | Live workflow passed with an existing CLI login |
| Antigravity CLI | Live workflow passed with a personal Google account |
| GitHub Copilot CLI | Live workflow passed with an existing Copilot account |
| OpenCode | Live workflow passed with an OpenRouter key and `openrouter/openai/gpt-4.1-mini` |
| Claude Code ACP | Experimental; mock workflow and adapter startup tested |
| Legacy Gemini CLI ACP | Experimental; mock workflow tested |
| OpenAI, Anthropic, Gemini APIs | Experimental; mock and local HTTP workflows tested |

Other account and model combinations remain unverified. CLI access uses the agent's login; direct APIs use separately billed API keys. See [setup instructions](docs/backends.md) and [tested versions and results](TRANSPORT.md).

**OpenCode:** If a free model says it only works inside OpenCode, connect a provider with `opencode auth login`, then choose its model with `:PairModel`. For example, `:PairModel openrouter/openai/gpt-4.1-mini` uses an OpenRouter key and its API billing.

## Commands and writable folders

Antigravity can run tests and builds while source files stay read-only. To allow build output or generated code, create dedicated folders in your project:

```sh
mkdir -p build coverage generated
```

Then configure Pair:

```lua
require("pair").setup({
  backend = "antigravity",
  commands = { writable_paths = { "build", "coverage", "generated" } },
})
```

For example, ask “Run `cmake -S . -B build && cmake --build build`,” or “Run my client generator with output set to `generated/`.” Paths are relative to Neovim's working directory and must already exist. The agent can create, replace, or delete files in those folders directly; source edits elsewhere still require a proposal. Save your buffer before asking for tests. These grants currently apply to Antigravity only. See [command setup](docs/backends.md#commands-and-generated-output) for details.

## Privacy and limits

Your prompt and attached code go to the selected provider. Pair keeps local history under `stdpath('state')/pair`; `:PairNew` preserves older conversations.

Agents inspect the project and return scoped proposals. Antigravity can also run commands and tests inside Pair's filesystem sandbox, with optional writable output folders. Codex uses its own read-only sandbox. See [command setup](docs/backends.md#commands-and-generated-output) and [SECURITY.md](SECURITY.md).

Pair supports one active workspace and one pending proposal at a time. Editing the target buffer while a proposal is being generated invalidates it. Commands use saved files on disk; prompts use your visible buffer.

## Help and contributing

Run `:checkhealth pair` for setup problems and `:help pair` for the full guide.

[Report a bug](https://github.com/sampsn/pair.nvim/issues) · [Contribute](CONTRIBUTING.md) · [Test a backend](docs/backend-validation.md) · [Try the preview](docs/preview-trial.md) · [Vision](VISION.md)

MIT licensed.
