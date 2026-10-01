# Run from the Pair repository root: vhs demo/workflow.tape
# Uses a live Codex session. No prerecorded or simulated agent responses.
Output assets/pair-workflow.gif
Output assets/pair-workflow.mp4

Require nvim
Require codex
Require python3

Set Shell "bash"
Set FontFamily "FiraCode Nerd Font Mono"
Set FontSize 14
Set Width 1440
Set Height 900
Set Padding 16
Set Margin 16
Set MarginFill "#0e111a"
Set BorderRadius 10
Set WindowBar Colorful
Set WindowBarSize 30
Set Theme "TokyoNight"
Set Framerate 12
Set TypingSpeed 55ms
Set CursorBlink false

Env PS1 "$ "
Env PAIR_DEMO_REPORT "/tmp/pair-zig-demo-result"

# Show the editor rather than the recording setup.
Hide
Type "python3 demo/launch.py"
Enter
Wait+Screen@30s /pub fn total/
Sleep 500ms
Show
Sleep 1s

# CHAT: plan in the sidebar, using the visible Zig module as context.
Space
Type "pc"
Sleep 500ms
Type "Keep f64. Where should I round the final price? One short sentence, no code."
Escape
Sleep 250ms
Enter
Sleep 300ms
Wait+Screen@90s /Ready/
Sleep 3s
Screenshot "/tmp/pair-demo-chat.png"

# ASK: select the calculation and ask beside the code.
Ctrl+w
Type "h"
Type@100ms "15ggV3j"
Sleep 600ms
Space
Type "pa"
Sleep 400ms
Type "Why are there fractional cents? One short sentence."
Sleep 500ms
Enter
# At this font size the inline spinner fits beside the selected function.
Wait+Screen@30s /Pair .*thinking/
Screenshot "/tmp/pair-demo-thinking.png"
Sleep 800ms
Wait+Screen@90s /Ready/
Sleep 3s
Screenshot "/tmp/pair-demo-ask.png"
Space
Type "pd"
Sleep 400ms

# INSERT: ask for the helper at a precise location, in the same session.
Type "14gg"
Sleep 400ms
Space
Type "pi"
Sleep 400ms
Type "Add the roundCents helper here. Use @round. Leave callers to me."
Sleep 500ms
Enter
Wait+Screen@90s /Accept/
Sleep 3s
Screenshot "/tmp/pair-demo-insert.png"

# Review with Vim motions, then accept only the scoped helper.
Type "j"
Sleep 900ms
Enter
Sleep 800ms
Type "13ggo"
Escape
Sleep 400ms

# The human wires the helper into the caller and saves the visible result.
Type "/return amount"
Enter
Sleep 400ms
Type "cc"
Type@80ms "return roundCents(amount * (1 - discount));"
Escape
Sleep 700ms
Type ":noh"
Enter
Type ":w"
Enter
Sleep 1s
Screenshot "/tmp/pair-demo-final.png"
Sleep 4s

# Keep teardown out of the clip.
Hide
Type ":qa!"
Enter
Sleep 500ms
