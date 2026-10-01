# Agent transport decisions

## Current preview candidate

### Antigravity command permissions (2026-10-01)

Antigravity CLI 1.2.14 now runs inside Pair's filesystem sandbox: macOS Seatbelt or Linux bubblewrap. The project is read-only except explicitly configured `commands.writable_paths`; private agent state and temporary storage remain writable. Direct file-edit tools stay disabled. Codex can run checks within its native read-only sandbox; ACP presets and direct APIs still have inspection-only tools.

A live command check on macOS with agy 1.2.14 ran a Python fixture, received its streamed result, wrote approved generated output and temporary files, and verified that a source overwrite was denied. The full live Antigravity workflow also passed with the corrected home setup. Local process checks exercise child inheritance, PTY creation, symlink escapes, hardlink grant rejection, Git protection, and default-denied output writes. Linux command protection is covered by the CI fixture, not an authenticated Antigravity run.

The check uncovered that agy 1.2.14 ignores `GEMINI_HOME`: the previous profile and settings were not being loaded. Pair now supplies a private process home containing `.gemini/antigravity-cli/settings.json`, `.gemini/config/config.json` with shared permission grants, the custom agent, and a symlink to the existing CLI login. It does not rewrite the user's CLI settings. Antigravity histories created before this correction may require `:PairNew`, since those agent conversations were stored in the user's normal CLI home. Pair keeps its prior transcripts.

Pair currently starts `codex app-server --stdio`. It uses the user's existing Codex CLI login, keeps one thread across chat and buffer actions, and streams answer deltas. Pair requests a read-only sandbox for each turn and receives tool events through the same connection. See the [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server).

The earlier `codex exec --json` transport remains available with `require("pair").setup({ transport = "exec" })`. Its JSONL events on the Codex version used during development contained completed agent messages but no text deltas, so it cannot give Pair the same live typing experience.

## Public preview target

Codex CLI, Claude Code, Antigravity CLI, GitHub Copilot CLI, and OpenCode are the named launch targets, with configurable ACP integration for more agents that meet Pair's safety contract. GitHub Copilot CLI's [ACP server supports a tool allowlist](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server). Pair uses one backend contract for starting or resuming a session, prompting, streaming answer and tool events, cancelling, stopping, and surfacing errors. Chat and buffer actions use the same selected backend session. Each backend's session history is separate; changing backends does not move the conversation context.

