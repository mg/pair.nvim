# Pair.nvim vision

Pair is a Neovim coding companion for programmers who want to work with an agent while staying hands-on and in control of each change.

## Promise

One conversation follows you between a chat pane and the source buffer. The agent can research, explain, review, and propose a small edit. You choose where a change belongs, inspect it in the unsaved buffer, and accept or reject it through Neovim.

**Pair helps you code with an agent while you stay in charge of the code.** The first public release should make that promise tangible in one short workflow: discuss a change, choose its exact location, inspect a proposal, and accept or reject it.

The headline use case is coding with an agent while remaining close to the implementation. A second use case is learning with the agent as a guide or tutor. Both use the same conversation and editor actions.

## Two use cases

### Hands-on coding (headline)

Plan or investigate in chat, then direct the agent to a specific place in the buffer. Select code to request a change, or put the cursor between functions and ask it to insert a helper there. Review the unsaved change where it belongs, then keep or reject it. The user still decides how the codebase is organized and which proposals belong in it.

### Learning with a guide

Select code to ask how it works, ask the agent to point out relevant locations before writing anything, or write an implementation and ask for a review of the reasoning behind it. Explanations stay anchored to the code when possible. This is an important workflow, but it does not need to lead the plugin's messaging or interrupt the normal coding flow.

## Core workflow

1. Discuss a problem in the chat pane. The agent can inspect the repository and report what it found, with file locations.
2. Select code to ask a question or propose a replacement. Or place the cursor at an insertion point and request new code there, such as "add a helper function here for ...". These actions continue the same conversation.
3. Read the wrapped answer beside the code, or inspect the proposed change in the unsaved buffer before keeping it.
4. Continue in the chat pane with the result and decision visible in the same conversation history.

The editor provides *scope*; the session provides *continuity*. Chat helps decide what to do; buffer actions help do it one piece at a time. Every turn should send the full current source buffer from Neovim memory by default, including unsaved edits. A buffer action should also carry its exact range or insertion point into the shared session. Pair shows the attached context and never silently substitutes the saved file for the live buffer.

The primary audience is a Neovim user who already uses coding agents, but wants to see and shape smaller pieces of implementation. Pair should feel useful during ordinary coding, with learning as a natural result of staying close to the work.

## Buffer interactions

| Action | Scope | Result |
| --- | --- | --- |
| Ask about selection | Selected lines or text | Answer attached to that code, with the full turn in chat |
| Change selection | Selected lines or text | Reversible unsaved replacement |
| Insert here | Cursor position, usually a blank line between definitions | Reversible unsaved insertion at that exact point |

"Insert here" opens a small editable prompt window near the cursor. The instruction is never inserted into the source file. Submitting the prompt closes the window and shows a spinner at that position while Pair works. Once the proposal is complete, Pair inserts it into the unsaved buffer and shows Accept and Reject controls beside the code.

The default edit review happens in the source buffer, at the chosen scope. The public preview should also offer a full diff on demand when the local change is too large to judge easily. Saving the buffer accepts the current proposal; Reject restores the original scoped code if it has not been changed again.

## Chat pane

The chat pane is a place to think through the work with the same agent that handles buffer actions. It should have a persistent message input at the bottom, so writing a follow-up does not require opening a separate prompt. Buffer actions still use a small prompt window near the selected code or cursor. Both routes feed the same session timeline.

The main transcript should read like a conversation. Research commands and other tool activity appear as compact entries that can be expanded to see the command, result, and errors. Buffer requests and accept/reject decisions should also appear in the timeline, without burying the discussion under event logs.

[UX.md](UX.md) describes how these surfaces should behave together and what should happen when an action fails or becomes stale.

## Product rules

