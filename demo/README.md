# Record the Zig workflow

From the repository root:

```sh
brew install vhs ttyd ffmpeg
mkdir -p assets
vhs demo/workflow.tape
```

Requires Neovim 0.11+, Python 3, the recorded font (FiraCode Nerd Font Mono),
and an authenticated `codex` CLI. Recording uses your account's quota.
VHS downloads a headless browser if one is not already available.

The tape records real chat, Ask, and Insert interactions in one live session:
discuss rounding, select the discount calculation, request a helper between
functions, accept it with Vim motions, and wire up the caller by hand.

`launch.py` copies the Zig checkout into a temporary project and isolates
Neovim's config, data, cache, and state. The original fixture and your Neovim
setup are preserved. Responses and timings can vary between recordings.

Outputs: `assets/pair-workflow.gif` and an MP4 version. Screenshots and a
saved-code verification report are written under `/tmp/pair-demo-*` and
`/tmp/pair-zig-demo-result.*` for review.
