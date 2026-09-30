# Security and privacy

Pair does not give an agent a Neovim file-writing tool. It applies completed proposals to the unsaved buffer for the user to review. Direct API backends receive only bounded file and git inspection tools. CLI backends rely on that CLI's sandbox or tool restrictions; Pair does not create an independent operating-system sandbox. A system prompt or an ACP permission prompt alone is not treated as a write boundary.

The selected provider receives your prompt and attached editor snapshot, including unsaved changes by default. CLI tools may read additional files according to their own permissions. In particular, Codex read-only mode can read outside the workspace. Do not send sensitive project content to a provider you do not trust. Review or detach the full-buffer attachment before sending when needed.

Pair saves transcripts, agent session pointers, models, and direct API conversation history under Neovim's `stdpath('state')/pair`. New files are created with owner-only permissions. Pair masks common key patterns in saved chat text, but cannot identify every secret. The selected CLI may maintain its own separate history. `:PairNew` keeps prior Pair records; removing the Pair state directory removes those local records.

To report a vulnerability, use GitHub's private **Report a vulnerability** flow when available, or contact the maintainer privately through their GitHub profile. Include the affected version, backend, reproduction steps, and the concrete boundary crossed. Do not include credentials or private source content. Public bug reports are suitable for ordinary UI and compatibility problems.
