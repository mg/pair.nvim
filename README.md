# Pair.nvim

Pair is an early Neovim coding companion for working with an agent while staying hands-on in the buffer. Discuss the codebase in a chat split, ask about a selection, request a replacement for selected code, or put the cursor between functions and ask for an insertion. Pair puts proposed code directly into your unsaved buffer so you can inspect it where it belongs, then accept or reject it.

This repository is a **public-preview candidate**. Codex, Antigravity CLI, one OpenCode account/model route, and Copilot CLI have passed live workflow checks. The Claude Code and legacy Gemini CLI presets still need authenticated live validation. Direct OpenAI, Anthropic, and Gemini API backends have passed mock protocol and loopback HTTP checks, but no authenticated provider requests yet. See the [backend support table](#backend-support) before selecting a route. The product direction is in [VISION.md](VISION.md), the intended editor experience is in [UX.md](UX.md), and the launch requirements are in [ROADMAP.md](ROADMAP.md).

## Start in a few minutes

Install with lazy.nvim:

```lua
{
  "sampsn/pair.nvim",
  config = function() require("pair").setup() end,
}
```

Sign in with `codex login`, open a file in a project, and set Neovim's directory to that project (`:cd /path/to/project`). Press `<leader>pc` to open Pair Chat. Type a message in Insert mode, press `Esc`, then `Enter` to send. Select code in Visual mode and press `<leader>pa` to ask about it or `<leader>pe` to request a change. Put the cursor between functions and press `<leader>pi` to request an insertion. Review a proposed edit in the unsaved buffer, then choose **Accept** or **Reject**. Run `:checkhealth pair` if setup fails; use `:help pair` for every command and mapping.

Pair sends the current buffer from Neovim memory by default, including unsaved edits. Avoid sending a file that contains secrets you do not want the selected provider to process. See [Privacy and local state](#privacy-and-local-state).

## Requirements

- Neovim 0.11 or newer.
- For the default backend, a recent `codex` CLI on `PATH`, signed in with `codex login`. Other CLI backends require their listed executable and account. Direct API backends require `curl` and the matching provider API key.

Pair starts the Codex CLI's app-server by default. Chat and buffer requests share one Codex thread, and answer text streams into the chat pane as it arrives. Pair stores timestamped session records, agent session IDs, and local chat transcripts under Neovim's `stdpath('state')/pair`.

Run `:checkhealth pair` to check setup, the selected executable, and saved session metadata. Run `:help pair` for the in-editor guide. Health checks do not launch agents or read credential values.

## Install from a local checkout

With lazy.nvim:

```lua
{
  dir = "/path/to/pair.nvim",
  config = function()
    require("pair").setup()
  end,
}
```

Or add this directory to `runtimepath` and call `require("pair").setup()` from your config. Use `require("pair").setup({ command = "/path/to/codex", keymaps = false })` to choose a Codex executable or define your own mappings. To use the older nonstreaming CLI path, set `transport = "exec"`.

## Backend support

| Route | Tested access | Live core workflow | Status |
| --- | --- | --- | --- |
| Codex app-server | Existing Codex login | Chat, Ask, Change, Insert, cancel, resume, attempted write | Preview candidate |
| Antigravity CLI | Personal Google account through `agy` | Same core workflow | Preview candidate |
| GitHub Copilot CLI | Existing Copilot account | Same core workflow | Preview candidate |
| OpenCode ACP | OpenRouter key and `openrouter/openai/gpt-4.1-mini` | Same core workflow | Preview candidate for that route |
| Claude Code ACP | No authenticated account here | Mock workflow and adapter startup only | Experimental |
| Legacy Gemini CLI ACP | Personal account rejected before prompt | Mock workflow only | Experimental |
| OpenAI, Anthropic, Gemini direct API | No provider keys here | Mock workflow and loopback HTTP only | Experimental |

“Preview candidate” means the listed route passed on this machine; see [TRANSPORT.md](TRANSPORT.md) for versions, dates, and exact checks. Other login, subscription, BYOK, and model combinations have not been verified. Pair offers the experimental backends in the picker so their users can help validate them; the table does not imply a live pass.

If you can test an experimental account route, follow the [backend validation checklist](docs/backend-validation.md) and report the result without sharing credentials. New Neovim users can follow the [outside-user trial](docs/preview-trial.md).

## Agent backends

Run `:PairBackends` to choose a backend, or use `:PairBackend codex`, `claude`, `copilot`, `gemini`, `antigravity`, `opencode`, `openai_api`, `anthropic_api`, or `gemini_api` directly. The picker starts the selected backend and resumes its session before changing the visible conversation; startup errors leave the current chat in place. The direct command connects on the next message. Pair keeps a separate session and transcript for each backend. Use `:PairModel` to pick a listed model, or `:PairModel model-id` to select an explicit ID. Direct APIs offer a short preset list and accept any valid model ID explicitly; the provider still determines access. The model choice is saved with that conversation. Antigravity does not report a model catalog to Pair; set `models.antigravity` in `setup()` before starting a conversation if needed. The older Codex `exec` transport does not provide a model picker.

- **Claude Code:** Install `@agentclientprotocol/claude-agent-acp` so `claude-agent-acp` is on `PATH`, then sign in with `claude-agent-acp --cli auth login`. Pair requires ACP plan mode and sends a session profile that exposes only Read, Glob, and Grep, disables settings and plugins, and excludes configured MCP servers. Adapter 0.84.0 started with this profile, but its bundled Claude Code reported `loggedIn: false` here, so authenticated prompts and the full Pair workflow remain unverified. See [the M5.3 status](TRANSPORT.md#claude-m53-status-2026-09-29).
- **Copilot CLI:** Install `@github/copilot` and sign in through Copilot CLI, or configure its supported BYOK provider. Pair launches ACP with only `view`, `glob`, and `grep` available; disables built-in MCP servers, custom instructions, experimental features, remote export, and automatic updates; and refuses ACP tool events outside its inspection set. Copilot CLI 1.0.89 passed the full Pair workflow with an existing account on this machine. BYOK remains untested. Use `:PairBackend copilot` to try it locally. See [the M5.4 results](TRANSPORT.md#copilot-m54-baseline-2026-09-30).
- **Antigravity CLI:** Install and sign in with `agy`, then use `:PairBackend antigravity`. Pair starts `agy` in its streaming headless mode with an isolated configuration and a primary agent limited to file inspection. The configuration denies writes, commands, MCP, and web tools. Pair stops the session if Antigravity reports any tool outside its inspection set. Antigravity CLI 1.2.11 passed the live Pair workflow with this machine's personal Google account; other account routes remain unverified. See [the M5.5 results](TRANSPORT.md#antigravity-m55-baseline-2026-09-30).
- **Gemini CLI:** Pair requests plan mode and launches with a bundled policy that permits only local file inspection. It also disables hooks, skills, extensions, and MCP servers. A mock covers the full Pair workflow, but Gemini CLI refused a live session with this machine's personal Google login, so prompting remains unverified. See [TRANSPORT.md](TRANSPORT.md) for the tested versions and access limitation.
- **OpenCode:** Pair launches `opencode acp --pure` in plan mode with only read, glob, grep, and list permissions. OpenCode 1.18.15 passed the full Pair workflow using an OpenRouter API key and `openrouter/openai/gpt-4.1-mini`. The default free model refused ACP prompts, and other account/model routes are unverified. Add an OpenRouter credential with `opencode auth login`, then use `require("pair").setup({ backend = "opencode", models = { opencode = "openrouter/openai/gpt-4.1-mini" } })`. The API key follows OpenRouter billing, separate from an agent subscription. See [OpenCode's provider setup](https://opencode.ai/docs/providers) and the [tested matrix](TRANSPORT.md#opencode-m52-baseline-2026-09-29).

### Direct provider APIs

Set `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY` in Neovim's environment and select `openai_api`, `anthropic_api`, or `gemini_api`. For a credential manager, pass a callback instead: `require("pair").setup({ api_keys = { openai = function() return your_key_lookup() end } })`. Pair reads the key when connecting and requesting; it never writes it to the transcript or session file. `curl` carries the key in a header supplied through stdin, so it does not appear in the process argument list. The request body lives in a mode `0600` temporary file during the request and is removed afterward. These backends use provider API billing, separate from CLI or chat subscriptions.

Direct APIs expose only Pair's bounded `list_files`, `read_file`, `search_text`, `git_status`, and file-scoped `git_diff` tools. They prefer open Neovim buffers, including unsaved changes. They cannot run arbitrary commands or write files. OpenAI uses the Responses API with `store = false`; Anthropic uses Messages; Gemini uses `streamGenerateContent`. Sessions are saved locally under Neovim's Pair state directory. The three routes currently have mock and loopback HTTP coverage; authenticated live provider behavior is unverified. See [TRANSPORT.md](TRANSPORT.md).

For another ACP agent, configure its command and its own read-only tool restrictions, then select it by name:

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

`restricted = true` confirms that you have configured the agent to expose only inspection tools; Pair cannot enforce that declaration inside a third-party process. Pair denies ACP permission requests and never offers the agent Neovim file-write or terminal tools. Do not point this experimental option at an agent with autonomous file-writing tools enabled. The [transport plan](TRANSPORT.md) lists the agents still awaiting dedicated safety checks.

## Use

1. Open a project and set Neovim's working directory to its root (`:cd /path/to/project`).
   Run `:PairActions` or press `<leader>pp` for a compact list of the main actions. Open it from Visual mode to make **Ask selection** and **Change selection** available; the picker keeps the exact selection while you choose. From any Pair pane, press `gP`. Editor actions that need a selection or source cursor explain what is missing when opened from the chat pane.
2. Run `:PairChat` or press `<leader>pc` to toggle the chat split. Its fixed **Pair Chat** header stays visible while the transcript scrolls. The input has three editable lines, with one `❯` beside the first input line. The cursor starts just after the prompt in both Normal and Insert mode. In Insert mode, `Enter` adds a line. Press `Esc` to return to Normal mode, then `Enter` to send. Run `:PairSend` to focus the input, or press `q` in Normal mode to close the chat split. Toggling the chat closed keeps an unsent draft. Press `gN` in Normal mode in any Pair chat pane, use `<leader>pr` from the editor, or run `:PairNew` to clear the chat and start a fresh agent session. Press `gS` in a Pair pane, `<leader>pS` in the editor, or run `:PairSessions` to choose an earlier conversation. Resolve a pending code proposal before switching conversations. `:q` in a Pair window acts on the last source window. When that clean source window quits, Neovim exits; unsaved source changes keep Neovim's normal save-or-discard behavior. The transcript follows new output unless you scroll up to read earlier messages.
   When a source buffer is available, each message attaches its full contents from Neovim memory, including unsaved changes. Chat uses the last focused source buffer. Pair captures it when you send, so a queued message keeps the version visible at submission.
   The one-row header shows the backend, model when the agent reports it, current action, and queued count. It shows **Cancel** while work is running or queued; narrow panes abbreviate it to **X**. Click that control when Neovim mouse support is enabled, focus the header and press `Enter` or `x`, or run `:PairCancel` from any pane. Updates to the header do not move focus from your code or input.
   Cancel clears queued requests and stops showing output from the cancelled turn. Pair waits briefly for the agent to acknowledge cancellation, then stops its connection if it does not respond. Wait for cancellation to finish before sending another message; an attempted chat message keeps its draft. A failed turn clears queued work and shows how to retry or start a new chat. `:PairNew` also stops startup or streaming work and opens a new empty record while preserving the previous transcript and agent session pointer.
   Inspection steps appear as compact rows in the chat transcript. A hollow circle means running, a check means completed, and a cross means failed. Focus the transcript, move to a tool row, and press `Enter` or `za` to expand its command, output, or error; press it again to collapse. `Enter` on another chat line focuses the message input. Output is capped at 4 KiB per entry.
3. Visually select code and run `:PairAsk` for a question or `:PairChange` for a proposed replacement. You can type either command from Visual mode or use its mapping. Ask answers appear in wrapped, shaded lines below the selection. Click their `×` or press `<leader>pd` to dismiss them.
   You can also give an explicit line range, such as `:20,24PairChange simplify this`; numeric Ex ranges select whole lines. Visual selections keep their exact character or line bounds.
4. Place the cursor where code should go and run `:PairHere`. For example, type “add a helper function here for parsing the response.”
5. Inspect the highlighted code already placed in the unsaved buffer. The cursor rests on the real line above the change, with a wrapped explanation and **Accept**, **Reject**, and **Diff** controls between it and the new code. The controls shorten to fit narrow splits. Click a control when Neovim mouse support is enabled. Press `j` from above or `k` from the first proposed line to focus the controls with a real cursor, `h` or `l` to choose Accept or Reject, then `Enter` to apply it. Press `d` from the controls, `<leader>pv`, or run `:PairDiff` to review the original and proposed code side by side with three context lines. Press `q` or `Esc` in the diff to return to the same review position and choice. `k` returns above the controls, while `j` moves into the changed code. You can also run `:PairAccept` or `:PairReject`. Reject restores the original code. One `u` undoes the proposal as its own undo step and clears the controls; redo remains a normal editor action. Saving accepts the current buffer contents automatically, including any edits you made after the proposal appeared; `:q!` discards unsaved changes as usual.

Buffer actions use a small prompt window outside the source file. Press `Enter` or `Ctrl-S` to submit; press `Esc` then `q` to cancel. Commands also accept text directly, such as `:PairHere add a helper function here`.

The chat input and small Ask, Change, and Insert prompts leave the input line clear. In Normal mode inside either kind of input, press `gC` to preview the current attachment, or `gA` to detach or reattach the full buffer for that message. A selected range remains attached when you detach the full buffer. The default attachment resets for the next message. Pair recaptures the buffer when you submit, so the preview can change if you edit the source afterward.

The default full-buffer limit is 128 KiB. For a larger buffer, Pair pauses submission and offers selected lines or nearby lines when they fit, sending without the full buffer, or cancellation. Cancellation keeps the draft. A selected range that alone exceeds the limit must be narrowed in the editor. Set `context_max_bytes` and `context_nearby_lines` in `setup()` to change the limit and nearby radius.

Completion menus are disabled inside Pair's chat input and request windows.

| Command | Default mapping | Action |
| --- | --- | --- |
| `:PairChat` | `<leader>pc` | Toggle chat open or closed |
| `:PairActions` | `<leader>pp` in Normal or Visual mode, or `gP` in Pair chat | Choose Chat, Ask, Change, Insert, New chat, Resume chat, or Switch backend |
| `:PairSend` | `<leader>ps` | Focus the chat input, or send command arguments directly |
| `:PairAsk` | `<leader>pa` in visual mode | Ask about selection |
| `:PairChange` | `<leader>pe` in visual mode | Propose replacement |
| `:PairHere` | `<leader>pi` | Propose insertion at cursor |
| `:PairAccept` | `<leader>py` | Keep the pending buffer edit and clear its controls |
| `:PairReject` | `<leader>pn` | Restore the original code |
| `:PairDiff` | `<leader>pv`, or `d` from proposal controls | Open or close the pending proposal diff |
| `:PairDismiss` | `<leader>pd` | Hide an inline answer |
| `:PairCancel` | — | Cancel the active request and clear the queue |
| `:PairNew` | `<leader>pr`, or `gN` in Pair chat | Stop the current response and create a new session record |
| `:PairSessions` | `<leader>pS`, or `gS` in Pair chat | Choose and resume a conversation for this workspace and backend |
| `:PairBackends` | `<leader>pB`, or `gB` in Pair chat | Choose an installed backend and verify its session |
| `:PairModel [model-id]` | `<leader>pM`, or `gM` in Pair chat | Choose an agent-reported model for this conversation |
| `:PairBackend [name]` | — | Show or directly switch the selected backend |

Pair keeps one active record per working directory and backend. Changing `:cd` or `:PairBackend` loads that scope's active record; switching while a request or proposal is pending waits until it is resolved. Each scope has a `.sessions.json` index and a `.records/` directory under `stdpath('state')/pair`. The index contains timestamps and record IDs, while each record has a transcript, an agent session pointer, and an optional model choice. Existing single-file transcripts and pointers migrate on first use. `:PairNew` keeps earlier records on disk. `:PairSessions` lists newest first and marks the active one. Pair restores the saved agent session before switching to an earlier transcript; if restoration fails or there is no pointer for a conversation with messages, the current chat remains active. A previously active transcript can appear on startup before its agent reconnects; the header shows **Reconnect** until a message or selecting that record in the picker verifies the connection. An unsent draft also blocks switching. ACP agents must support `session/load`. The optional Codex `exec` transport cannot verify restoration before the next turn, so use the default app-server transport to reopen its older chats. Pair does not write backend credentials into the index or records, and it redacts recognizable API keys and bearer tokens from persisted transcript text. Avoid entering other secrets in chat because arbitrary secret formats cannot be identified reliably.

Direct API conversations have a local 2 MiB / 400-message ceiling. Pair warns when history reaches three quarters of that budget and asks you to run `:PairNew` before a turn would exceed it. A provider may reach its own context limit sooner; Pair reports that as a restart action. `:PairNew` preserves the old local transcript for `:PairSessions`. CLI backends manage their own context; if one can no longer resume, start a new Pair conversation.

## Privacy and local state

Every turn includes the attached source buffer and instruction. The selected CLI or API provider receives this content, and its own file tools may inspect repository or machine files according to that backend's permissions. Codex read-only mode can read outside the workspace; Pair does not restrict readable roots at the operating-system level. Direct API tools are limited to bounded inspection of workspace files and loaded buffers, but `git_status` may reveal tracked hidden filenames. Review the attached context with `gC` and remove the full buffer with `gA` in a Pair input before sending when appropriate.

Pair stores chat transcripts, session pointers, model choices, and direct API conversation history under `:echo stdpath('state') . '/pair'`. New files are created with owner-only permissions, but older files may retain their original permissions. `:PairNew` starts a fresh record and keeps earlier ones; delete that directory yourself to remove Pair's local history. CLI agents may keep their own session and telemetry state elsewhere; consult each tool's settings. Pair masks familiar API-key formats in saved chat text, but cannot reliably recognize arbitrary secrets. Direct API credentials come from the environment or a callback and are not saved by Pair. See [SECURITY.md](SECURITY.md) for the precise boundary and reporting guidance.

## Editing boundary

Pair does not expose a file-writing action to the agent. Each Codex turn requests a read-only shell sandbox with approval disabled. Pair disables Codex plugins, apps, hooks, browser/computer tools, multi-agent tools, and configured MCP servers because they can operate outside the shell sandbox. The agent is instructed to use only read-only inspection commands. Pair places a completed proposal into a Neovim buffer; saving that buffer remains your normal editor action.

The app-server uses the same local Codex login as the CLI. Pair uses app-server directly for Codex; [TRANSPORT.md](TRANSPORT.md) explains the CLI and direct API plan. Subscription eligibility and billing are determined by each provider. Direct API use draws on the provider's API account or quota, separately from a chat or agent subscription.

## Current limits

- One active workspace per Neovim instance and one pending proposal at a time.
- Pair sends the full live source buffer by default with chat and editor actions. Live probes with Codex, Antigravity, Copilot, and a tested OpenCode route confirmed that an agent file tool may read the older saved file while Pair's attached snapshot contains unsaved text; the agent answered from the snapshot. See [TRANSPORT.md](TRANSPORT.md).
- A change anywhere in the target buffer while an edit is being prepared invalidates the proposal. After the proposal appears, Reject refuses to overwrite subsequent user edits; Accept or save keeps the buffer as edited.
- Ask answers stream into both chat and wrapped lines beside the selected code. Edit requests show progress in chat and beside the code, then apply the completed proposal. Partial code is not written while the agent is still generating JSON.
- The prompt window sends on `Enter` and is best suited to short instructions.
- App-server chat streams text during a turn. The optional `exec` transport receives final agent messages when Codex finishes them. Inspection details depend on what each agent reports; some tools provide only a name and completion state.
- Proposed replacements use a JSON response contract. Pair reports a malformed response in chat instead of applying it.
- Pair does not automatically run tests, builds, generators, or formatters through the agent.
- The read-only boundary relies on Codex CLI honoring its sandbox and tool settings; Pair does not add an independent OS sandbox.

## Checks

Run the non-live suite and clean-install smoke checks with:

```sh
bash tests/run_all.sh
bash tests/install_smoke.sh
```

The opt-in `tests/live_codex_baseline.lua` check uses the configured Codex account and a temporary workspace. See [TRANSPORT.md](TRANSPORT.md) for its command, coverage, and limits.
The opt-in `tests/live_opencode_baseline.lua` check uses a configured OpenCode provider account and a temporary workspace. Set `PAIR_LIVE_MODEL` to test a different authenticated OpenCode model.
`tests/claude_mock_flow.lua` exercises the built-in Claude preset through Pair with a local ACP mock; it needs no Claude login. The opt-in `tests/live_claude_session.lua` check tests the installed adapter without a prompt. After Claude authentication, `tests/live_claude_baseline.lua` checks the full Pair workflow in a temporary workspace.
`tests/copilot_mock_flow.lua` checks the Copilot preset and ACP tool guard without an account. The opt-in `tests/live_copilot_session.lua` checks startup without a prompt; `tests/live_copilot_baseline.lua` exercises the full Pair workflow with an authenticated Copilot CLI in a temporary workspace.
`tests/gemini_mock_flow.lua` checks the Gemini preset, restrictions, scoped actions, session resume, and unexpected tool handling without an account. The opt-in `tests/live_unsaved.lua` checks a live Gemini session when the installed CLI has an eligible account or API key.
`tests/live_gemini_baseline.lua` is the opt-in full workflow check for that eligible Gemini CLI route.
`tests/antigravity.lua` checks the Antigravity headless adapter and isolated restrictions without an account. `tests/direct_core.lua` checks the direct API research and conversation core, including unsaved buffers, path boundaries, output limits, and git inspection. `tests/direct_api.lua` checks all three provider tool loops, streaming, cancellation, and session restore. Run `python3 tests/run_direct_http.py` for loopback HTTP and editor workflow checks across all three providers. The opt-in `tests/live_antigravity_baseline.lua` checks the full Antigravity workflow using the local `agy` login.

The direct API research core is in `lua/pair/research.lua`. It exposes bounded `list_files`, `read_file`, `search_text`, `git_status`, and file-scoped `git_diff` calls. Open Neovim buffers take priority over disk for reading and searching; file listing, reads, searches, and scoped diffs exclude hidden paths and symlinks. Binary files and oversized content are excluded. Git status can include names of tracked hidden files. `lua/pair/direct_session.lua` stores provider-neutral messages and tool results, while `lua/pair/direct_providers.lua` translates the three provider protocols.
