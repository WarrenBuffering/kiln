# Provider references

Kiln integrates the installed CLIs rather than maintaining separate API clients.

- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive) documents JSON Lines events and automated command execution.
- [Codex CLI reference](https://developers.openai.com/codex/cli/reference) documents command arguments and session resumption.
- [Codex app-server](https://learn.chatgpt.com/docs/app-server) documents the metadata-only account identity check.
- [Run Claude Code programmatically](https://code.claude.com/docs/en/headless) documents print mode, streaming output, and session continuation.
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) documents model overrides and permission settings.

The local implementation was developed against Codex CLI 0.160.1, Claude Code 2.1.322, and Neovim 0.10.1. CLI schemas can evolve; parser tests cover the event families Kiln consumes, and unknown activity must remain visible or degrade safely rather than crash the editor.

Native provider output is not identical. Codex generally reports assistant text at item boundaries; Claude can emit text deltas. Tool and file activity can appear before a complete assistant message. Kiln renders the events it receives without inventing progress or extrapolating account balances from token counts.

Model names are account dependent. Kiln leaves default selection to the CLI and permits explicit model names. A failed model selection should appear as an error in the transcript so the user can choose another model.