[CodeCompanion's adapter catalog](https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/config.lua) shows the breadth available through ACP and direct HTTP. Its [documentation](https://github.com/olimorris/codecompanion.nvim/blob/main/doc/codecompanion.txt) says ACP adapters currently serve its chat interaction while inline uses HTTP adapters. Pair will reuse the protocol approach, not their adapter code, because Pair's chat and buffer turns must share one backend session. The reusable ACP client is now in place with mock protocol tests; Antigravity, Copilot, and one OpenCode route have passed live Pair workflows while Claude, legacy Gemini CLI, and broader provider routes remain experimental.

| Backend | Connection | Launch access path | Current state |
| --- | --- | --- | --- |
| Codex CLI | App-server | CLI login or CLI API key | Live baseline passed with Codex CLI 0.159.2 on 2026-09-30; see matrix below |
| Claude Code | ACP adapter | Claude Code account or supported API key | Adapter 0.84.0 starts in restricted plan mode; bundled Claude Code 2.1.284 reports no login, so live prompts remain blocked |
| Antigravity CLI | Headless stream-json | Existing `agy` personal Google login | Live baseline passed with Antigravity CLI 1.2.14 on 2026-09-30; see matrix below |
| Gemini CLI | Native ACP mode | Eligible enterprise/Google Cloud account or paid Gemini API key | Restricted preset and mock workflow pass; CLI 0.42.0 and 0.62.0 refused ACP session creation with this personal Google login |
| GitHub Copilot CLI | Native ACP mode | Existing Copilot account; CLI BYOK untested | M5.4 passed with Copilot CLI 1.0.89 on 2026-09-30; see matrix below |
| OpenCode | Native ACP mode | OpenRouter API key via OpenCode login | M5.2 passed with OpenCode 1.18.15 and `openrouter/openai/gpt-4.1-mini` on 2026-09-29; other routes unverified |
| OpenAI API | Direct HTTP Responses API | OpenAI API key | Mock tool loop and loopback HTTP streaming pass; authenticated live route unverified |
| Anthropic API | Direct HTTP Messages API | Anthropic API key | Mock tool loop and loopback HTTP streaming pass; authenticated live route unverified |
| Gemini API | Direct HTTP `streamGenerateContent` | Gemini API key | Mock tool loop and loopback HTTP streaming pass; authenticated live route unverified |

### Release-candidate rerun (2026-09-30)

On macOS, Neovim 0.12.5, the opt-in full Pair workflow passed again with Codex CLI 0.159.2, Antigravity CLI 1.2.14, Copilot CLI 1.0.89, and OpenCode 1.18.15 using the OpenRouter model above. Each script exercised chat, Ask, Change, Insert, cancellation, restoring a conversation, an unsaved-buffer snapshot, and an attempted repository write in a temporary workspace. The attempts left disk unchanged. Antigravity reported a `write_to_file` event, which Pair stopped. The other tools did not prove an independent sandbox; their reported permissions and observed disk result are the evidence.

The OpenCode rerun first exposed intermittent loss of `read` and `glob` in `opencode debug agent plan --pure`. OpenCode applies permission JSON rules in order, while Lua's table encoder emitted the catch-all deny in varying positions. Pair now sends that deny first in a fixed string, followed by the inspection allows. Five successive debug checks then reported `read`, `glob`, and `grep` enabled and write/shell tools disabled; the full live workflow passed after the fix. `tests/acp.lua` checks the order so it cannot silently regress.

The full non-live suite passed on macOS with Neovim 0.11.7 and 0.12.5. Clean native-package and lazy.nvim installs passed in isolated temporary Neovim state on both versions and from a fresh GitHub clone. The GitHub CI matrix passed on macOS and Linux with Neovim 0.11.7 and stable on commit `d9ee104`. Neovim 0.10.4 failed the chat bottom-alignment check in headless testing, so the preview minimum is 0.11. No `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY` was available here, so direct provider live validation remains open. Claude authenticated prompts remain open because its adapter previously reported `loggedIn: false`; the user chose to continue with mock checks for that route.

### Long direct API sessions and recovery (M5.10)

Direct API history has a local ceiling of 2 MiB or 400 messages. Pair warns at three quarters of the budget and refuses a turn before the next request would exceed the local allowance. `:PairNew` creates an empty conversation while keeping the previous local transcript available in `:PairSessions`. Provider HTTP errors are classified into authentication/model access, quota/rate limit, context exhaustion, and service errors without printing response bodies that could contain private data. A provider context error and a CLI session that cannot continue both suggest starting a new conversation. Mock tests cover the preflight limit and loopback HTTP error classes. Provider-specific context limits vary and may occur before Pair's local ceiling; automatic compaction is not part of this preview.

### Live unsaved-buffer check (2026-09-28)

The opt-in probe in `tests/live_unsaved.lua` creates a temporary workspace, saves one marker to disk, changes that line only in a Neovim buffer, and sends Pair's serialized editor snapshot through the selected backend. It explicitly asks the agent to inspect the saved file with an allowed read tool and report both values. `tests/live_pair_unsaved.lua` checks the full Pair chat and selection Ask flow with Codex. Both probes check that the buffer and disk remain unchanged.

| Backend on this machine | Result | What this establishes |
| --- | --- | --- |
| Codex CLI 0.156.1 | Passed. Its `cat -- pair_probe.txt` tool call read the saved disk marker; its answer reported the different unsaved editor marker and chose the editor snapshot as authoritative. The full Pair chat and selection Ask each answered with the unsaved marker. | Pair sends live text successfully. Codex's own file tools still read disk, so the attached snapshot must remain authoritative when the two differ. No automatic save occurred. |
| Gemini CLI 0.42.0 and 0.62.0 | `session/new` failed: “This client is no longer supported for Gemini Code Assist for individuals.” | No prompt or file-read behavior could be tested with this personal Google account. See the legacy Gemini CLI status below. |
| OpenCode 1.18.15 default free model | ACP session opened, then the prompt failed: “OpenCode's free tier can only be used from within OpenCode.” | This default route cannot serve Pair's ACP requests. A later authenticated OpenRouter route passed; see M5.2 below. |
| Claude Code ACP adapter 0.84.0 | On 2026-09-29, plan-mode session creation passed with Pair's restricted profile; the first prompt returned “Authentication required.” | The bundled Claude Code 2.1.284 reports `loggedIn: false`; no authenticated reply or file inspection was tested. See M5.3 below. |
| GitHub Copilot CLI | At the time of this 2026-09-28 probe, `copilot` was not installed. | See the later M5.4 baseline for authenticated results. |

To repeat the probes after configuring an account or installing an adapter:

```sh
PAIR_LIVE_BACKEND=codex nvim --headless -u NONE -c 'luafile tests/live_unsaved.lua' -c 'qa!'
PAIR_LIVE_BACKEND=gemini nvim --headless -u NONE -c 'luafile tests/live_unsaved.lua' -c 'qa!'
PAIR_LIVE_BACKEND=antigravity nvim --headless -u NONE -c 'luafile tests/live_unsaved.lua' -c 'qa!'
PAIR_LIVE_BACKEND=opencode PAIR_LIVE_MODEL=openrouter/openai/gpt-4.1-mini nvim --headless -u NONE -c 'luafile tests/live_unsaved.lua' -c 'qa!'
PAIR_LIVE_BACKEND=claude nvim --headless -u NONE -c 'luafile tests/live_unsaved.lua' -c 'qa!'
PAIR_LIVE_BACKEND=copilot nvim --headless -u NONE -c 'luafile tests/live_unsaved.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_pair_unsaved.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_codex_baseline.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_opencode_baseline.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_claude_session.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_claude_baseline.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_copilot_session.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_copilot_baseline.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_gemini_baseline.lua' -c 'qa!'
nvim --headless -u NONE -c 'luafile tests/live_antigravity_baseline.lua' -c 'qa!'
```

The live probes contact the selected agent and may use its account quota. They create and delete a temporary workspace and do not send repository contents.

### Codex M5.1 baseline (2026-09-29)

Codex CLI 0.156.1 passed the following checks in a disposable Lua workspace. `tests/codex_baseline.lua` exercises the full Pair path against a mock app-server; `tests/live_pair_unsaved.lua` and `tests/live_codex_baseline.lua` use the installed CLI and account.

| Behavior | Result |
| --- | --- |
| Chat and Ask | Both live replies used an unsaved editor marker instead of the older disk marker. The disk file and editor text stayed unchanged. |
| Change and Insert | Live Change produced a scoped proposal that Reject restored; live Insert produced a scoped proposal that Accept kept in the buffer without saving the disk file. |
| Streaming | Mock output appeared before turn completion. The live long chat produced agent text before Pair cancelled it. |
| Cancel and resume | The mock confirmed `turn/interrupt`; live cancellation finished, and Pair resumed the prior Codex thread after `:PairNew` and answered a follow-up. |
| Read-only boundary | The mock checked read-only sandbox and never-approve parameters on start, resume, and each turn, disabled configured MCP servers and unsafe CLI features, blocked a changed MCP configuration, and stopped on a reported direct file change. A live request to create a marker file finished without creating it. The live result alone does not establish whether Codex attempted the command or declined it; Pair relies on Codex's sandbox rather than an independent OS sandbox. |

The live baseline also exposed an app-server event with a JSON `null` item during cancellation. Pair now ignores that item and handles a null turn error, with a mock regression case for both.

### OpenCode M5.2 baseline (2026-09-29)

The verified route is OpenCode CLI 1.18.15 with an OpenRouter API key stored by `opencode auth login`, using `openrouter/openai/gpt-4.1-mini`. OpenCode's [provider guide](https://opencode.ai/docs/providers) describes this credential path. The default OpenCode free model was rejected for ACP use, and an authenticated `openrouter/google/gemini-2.5-flash` probe returned tool-call-looking text without making a file-read call. Those model routes are not validated. Other OpenCode versions, providers, and subscription paths remain untested.

| Behavior | Result |
| --- | --- |
| Chat and Ask | Live Pair replies quoted the unsaved editor line. A separate raw ACP probe used the allowed read tool to see the older saved disk line and correctly treated the editor snapshot as authoritative. |
| Change and Insert | Live scoped Change was rejected and restored the unsaved line. Live Insert was accepted in Neovim without saving the disk file. |
| Streaming and cancel | The live long reply produced new text before completion; Pair then cancelled it and recorded cancellation. |
| Resume | After `:PairNew`, Pair loaded the prior OpenCode session and received a follow-up answer. |
| Read-only boundary | With Pair's launch environment, `opencode debug agent plan --pure` reported read, glob, and grep enabled; edit, write, bash, task, and webfetch disabled. A live request to create a marker file left no file. The request sometimes produced no write-tool event, so this proves the observed outcome and the configured tool set, not an OS-level sandbox. Pair also denies ACP permission requests. |

The opt-in `tests/live_opencode_baseline.lua` runs that workflow in a temporary workspace. It defaults to the validated model; set `PAIR_LIVE_MODEL` to check another authenticated model. It uses the configured provider's quota or API billing. Pair does not manage or store the provider key.

### Claude M5.3 status (2026-09-29)

The installed `claude-agent-acp` 0.84.0 bundles Claude Code 2.1.284. Pair's ACP session creation reached plan mode with a per-session profile that exposes only Read, Glob, and Grep; sets `settingSources`, `plugins`, and MCP servers to empty; enables strict MCP configuration; disallows write, shell, subagent, skill, and web tools; and removes bypass-permissions mode. Pair also stops the session if it reports a tool outside that inspection set. Mock checks confirm the profile is sent on both `session/new` and `session/load`, and that an unexpected Write tool event stops the session. A Pair-level mock test now covers Chat streaming, scoped Ask, Change rejection, Insert acceptance, cancellation, resume, and a blocked Write event with an unsaved source buffer. [The adapter's permission extension](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/docs/permission-extension.md) describes the bypass control; the installed adapter accepts the other listed session options.

