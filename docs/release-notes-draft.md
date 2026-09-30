# Pair.nvim v0.1.0 preview — draft

Pair brings a shared agent conversation into Neovim while keeping code edits in your hands. Ask in chat, ask about a selection, request a scoped replacement or insertion, and review a proposal in your unsaved buffer before keeping it. Pair sends the current buffer from Neovim memory, including unsaved edits, by default.

## Supported preview routes

Codex app-server, Antigravity CLI, GitHub Copilot CLI, and OpenCode with the tested OpenRouter model/account route have passed the core live workflow on macOS. See the README support table and TRANSPORT.md for exact versions and limits. Claude Code ACP, legacy Gemini CLI ACP, and direct OpenAI/Anthropic/Gemini APIs are available as experimental routes with mock/loopback coverage; their authenticated workflows still need testing before being called supported.

## Requirements and known limits

Neovim 0.11 or newer; Git and the selected backend's CLI or a direct API key. One active workspace and one pending proposal per Neovim instance. Pair does not run builds or tests through agents and does not provide an independent OS sandbox for CLI backends. Attached source content is sent to the selected provider. Direct API sessions ask for a new conversation before local history exceeds 2 MiB or 400 messages; provider context limits may arrive sooner.

## Before publishing this draft

- Confirm Linux CI and clean GitHub installs on the tagged commit.
- Recheck exact live backend versions and the README support table.
- Complete an outside-user trial and resolve blocking issues.
- Record and review the short demo.
- Add the GitHub issue and security links after the repository exists.
