# Verification

Verified on macOS on November 12, 2026 (America/Denver).

## Environment

- Neovim 0.10.1
- Python 3.14.6
- Git 2.50.1
- Codex CLI 0.160.1
- Claude Code 2.1.322

The installed `kiln` shortcut resolves to this checkout. `kiln --doctor` confirms the local dependencies without starting an agent.

## Automated coverage

Run `make test` from the checkout. Tests use temporary Git repositories, executable provider doubles, and real headless Neovim processes. No model requests are submitted.

The final run passed 68 Python tests and 186 Neovim assertions: 54 live-change assertions, 56 provider-streaming assertions, and 76 workspace UI assertions. The local run log is retained under `.state/verification.log`.

The suite covers provider event normalization; fragmented streams; native session continuation; provider handoffs; subagent activity; account isolation; permission denials; literal argument handling; terminal restoration; editor layout; multiline drafts; live diffs; deleted, renamed, and untracked files; unusual filenames; symlinked buffer paths; preservation of unsaved edits; and native error diagnostics.

End-to-end cases run the actual Neovim interface through the Python bridge into fake Codex and Claude executables, change files on disk, and inspect the resulting editor buffers. Cancellation cases run stubborn provider and child processes under Neovim's real `jobstop()` lifecycle and verify that they are gone before its forced-kill deadline.

## Terminal checks

The offline workspace was inspected in detached 180×52 and 160×46 terminals. Startup, prompt access, Ctrl-S delivery, narrow layout, and clean exit were also checked in an 80×24 terminal. No application was brought to the front. The preview image is rendered from the actual offline terminal capture.

## Validation boundary

Installed CLI flags were checked against local help and official provider documentation. Authentication checks used account metadata only. Live model generation has not been exercised; the configured isolated profiles await approved-account sign-in.

The existing provider logins and normal Neovim configuration were left intact. No deployment, push, public posting, or paid model call was performed. Linux portability has not been exercised on a Linux host.
