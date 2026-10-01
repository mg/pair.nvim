# Road to a public Pair.nvim preview

[MILESTONES.md](MILESTONES.md) is the ordered, issue-sized implementation plan. This document records the broader release gates and validation work.

## Release target

Publish an MIT-licensed GitHub repository and a clearly marked `v0.1.0` preview release. A Neovim user with a supported agent CLI or provider API key should be able to install Pair, choose a backend, complete the core workflow in a disposable project, understand what the agent can do, and report a useful bug without contacting the author privately.

The release message is **code with an agent while staying in charge of the code**. Show one short example that moves from chat to a scoped insertion or replacement and ends with an inspected, accepted proposal. Mention the question-answer workflow as a second benefit.

Multi-agent CLI support, account/subscription sign-in, and direct provider API-key access are launch requirements. Target Codex CLI, Claude Code, Antigravity CLI, GitHub Copilot CLI, and OpenCode as named integrations, plus configurable ACP agents that meet the same safety contract. Target the OpenAI, Anthropic, and Gemini APIs for direct-key access. Every listed route must pass authentication, streaming, session-continuity, and read-only checks before it is advertised. Avoid adding indexing, autonomous edits, multi-agent workflows, or a large configuration surface to this release. [UX.md](UX.md) describes the intended interaction in detail.

The current chat, prompt, Ask, and proposal UI is the alpha baseline. Add the focused context, review, session, and status controls in [MILESTONES.md](MILESTONES.md), then spend the remaining work on backend parity, correctness, installation, and accurate documentation.

## 1. Make the core workflow dependable

- [x] Send a snapshot of the full current source buffer from Neovim memory by default on each chat or buffer turn, including unsaved edits; never silently substitute the saved file.
- [x] Show what is attached and let the user inspect or remove it before sending. See M1 in [MILESTONES.md](MILESTONES.md).
- [x] Show backend, model when known, running action, queue, and cancellation in the one-row chat header.
- [x] Add compact, expandable tool activity. See M2 in [MILESTONES.md](MILESTONES.md).
- [x] Add a full diff on demand for pending proposals. See M3 in [MILESTONES.md](MILESTONES.md).
- [x] Accept Visual-mode command ranges for `:PairAsk` and `:PairChange`.
- [ ] Exercise Ask, Change, and Insert through their actual prompt windows and mappings in an interactive Neovim session. Check characterwise and linewise selections, empty or cancelled prompts, and the normal and Visual-mode command paths.
- [x] Give the chat pane a persistent input at the bottom while keeping the small floating prompt for buffer actions.
- [x] Keep the input within the right split, remove its instructional header, style user messages and agent text, and stream Codex app-server answers into the transcript.
- [x] Keep Pair panes at normal brightness when inactive; forward `:q` to the source window and close Pair with the last source window.
- [x] Put completed proposals in the unsaved buffer with clickable Accept and Reject controls; accept on save. Stream wrapped Ask answers beside the code and show in-buffer progress for Ask and edits.
- [x] Pin the transcript to the pane bottom during streaming and input resize. Show a three-line input with a prompt marker, shade Ask answers, and place keyboard- and mouse-operable proposal controls above the changed code.
- [x] Make all three input rows editable with the prompt beside the first row, brighten chat text and title its pane, pin long wrapped responses to their final displayed row, and give proposal controls a real keyboard focus that releases cleanly.
- [x] Remove the decorative input border, keep the input cursor clear of the prompt, disable completion in Pair inputs, brighten request prompts, and prevent background chat scrolling from taking focus during Ask or Insert.
- [x] Give the chat a fixed one-row header and divider, keep manual reading positions during streaming, clamp short and bottomed-out transcripts, show one prompt marker on wrapped input, and keep proposal controls reachable from both sides after nearby edits. Show a wrapped proposal rationale above the controls and dim tool/status entries.
- [ ] Check the chat input and transcript interactively, including focus when switching between chat and code and reopening the split.
- [ ] Check applied proposals visually for additions, replacements, and deletions, including long lines and multi-line changes. Acceptance must keep only the chosen buffer range; rejection must restore it without erasing later user edits.
- [ ] Verify behavior when the buffer changes while the agent works, the target buffer closes, the agent returns malformed JSON, the selected agent exits unsuccessfully, or a request is cancelled. Show a clear recovery action for each case.
- [ ] Verify that chat, Ask, Change, and Insert continue the selected agent's session across turns and after restarting Neovim. Check what happens when `:cd` changes after Pair starts, and document or enforce the result.

**Gate:** Someone unfamiliar with the implementation can complete chat → scoped request → inspect → accept/reject → save, without an unexplained error or an out-of-scope edit.

## 2. Add the launch backends and access paths

- [ ] Finish the backend contract for start/resume, prompt, streamed answer and tool events, cancel, stop, authentication status, and capabilities. Chat, Ask, Change, and Insert now route through a selected Codex or ACP backend with separate workspace session files; authentication and capability reporting still need work.
- [ ] Keep the working Codex app-server backend. The generic ACP client and Claude Code, Copilot CLI, and OpenCode presets are implemented and mock-tested. Copilot CLI, Antigravity CLI, and one OpenCode route passed live Pair workflows; OpenCode's default free model refused ACP prompting. Claude still needs authentication. A legacy Gemini CLI preset remains experimental for eligible paid-key or enterprise users; Antigravity is the supported personal Google account route. Validate the remaining routes, then add other ACP agents whose tool restrictions satisfy Pair's boundary. Verify current adapter versions rather than assuming every ACP agent behaves alike. Custom ACP launchers are experimental, not an advertised support guarantee.
- [ ] Implement direct API backends for OpenAI, Anthropic, and Gemini with streaming, tool calling, cancellation, persisted conversation state, and the same bounded proposal contract. These APIs provide models rather than a ready-made coding agent, so Pair must own the research tool loop.
- [x] Give direct API backends a small, constrained inspection toolkit: workspace file listing, file reading, text search, and read-only git inspection. Validate paths and arguments; do not expose an arbitrary shell or file-write tool. The core is implemented; provider transport wiring follows in M5.7–5.9. Direct API tests and builds remain user-run actions until protected command execution is integrated.
- [ ] Add backend selection and clear status/errors for missing CLI, missing login/key, unsupported authentication, failed startup, incompatible version, and API errors. Switching backends must make the session change visible; histories from separate backends are not the same conversation.
- [ ] Support each CLI's documented account/subscription login and API-key route. For direct APIs, read keys from documented environment variables or a user-supplied callback at request time; never print, log, or persist raw keys. Document which plans and auth modes have actually been verified.
- [ ] Test a matrix of backend × auth mode × chat/Ask/Change/Insert × streaming/cancel/resume. Distinguish subscription access through a CLI from separately billed direct API calls; providers control eligibility, limits, and policy.