An unprompted adapter session could not be loaded after restarting the process. Pair now saves an ACP session pointer after its first completed prompt, avoiding a stale pointer for an empty session. The live no-prompt reconnect check passes. Authenticated resume and the full Chat, Ask, Change, Insert, streaming, cancel, and write-attempt matrix still require a Claude login: `claude-agent-acp --cli auth status` reported `loggedIn: false`, and the first live prompt returned “Authentication required.” Run `claude-agent-acp --cli auth login` and then `tests/live_claude_baseline.lua` to finish this gate. M5.3 remains open.

### Copilot M5.4 baseline (2026-09-30)

Copilot CLI 1.0.89 passed using the existing Copilot account on this machine and its default model. The [ACP server documentation](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server) says `--available-tools` is set at server startup and applies to both new and loaded sessions. Pair launches with only `view`, `glob`, and `grep`; disables built-in MCP servers, custom instructions, experimental features, remote export, and auto-updates; and sends no MCP servers or client filesystem/terminal capabilities. Copilot's ACP read-tool event omitted `name` but reported `kind = "read"`. Pair now accepts an unnamed read event for this preset while continuing to stop on named tools outside the allowlist or unnamed non-read events. The CLI allowlist is the tool boundary; Pair's event check catches reported drift, not an independent OS sandbox.