- The agent does not directly edit project files. Pair applies a completed proposal to an unsaved Neovim buffer; the user's normal save workflow persists it and accepts the proposal.
- A proposal names one target buffer and one bounded range for the first version. An insertion uses an empty range anchored at the cursor. The plugin rejects proposals outside that scope.
- A proposal is tied to the buffer version it was based on. If the selected region or the code around an insertion point changes while the agent works, Pair asks for a fresh proposal instead of silently overwriting the user's work.
- Chat and buffer actions use the same session and appear in one timeline. Buffer actions may be visually compact in chat, but they are not hidden from it.
- Research commands need a real read-only boundary for the project. Some commands, including tests and builds, may create files; that behavior needs a deliberate policy before they are offered as agent tools.
- Explanations should be available when useful, but should not be required reading before accepting every edit.
- Pair should make the scope and effect of every proposed change obvious. If the buffer moves on while the agent works, it must refuse a stale proposal instead of guessing.
- The main workflow should work with plain Neovim and any launch-supported CLI agent or direct API backend. Backend choice must not change how chat, Ask, Change, Insert, or proposal review works.

## Public preview boundary

The first public GitHub release is a **multi-backend preview**. Its headline demonstration is: choose a CLI agent or direct API backend, chat about a task, select code to ask or request a replacement, or place the cursor between functions to request an insertion, then review and accept or reject the proposal. The agent may inspect the project through a verified read-only boundary, while Pair owns changes to the Neovim buffer. Codex CLI, Claude Code, Gemini CLI, GitHub Copilot CLI, and OpenCode are the named CLI targets, with a path for other ACP agents; direct OpenAI, Anthropic, and Gemini API-key connections are also required. The integration and safety checks are in [ROADMAP.md](ROADMAP.md).

The preview should clearly state its limits: one workspace per Neovim instance, one pending proposal, a prompt window suited to short requests, and conservative stale-buffer detection. CLI users may authenticate through a supported account/subscription login or API-key path. Direct API users supply provider API keys and use that provider's API quota and billing terms, independently of an agent subscription. Pair must document which combinations were verified and how each backend enforces read-only work. The selected backend has one shared conversation across Pair surfaces; switching backends changes sessions and does not transfer conversation history automatically.

The launch criteria and ordered work are in [ROADMAP.md](ROADMAP.md).

## Local alpha implemented

The local alpha exercises the smallest complete loop:

- Start or resume one Codex session for the current workspace. The alpha uses Codex app-server events by default, requesting an explicit read-only sandbox on each turn; the older `exec` transport is available as a fallback.
- Show a chat split with streamed answers and basic tool activity. Keep the input at the bottom of the chat split and use normal Vim editing there.
- Ask about a visual selection in that same session.
- Request a replacement for a visual selection.
- Request an insertion at the cursor using an inline prompt, including between two functions.
- Show the completed proposed change directly in the unsaved buffer with clickable accept and reject controls.
- Show the request, proposal, and accept/reject outcome in the session timeline.
- Detect edits to the target region while a proposal is pending.

This tests the central claim: can the agent help someone understand the code and make progress while they remain in charge of the buffer? The public preview should prove that someone outside the author's setup can install and complete this loop with each launch-supported backend and access path without help.

## Later experiments

- Infer scope from Tree-sitter text objects such as the surrounding function or class.
- Improve code-anchored answers and edit rationales beyond the alpha's basic virtual text.
- Add a "show me where" action that returns locations and an implementation outline for the user to write.
- Let the user request a review of code they wrote against an earlier plan.
- Add further ACP agents and direct API providers after the launch matrix is stable.

## Architectural questions to prove with a spike

1. Can ACP adapters preserve Pair's read-only project boundary, session continuity, and bounded proposal workflow with Claude Code and Gemini CLI? The alpha uses Codex app-server directly and parses a strict JSON proposal response; each new adapter needs an independent integration and safety check.
2. Can Pair's direct API tool loop provide enough project context through file reading, search, and read-only git inspection without exposing shell or write access?
3. What is the safest useful command policy on macOS, Linux, and Windows when the agent may inspect the repo but cannot write project files?
4. How should a second action behave while a session turn streams? Start with a visible queue and cancellation; only add live steering if it improves the workflow and the adapter supports it reliably.
5. Which session state can be restored after restarting Neovim, and what must Pair store locally to reconnect buffer annotations and proposal outcomes?

## Nearby work

lg.nvim already combines scoped editing and chat in a shared ACP session. CodeCompanion offers chat, editor context, and inline diff workflows. Pair's intended distinction is the interaction contract: the user directs where each change belongs, the agent proposes bounded code, and the user applies it through the editor. The same interface also supports learning from the code.
