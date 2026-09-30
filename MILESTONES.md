# Pair.nvim public-preview milestones

These milestones are ordered. Each numbered slice should be small enough for one reviewable pull request with a user-visible result. The public preview is ready when every launch gate below passes, not when a preset merely starts in a mock test. [ROADMAP.md](ROADMAP.md) holds the broader safety and release checks.

## Product contract for the preview

- **The live buffer is the default context.** At submission, Pair captures the *entire current source buffer from Neovim memory*, including unsaved edits. Chat uses the last focused source buffer while its input has focus. Ask, Change, and Insert use their target buffer and also mark the exact selection or insertion point. The snapshot is fixed for that turn; the next turn captures the latest buffer again.
- Pair shows the attached file, whether it has unsaved changes, and what additional context is included. Users can inspect or remove context before sending. If a buffer exceeds the supported size, Pair explains this and offers a narrower scope; it must never silently substitute the version on disk or truncate the snapshot.
- The live snapshot is sent with the prompt to every backend. Direct API file-reading tools should also prefer loaded Neovim buffers over disk. CLI agents have their own file tools and may separately read an older saved version; Pair must test and disclose that limit, and tell the agent which snapshot is authoritative. Pair never saves a buffer just to provide context.
- Diagnostics, git diff, another buffer, and other sources are explicit optional additions. Pair does not silently attach the whole project. The agent never writes project files; Neovim owns accepted edits.

## M1 — Live editor context

**Outcome:** The code the user sees is what Pair sends by default.

- [x] **1.1 Source tracking.** Remember the last focused source buffer when the user enters Pair chat. Handle unnamed, closed, and switched buffers without accidentally treating a Pair pane as source.
- [x] **1.2 Snapshot contract.** Capture contents, path or unnamed label, filetype, modified flag, changedtick, and optional selected range at submission time. Use one representation for chat, Ask, Change, and Insert.
- [x] **1.3 Shared prompt path.** Attach the full live snapshot by default on every turn, clearly delimit it from the user's instruction, and identify it as newer than the disk version when modified. Re-capture on the next turn. Keep selected scope unambiguous.
- [x] **1.4 Visible context.** Show a compact attached-buffer indicator by the chat input and request windows, with a way to inspect and remove the attachment. For oversized buffers, pause submission with a clear choice to narrow scope; do not silently fall back to disk.
- [x] **1.5 CLI read behavior.** Test Codex and each available ACP backend against an unsaved edit. Document any case where an agent's own file inspection still uses disk content, even though Pair sent the live snapshot. Direct API tool parity is covered in M5.6. Codex passed; installed Gemini and OpenCode could not reach a usable prompt with their current account/model settings. See [TRANSPORT.md](TRANSPORT.md).

**Gate:** Edit a line without saving, ask in chat and with a selection about that line, and confirm the exact live text is sent and used. No automatic save occurs. Repeating the request after another edit sends the newer version.

## M2 — Clear turn and tool activity

**Outcome:** A user can tell what Pair is doing without losing the conversation in logs.

- [x] **2.1 Turn state.** Show selected backend, model when known, running action, cancel control, and queued-request count in a small stable place. Keep editor focus unchanged while updates arrive.
- [x] **2.2 Tool entries.** Show one compact row per inspection step with running, success, or failure state. Open it to view the command or tool name and bounded output/error. Preserve manual chat scrolling during streaming.
- [x] **2.3 Cancellation and recovery.** Make cancel and new-chat behavior consistent during startup, streaming, and queued work. A failed or cancelled turn must leave the buffer unchanged and give a useful next action.

**Gate:** During a long response and a tool call, a tester can identify the current action, inspect what ran, scroll up without being pulled down, and cancel without a late response changing the chat or buffer.

## M3 — Proposal review and editor reliability

**Outcome:** The scoped edit is easy to inspect and safe to keep or reject.

- [x] **3.1 Full diff on demand.** From a pending proposal, open a focused diff with its original text, proposed text, and enough surrounding context. Return to the inline controls without losing the decision.
- [x] **3.2 Review edge cases.** Check insertion, replacement, deletion, wrapped lines, nearby user edits, stale targets, closed buffers, undo, save-to-accept, and reject. Never overwrite later user edits during rejection.
- [x] **3.3 Real input paths.** Exercise Visual-mode ranges, mappings, small prompt windows, empty/cancelled prompts, and chat-to-buffer follow-ups interactively. Fix any case where the preview does not match the requested scope.

**Gate:** A new tester can locate every changed line, see why it changed, and accept or reject it without surprising buffer changes.

## M4 — Sessions, discovery, and diagnostics

**Outcome:** The plugin remains understandable after more than one task or backend.

