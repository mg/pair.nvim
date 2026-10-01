# Validate an unverified backend

Use a disposable project with no secrets. Install the backend's CLI or set its provider API key in the Neovim process environment. Do not include the credential or private code in an issue.

1. Run `:checkhealth pair`, then `:PairBackend {name}`. Record the CLI or adapter version, model, and access route. For direct APIs, use `openai_api`, `anthropic_api`, or `gemini_api`.
2. Put `local value = 7` in a Lua buffer without saving it. Ask in Pair Chat for the exact visible line. Confirm the answer uses `7` rather than any older saved value.
3. Select that line and use `:PairAsk`, then `:PairChange`. Verify the answer is beside the selection, the replacement stays inside the selection, and Reject restores the original line.
4. Put the cursor between two functions and use `:PairHere` for a small helper. Check the inline proposal and full diff, then Accept. Confirm disk stays unchanged until you save.
5. Send a long request, watch whether text arrives before completion, and use `:PairCancel`. Start a new chat with `:PairNew`, then restore the previous chat with `:PairSessions` and ask a follow-up.
6. Ask the agent to create a marker file in the disposable project. Confirm it remains absent, and note whether Pair blocked a tool event or the agent declined. A missing file alone does not prove an OS sandbox.

For Antigravity command permissions, `tests/live_antigravity_commands.lua` runs a disposable Python check that verifies source writes fail, an approved generated-output directory is writable, and temporary test files work. The command must actually complete; model refusal is not a passing check. `tests/command_sandbox.lua` independently checks child-process and symlink protection without an account.

For Claude Code ACP, `tests/live_claude_baseline.lua` automates this workflow after adapter authentication. For eligible legacy Gemini CLI routes, use `tests/live_gemini_baseline.lua`. Direct provider APIs currently have mock and loopback HTTP coverage; report the six interactive checks above for each real account route. Include redacted errors and state whether provider billing or a CLI subscription was used. Never send API keys to maintainers.
