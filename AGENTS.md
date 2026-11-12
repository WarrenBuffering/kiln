# Kiln development

Kiln is a local terminal workspace. Do not deploy it, publish it, or push branches without an explicit request. Author commits as WarrenBuffering.

Keep the editor and provider boundary explicit. Neovim owns editing, navigation, and display; the Python bridge owns provider processes and event normalization. Use argument arrays, never shell interpolation, for prompts, filenames, models, or session IDs.

Preserve the user's existing Neovim configuration and provider accounts. Do not copy credentials or switch an unrelated CLI login. Respect configured provider profile directories and expected-account checks in both streamed and native sessions.

Never overwrite a modified editor buffer during refresh, following, or diff review. Keep normal Vim motions available in every non-terminal pane. Preserve focus when agent events change displayed files.

Run `make test` for behavior changes. Tests must use temporary repositories and fake provider executables; do not make billable model calls without explicit authorization. Trace fixes through both Codex and Claude adapters when applicable. Exercise the actual Neovim-to-bridge boundary for lifecycle changes.

Keep source, documentation, and commit messages in normal professional prose. Do not create backup copies or retain superseded build artifacts.
