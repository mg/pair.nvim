# Pair.nvim interaction design

This is the intended public-preview experience. It describes behavior and feel; the current alpha implements only part of it.

## Overall feel

Pair should feel like a quiet Neovim companion. The source buffer remains the main workspace. Chat is a persistent place to think through a task, and editor actions are short, local interruptions that return focus to the code. Every agent action should make its scope and current state clear. Routine use should require few keystrokes and no special prompt syntax.

Use normal Neovim buffers, windows, highlights, and keymaps. The layout should resize with the editor, remain usable in both light and dark color schemes, and avoid hard-coded colors or large permanent controls. A user should be able to hide the chat split without losing the session or an in-progress proposal.

## Chat split

The right-hand split has two stable parts:

```text
┌ source buffer ──────────────┬ Pair ─────────────────────┐
│                             │ conversation              │
│ selected code or cursor     │ compact research activity │
│                             │ answers and decisions     │
│ proposed change at scope    ├───────────────────────────┤
│                             │ persistent message input  │
└─────────────────────────────┴───────────────────────────┘
```

- The transcript is readable first as a conversation: user requests and agent answers get visual priority. Distinguish them with spacing, symbols, and bright, readable color rather than repeated role labels. Give user messages a subtle background and tool or status messages slightly dimmer text. Keep the text close to the split divider without an extra gutter. The pane title reads **Pair Chat** in a distinct, fixed one-row header, separated from the scrolling transcript by the window divider.
- The message input stays at the bottom of the chat split only, shows three editable lines by default, and uses normal Vim modes and motions. A slightly lighter background and a small `❯` marker beside the first editable line distinguish it from the transcript. Use Neovim's actual pane boundary for resizing, without a decorative border. The cursor starts at the first editable column after the prompt in either mode, and its line uses the same background as the rest of the input. Disable completion menus in Pair input and request windows. It can grow for a longer message without consuming the whole screen. In Insert mode, `Enter` adds a line. In Normal mode, `Enter` sends, clears the input, and leaves focus in the chat input.
- Keep the final displayed row of the transcript at the physical bottom of the pane during streaming and input resize, including long wrapped paragraphs, unless the user has scrolled up to read earlier messages. Streaming must preserve a manually scrolled reading position. Starting a new Chat, Ask, or Insert request returns the transcript to live follow. Short transcripts cannot scroll, and scrolling at the end should not leave blank rows under the final row.
- Pair's chat and input keep their normal colors even when the source buffer has focus. `:q` in a Pair window acts on the last source window; when the last source window quits, Pair closes too.
- Stream agent text into the transcript as it arrives, with light Markdown and code styling that follows the user's colorscheme.
- Attach the full current source buffer from Neovim memory to each chat turn by default, including unsaved edits. While chat has focus, use the last focused source buffer. A compact indicator beside the input shows the attached file and modified state and lets the user inspect or remove the attachment. Capture it at send time so later edits appear in the next turn. If the buffer is too large, ask the user to narrow the scope instead of silently sending the saved file or an incomplete snapshot.
- A running turn shows a small status indicator and a cancel action. If a second request is queued, show that fact rather than making the editor appear unresponsive.
- Tool activity is compact by default: one row for a command or research step with running, success, or failure state. Expanding it reveals the command and bounded output or error. Do not dump command output into the conversation by default.
- An Ask, Change, or Insert request is represented in the same timeline with its file and location. A proposal decision appears as a short accepted/rejected event. The full answer or rationale remains available in chat even when the user dismisses its buffer annotation.

## Ask about selected code

1. Select code and invoke Ask.
2. A small prompt window with readable foreground color opens near the selection. The selection stays intact; no prompt text enters the source buffer.
3. On submit, Pair marks the request as running and sends the target buffer's full live contents and exact selected range into the shared session. The selection remains the focus of the question.
4. A small spinner appears beside the code while the agent works. The answer streams into wrapped lines below the selection and into the chat transcript at the same time. Dismissing the annotation does not erase the conversation.

The annotation can show the full answer, wrapped to the source window width, with a subtle background. Click its `×` or use `<leader>pd` / `:PairDismiss` to remove it. Source editing keys such as `d` retain their normal meaning. A changed or closed target buffer should leave the answer in chat and explain why it could not be attached to code.

## Change selection and Insert here

1. A selection defines the exact replacement scope; the cursor defines an empty insertion scope. Pair displays the scope before or while the request runs.
2. A small prompt window near the code collects the instruction. Cancelling it returns to the original buffer without starting a turn.
   The request includes the target buffer's live contents at submission, even when it has not been saved. The selection or cursor position still bounds where a proposed edit may land.
3. A small spinner marks the scope while the agent works. The buffer remains editable; if it changes before the proposal can be shown, Pair reports that the proposal is stale and asks for a new request.
4. Pair places the completed proposal directly in the unsaved source buffer, highlights the changed lines, keeps the cursor on the real line above the change, and shows a wrapped rationale and colored Accept and Reject controls between that line and the new code. Mouse hover highlights a control; a click chooses it. `j` from above or `k` from the first proposed line focuses the controls with a real cursor, `h` and `l` choose, and `Enter` applies the choice. `k` exits above the controls; `j` exits into the changed code. The controls track their buffer position when nearby code changes. Focus must never trap ordinary movement above the change. The temporary annotation disappears immediately after Accept, Reject, or save.
5. Accept keeps the code and clears the controls. Reject restores the original code while the buffer remains untouched by the user. If the user edits after the proposal appears, Reject refuses to overwrite those edits; Accept or save keeps the current buffer. Saving accepts automatically. Undo removes the proposal in its own undo step and clears the controls; redo is then the user's normal editor action.
6. A full diff opens on demand with `:PairDiff`, `<leader>pv`, `d` from the controls, or a click on Diff. It uses two temporary Vim diff windows for the original and proposed code with three context lines on each side. `q` or `Esc` returns to the same inline review position and choice.

Keep one pending proposal for the public preview. A new edit request should explain that the current proposal needs a decision first. Questions and chat can continue if the single-session scheduler can present their order clearly.

## Error and recovery behavior

- A missing Codex CLI, failed login, disabled tool boundary, failed turn, or malformed proposal should show a plain-language error in chat with a useful next action. The source buffer must remain unchanged.
- A proposal tied to an older buffer version cannot be applied. If the user edits after Pair applies a proposal, Reject must not erase their edits.
- If the agent's response is empty or outside the requested scope, keep it as text in chat and do not present it as an applicable edit.
- Closing the chat split does not cancel a turn. Explicit cancellation does, and its outcome appears in the timeline.

## Public-preview usability check

Give a new user one task: discuss a helper function in chat, insert it between two functions, inspect the unsaved buffer edit, accept or reject it beside the code, and save. Then have them select a block and ask why it works. The flow succeeds if they can identify what the agent ran, where the proposal landed, how to reject it, and whether the file has been saved without verbal guidance.