| Behavior | Result |
| --- | --- |
| Chat and Ask | Both live replies used the unsaved editor line. A separate live probe called Copilot's `view` tool to read the older disk line and identified the editor snapshot as authoritative. |
| Change and Insert | Live Change produced a scoped proposal that Reject restored; live Insert produced a scoped proposal that Accept kept in the Neovim buffer without saving the disk file. |
| Streaming and cancel | A live response produced text before completion; Pair then cancelled and recorded the cancellation. |
| Resume | Pair loaded the prior Copilot session after `:PairNew` and received a follow-up answer. |
| Read-only boundary | A live request to create a marker file left no file; no write-tool event was reported. The mock verified launch flags, accepted an unnamed read event, and stopped on an unnamed edit event. This tests the observed behavior and configuration, not an OS-level write restriction. |

`tests/copilot_mock_flow.lua` runs without a Copilot account. The opt-in `tests/live_copilot_session.lua` and `tests/live_copilot_baseline.lua` use an authenticated CLI and a disposable workspace. An existing account route passed; [Copilot ACP also supports configured BYOK providers](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server), but that route remains untested here. Copilot CLI 1.0.89 is installed on the local `PATH`, so `:PairBackend copilot` can be tried in Neovim.

### Antigravity M5.5 baseline (2026-09-30)

