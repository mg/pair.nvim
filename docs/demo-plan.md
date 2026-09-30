# Short terminal demo plan

Record a 60–90 second terminal clip on the build that will be tagged. Use a disposable Lua file such as:

```lua
local function total(items)
  local sum = 0
  for _, item in ipairs(items) do sum = sum + item end
  return sum
end
```

Show the following continuous flow in Neovim:

1. Open Pair Chat with `<leader>pc`, ask where input validation belongs, and show the streamed answer.
2. Close chat, place the cursor above `total`, press `<leader>pi`, and ask for a small helper that validates numeric items.
3. Show the proposal in the unsaved buffer and use `:PairDiff` once. Return to the inline controls and choose Accept with the keyboard.
4. Save the file, then show the resulting code without Pair controls. End with a concise caption: “Discuss, request a scoped change, inspect, then keep it.”

Use a verified live backend and a legible terminal color scheme. Keep account details, private paths, and unrelated windows out of the capture. Review the clip against the tagged build and README before attaching it to the prerelease.
