# Contributing to Pair.nvim

Pair is a Neovim plugin for coding with an agent while keeping edits in the user's hands. Read [VISION.md](VISION.md) and [UX.md](UX.md) before changing the workflow. Small fixes and clear reproductions are welcome.

## Development setup

Use Neovim 0.11 or newer, Python 3, and Git. Clone the repository and point a local lazy.nvim spec at the checkout, as shown in [README.md](README.md). The non-live suite needs no agent login or API key:

```sh
bash tests/run_all.sh
bash tests/install_smoke.sh
```

The clean-install check downloads lazy.nvim into a temporary directory. Live backend tests are opt-in, may use account quota, and run in temporary workspaces. Their commands and coverage are in [TRANSPORT.md](TRANSPORT.md).

## Changes and pull requests

Describe the user-visible behavior, the backend or Neovim version affected, and how you verified it. Add a focused regression check for changes to scope, proposal application, session recovery, transport parsing, or the read-only boundary. Avoid tests that only repeat an implementation detail. Keep secrets, full transcripts, and private repository content out of issues and fixtures.

For a new backend, first document its account route, session/resume behavior, streaming events, tool permissions, and cancellation. A successful handshake alone is not enough to call it supported. Check Chat, Ask, Change, Insert, unsaved-buffer context, resume, cancel, and attempted writes. Update the support table and [TRANSPORT.md](TRANSPORT.md) with the exact route and version that passed.

Please file a bug with the issue template if a change affects another backend or the editor controls unexpectedly. If you find a security issue, follow [SECURITY.md](SECURITY.md) rather than posting exploit details in a public issue.