The installed `agy` 1.2.11 CLI passed Pair's live workflow with the existing personal Google login. Pair uses Antigravity's [headless stream-json interface](https://antigravity.google/docs/cli/headless/) so chat and editor actions share a process and conversation ID. The initial integration attempted to load an inspection agent and restrictive settings through `GEMINI_HOME`, and stopped on unsupported tool events. Subsequent command validation with 1.2.14 found that the CLI ignored that environment variable; the corrected home setup and independent filesystem sandbox are described above. The results below record the earlier workflow checks, not proof that its intended CLI profile was enforced. The official [Antigravity ACP server](https://zed.dev/acp/agent/antigravity-acp) initialized here but hung on session creation with the personal account, so Pair uses the working CLI path.

| Behavior | Result |
| --- | --- |
| Chat and Ask | Both live actions used the unsaved editor line. A separate read-tool probe saw the saved disk line and correctly treated the live editor snapshot as authoritative. |
| Change and Insert | Live Change produced a scoped proposal that Reject restored; live Insert produced a scoped proposal that Accept kept in Neovim without saving the disk file. |
| Streaming and cancel | Text arrived before turn completion, and cancellation stopped a long response. |
| Resume | Pair restored an earlier Antigravity conversation after `:PairNew` and received a follow-up answer. |
| Read-only boundary | A live write request reported `write_to_file`; Pair stopped the turn. The requested marker file was absent, and disk content was unchanged. A mock checks the isolated deny rules and blocked tool events. |

The opt-in `tests/live_antigravity_baseline.lua` and `tests/live_unsaved.lua` exercise the live route in temporary workspaces. `tests/antigravity.lua` checks its launch configuration, streaming event translation, resume, and unexpected tool handling without an account. Only the existing personal OAuth route was tested; API-key and enterprise paths remain unverified.

### Legacy Gemini CLI status (2026-09-30)

Pair now starts Gemini ACP in plan mode with a bundled [admin-tier policy](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/policy-engine.md) that denies all tools except `read_file`, `list_directory`, `glob`, and `grep_search`. It supplies system settings that disable hooks, skills, extensions, MCP, and permission bypass, and refuses to start if standard system settings or policy files could supersede those restrictions. Pair sends no MCP servers or client filesystem/terminal capabilities and stops on a reported tool outside the inspection set. This policy does not add an independent OS sandbox.

`tests/gemini_mock_flow.lua` checks chat, scoped Ask, Change rejection, Insert acceptance, session restoration, unsaved buffer context, policy launch arguments, and an unexpected Write event. It needs no Gemini account. The installed 0.42.0 CLI and a temporary 0.62.0 install both reached ACP `session/new` but returned the same account rejection before any prompt or tool call. [Google's transition announcement](https://github.com/google-gemini/gemini-cli/discussions/27274) says Gemini CLI stopped serving free, Google AI Pro, and Ultra users on June 18, 2026; eligible enterprise/Google Cloud and paid API-key routes remain. The global CLI remains at 0.42.0; 0.62.0 was tested from a temporary install. `tests/live_gemini_baseline.lua` is ready to check streaming, cancellation, resume, all four Pair actions, unsaved context, and an attempted write with an eligible route. A separate `tests/live_unsaved.lua` run requests a file-read tool. Both still need to pass before Pair advertises the legacy Gemini CLI preset.

Keep the working Codex app-server backend. Use [ACP](https://agentclientprotocol.com/) for other agents whose official CLI or adapter supports Pair's tool boundary. The legacy Gemini CLI preset remains for eligible enterprise or paid-key routes, but Antigravity is the tested personal-account route. For each adapter, verify permissions, project and tool write attempts, configured extensions, streaming, session resume, cancellation, and bounded proposal parsing.

Direct OpenAI, Anthropic, and Gemini API backends now use `pair.research` for bounded file listing, reading, literal search, and git status/file-scoped diff inspection, plus `pair.direct_session` for persisted messages and tool calls. File reads and searches prefer loaded Neovim buffers, including unsaved named files. Listing, reads, searches, and scoped diffs reject or omit hidden paths, symlinks, traversal, binary files, and oversized inputs; git status can still report names of tracked hidden files. No arbitrary shell or file-write tool is exposed. The model returns the same bounded proposal format as a CLI backend, and Neovim applies it. `tests/direct_api.lua` checks streaming translation, research tool round trips, cancellation, and restoration for each provider. `tests/run_direct_http.py` checks all three over actual loopback HTTP streams, including credential headers and Pair's Chat, Ask, Change, and Insert flow. `tests/direct_core.lua` covers the unsaved-buffer and path boundary. No provider API keys were available in the test environment, so authenticated live and attempted-write checks remain open.

## Accounts, subscriptions, and API keys

The launch target is account/subscription sign-in through supported CLIs, API-key access through their documented authentication, and direct provider API-key access without an installed agent CLI. Pair launches a CLI with the user's existing login or environment. Direct API backends read a key from an environment variable or callback when needed. Pair does not print, log, or persist a raw key. An API key is billed under the provider's API terms; it does not automatically draw from a CLI or chat subscription.

[Codex supports ChatGPT login and API-key login](https://learn.chatgpt.com/docs/developer-commands). [Gemini CLI's current access announcement](https://github.com/google-gemini/gemini-cli/discussions/27274) limits its continuing routes to eligible enterprise/Google Cloud access and paid Gemini API keys; personal free, Pro, and Ultra accounts moved to Antigravity CLI. [Copilot CLI supports GitHub sign-in and bring-your-own-key configuration](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server). Claude's subscription use in third-party clients needs special care: [Anthropic's June 2026 notice](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) says use through Claude Agent SDK and third-party apps continues to count against subscription limits for now, while its [login policy](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account) reserves the right to change how that use is billed. The launch docs must state tested combinations and current policy rather than promise that any subscription always covers Pair usage.
