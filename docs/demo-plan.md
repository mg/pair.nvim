# Terminal demo

The README demo is recorded with [VHS](https://github.com/charmbracelet/vhs).
Its source is [demo/workflow.tape](../demo/workflow.tape), with a small
[Zig checkout](../demo/checkout) and an isolated Neovim recording config.

The continuous workflow shows:

1. Chat about where to round the final price, with the visible module attached.
2. Select the discount calculation and Ask why it can produce fractional cents.
3. Insert a rounding helper between functions using the same conversation.
4. Inspect the proposal and accept it with Vim motions.
5. Wire the helper into the caller by hand and save.

These are live Codex responses, not simulated messages. The recording uses
the existing CLI login and account quota. The example project and Neovim
state are temporary; the user's editor configuration is not loaded.

See [recording instructions](../demo/README.md). Outputs are
`assets/pair-workflow.gif` and `assets/pair-workflow.mp4`.

Before replacing the public demo, review the chat, Ask, proposal, and final
screenshots, check the saved-code report, and run Zig tests against that saved
code. Keep private paths and account details out of the capture. Prefer a
short clip with enough pause to read each result.