- [x] **4.1 Durable session records.** Keep separate conversations per workspace and backend, with a title or timestamp. `:PairNew` creates a new record instead of destroying the only pointer to the previous one; do not retain raw API keys.
- [x] **4.2 Session picker.** List and resume previous conversations when the backend supports it. Reconcile the visible transcript with the actual agent session; explain when a backend cannot restore one.
- [x] **4.3 Backend and model picker.** Show the active backend/model and available alternatives, with clear missing-login, missing-executable, and unsupported-model errors. Switching sessions never implies their contexts are shared.
- [x] **4.4 Small action picker.** Offer Chat, Ask selection, Change selection, Insert here, New chat, Resume chat, and Switch backend through a Neovim-native picker; keep existing commands and mappings first-class.
- [x] **4.5 Health and help.** Add `:checkhealth pair` and `:help pair` covering setup, context, sessions, proposals, and backend troubleshooting without exposing credentials.

**Gate:** A fresh user can find the core actions, identify the selected backend, start a second chat, return to the first when supported, and diagnose a failed startup without private help.

## M5 — Launch backend parity

**Outcome:** Every advertised CLI and direct API route completes the same chat → scoped request → review loop.

- [x] **5.1 Codex baseline.** Preserve working app-server streaming, resume, cancellation, and read-only behavior while exercising the new context path. Mock and opt-in live results are recorded in [TRANSPORT.md](TRANSPORT.md).
- [x] **5.2 OpenCode.** Validate an authenticated model through chat, Ask, Change, Insert, resume, and rejected write attempts; document supported versions and auth paths. OpenCode 1.18.15 with an OpenRouter API key and `openrouter/openai/gpt-4.1-mini` passed the live matrix in [TRANSPORT.md](TRANSPORT.md); other routes remain unverified.
- [ ] **5.3 Claude Code.** Validate the ACP adapter's plan mode, authenticated prompts, session restoration, hooks/tool boundary, and all four Pair actions. Restricted session profile, no-prompt adapter startup, and the full Pair workflow against a local ACP mock are checked; authenticated live turns await Claude login. See [TRANSPORT.md](TRANSPORT.md).
- [x] **5.4 Copilot CLI.** Copilot CLI 1.0.89 with an existing account passed restricted tool startup, streaming, cancellation, resume, all four Pair actions, and a write-attempt check. A mock covers unnamed read-tool events and blocks unexpected edit events. BYOK remains untested. See [TRANSPORT.md](TRANSPORT.md).
- [x] **5.5 Antigravity CLI.** The local `agy` account passed Chat, Ask, Change, Insert, streaming, cancellation, resume, unsaved-buffer inspection, and a guarded write-attempt check. Pair uses an isolated Antigravity home with a read-only primary agent and deny rules for writes, commands, MCP, and web tools. The official Antigravity ACP server is not used because its personal-account session creation hung here. See [TRANSPORT.md](TRANSPORT.md).
- [x] **5.6 Direct API research core.** Added bounded list/read/search/git inspection with path and output limits, a live-buffer overlay, no shell or write tool, and a provider-neutral conversation/session contract. Direct API provider transports and tool loops are the next slices.
- [x] **5.7 OpenAI API.** Responses API streaming, bounded research calls, cancellation, key handling, model choice, and local conversation restore are implemented. Mock protocol and loopback HTTP checks pass; authenticated live validation remains open.
- [x] **5.8 Anthropic API.** Messages API streaming and the same Pair workflow contract are implemented. Mock protocol and loopback HTTP checks pass; authenticated live validation remains open.
- [x] **5.9 Gemini API.** `streamGenerateContent` streaming, function responses, and thought-signature preservation are implemented. Mock protocol and loopback HTTP checks pass; authenticated live validation remains open.
- [x] **5.10 Long-session behavior.** Direct APIs warn near their local history ceiling, refuse an over-limit turn, and classify provider context errors; CLI session errors suggest a fresh chat. Earlier transcripts remain available. See [TRANSPORT.md](TRANSPORT.md).

**Gate:** Each listed backend and authentication route has a recorded result for chat, Ask, Change, Insert, streaming, cancel, resume, unsaved-buffer context, and attempted file writes. A failing route stays marked experimental.

## M6 — Public release

**Outcome:** Someone outside the author's Neovim setup can install, understand, and report problems with Pair.

- [x] **6.1 Install and CI.** Clean `lazy.nvim` and native package installs pass from a fresh GitHub clone. CI passes the non-live suite and install smoke checks on macOS and Linux with Neovim 0.11.7 and stable.
- [x] **6.2 Docs and support.** The README has a first-run path and support table; help, contribution, issue, security, and local-state guidance are in place. Recheck the table after remaining live gates.
- [ ] **6.3 Outside-user trial.** Have several Neovim users complete the headline flow without guidance. Fix blockers around context, scope, review, setup, and cancellation before tagging.
- [ ] **6.4 Publish.** Prepare a short terminal demo, confirm the GitHub repository/name and MIT license, publish a `v0.1.0` preview with known limits, then share it.

**Gate:** Docs, demo, release tag, and support matrix describe the same tested build.

## After the preview

Consider Tree-sitter function/class scopes, richer code-anchored teaching, review of user-written code against a plan, configurable prompt recipes, and more ACP agents after the core loop and launch backends are dependable. Keep autonomous project writes outside Pair's product contract.