**Gate:** A fresh user can choose any listed launch CLI or direct API backend, authenticate through its supported route, and complete the same scoped workflow. Each advertised backend/auth combination has a recorded test result.

## 3. Validate the agent boundary

- [ ] Test the exact CLI and adapter versions the release will support. Confirm that new and resumed turns enforce a read-only boundary and that project configuration, plugins, MCP servers, hooks, and auxiliary tools cannot bypass it. A failed safety check stops the request.
- [ ] Test the direct API tool loop with traversal, symlinks, hidden files, binary files, huge output, malformed tool calls, and attempts to invoke unadvertised tools. Review what context each API request transmits.
- [ ] For each provider, try commands and tools that would write ordinary source, including redirection and scripts. Confirm they fail, while explicit output-directory grants permit generated output. Document limits discovered. Prompt instructions alone are not a security boundary.
- [ ] Decide whether the agent may read outside the workspace. [Codex's `readOnly` policy](https://learn.chatgpt.com/docs/app-server) permits full read access by default; either configure restricted readable roots and test them or state the actual read scope plainly in the README.
- [ ] Check the proposal parser against valid JSON, code fences, extra prose, and malformed output. Never apply an unparsed response or a proposal outside the selected range.
- [ ] Check what project content and local state are sent to or saved by each CLI, direct API, and Pair. Explain session and transcript locations, reset behavior, and any privacy limits in the README.
- [ ] State each backend's actual security boundary precisely. Pair never gives the model an editor write tool. Direct APIs receive bounded inspection tools. Antigravity now runs inside Pair's filesystem sandbox with explicit output-directory grants; other CLI backends depend on their own sandbox or tool restrictions. Do not equate ACP permission prompts or a system prompt with process isolation.

**Gate:** The documented write boundary matches observed behavior, including failure cases. No claim depends on a system prompt alone.

## 4. Make it installable and supportable

- [ ] Test a fresh GitHub install with `lazy.nvim` and a manual `runtimepath` install. Provide a copyable setup snippet with the real repository address once it exists.
- [ ] Run the core checks on the minimum supported Neovim version and a current release. Test on macOS and Linux; only claim Windows support if it has been exercised there.
- [ ] Add focused automated checks for command registration, selection coordinates, proposal acceptance/rejection, stale buffers, backend events, startup/resume, cancellation, and provider safety configuration. Add CI that runs these checks on pushes and pull requests.
- [ ] Add `:checkhealth pair` or an equally clear diagnostic path for missing Neovim/backend requirements, login, API-key configuration, and launch failures without revealing credentials.
- [ ] Write `:help pair` documentation for setup, commands, mappings, proposals, session state, and troubleshooting. Keep the README short enough that a first-time user can start in minutes.
- [ ] Add `CONTRIBUTING.md`, an issue template for bugs, and a feature-request path. State how to reproduce a problem and which Neovim, CLI, and adapter versions to include. Keep the existing MIT license.

**Gate:** A clean-machine tester can follow the README, run the demo, find help for a failure, and file an actionable issue.

## 5. Prepare and publish the preview

- [x] Publish the repository as `sampsn/pair.nvim` with the MIT license and a first-run README. It is an untagged preview candidate while outside-user testing continues.
- [ ] Record a short terminal demo of the headline workflow, using a small sample file and showing the prompt window, preview, and accept/reject decision.
- [ ] Ask a few Neovim users to install from GitHub without verbal guidance. Fix the problems that prevent the core loop; capture other feedback as issues.
- [ ] Review the README and security wording against the tested behavior. Remove local absolute paths and temporary setup instructions from public-facing examples.
- [ ] Tag `v0.1.0` and publish a GitHub prerelease with supported versions, what works, known limits, and links to issues. Share the demo and repository link with friends and developer communities after the prerelease is live.

**Gate:** The release tag, docs, demo, and reported support matrix all describe the same tested build.

## After the preview

Prioritize feedback about scope control, preview clarity, prompt ergonomics, and session continuity. Consider growing the chat input for long messages. Explore Tree-sitter scopes, anchored teaching or review actions, and additional ACP agents after the launch providers have held up outside the author's setup.

## Launch questions to settle during testing

1. Which CLI and adapter versions can be supported without fragile flag or event assumptions?
2. Neovim 0.11 is the preview minimum. The full local suite passes on 0.11.7 and 0.12.5; 0.10.4 failed the chat bottom-alignment check in headless testing.
3. Does the name `pair.nvim` remain the right public name after checking the GitHub namespace and nearby projects?
4. Which subscription and API-key paths are supported by each agent's current CLI and provider policy?
5. Which further ACP agents beyond the five named integrations pass Pair's shared-session and read-only requirements with reliable subscription or API-key access?
