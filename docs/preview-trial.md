# Outside-user preview trial

Use a fresh Neovim configuration or a disposable profile. Do not guide the tester through the steps unless they get stuck; capture where the README or UI failed them. Use a small project without secrets.

1. Install Pair from the README with Neovim 0.11 or newer. Run `:checkhealth pair` and note anything unclear.
2. Open a source file, make an unsaved change, and ask Pair Chat a question about that line. Confirm the answer uses the unsaved version.
3. Select a function and use Ask. Read and dismiss the answer in the buffer.
4. Select a few lines and request a Change. Inspect the inline proposal and full diff, then Reject it. Confirm the original code returns.
5. Place the cursor between functions and request an Insert. Inspect it, Accept, and save. Confirm only the desired code was written.
6. Start a new chat with `:PairNew`, then resume the previous one with `:PairSessions`. Close and reopen Pair Chat, and try Cancel during a long response.
7. Report the backend, CLI/adapter and Neovim versions, what worked, where you paused, and the smallest redacted reproduction for any problem. File issues using the repository templates.

The preview gate is several users completing the core loop without private instructions. Track blocking setup, scope, review, and cancellation problems as issues before tagging. Optional or experimental backends should be reported separately from the tested Codex, Antigravity, Copilot, and OpenCode routes.
