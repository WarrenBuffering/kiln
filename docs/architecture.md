# Architecture

Kiln uses Neovim as its interface and editor. A separate Python process adapts each provider's event stream. Keeping these concerns separate lets the editor remain responsive while a provider is working and lets protocol tests run without network access.

```text
Neovim workspace
  ├── code windows and native diff views
  ├── session, transcript, and prompt buffers
  ├── repository change watcher
  └── Python bridge (one process per running turn)
        ├── Codex: exec --json
        └── Claude: --print --output-format stream-json
```

## Process boundary

The editor starts the bridge with an argument list, not a shell command string. The prompt travels over standard input. The bridge starts the provider the same way and sends normalized JSON Lines events back to Neovim. This avoids interpreting prompt text, file paths, or model names as shell syntax.

Events identify sessions, assistant messages, tool calls, changed files, usage, errors, and turn completion. Message and tool IDs allow the interface to update a running item without duplicating it. Subagent events retain parent information when the provider exposes it.

Each provider owns its native conversation ID. A follow-up turn resumes that exact conversation; switching providers must not reuse another provider's ID. Model overrides are passed through to the selected CLI. Omitting a model preserves its configured default.

The launcher holds an advisory filesystem lock for the canonical project path within its state directory while Neovim runs. A second launcher for the same project cannot overwrite its session history or start another editing owner. The operating system releases the lock when the launcher exits. Empty lock files remain to avoid an unlink race; their existence alone does not mean a workspace is running. Offline demonstrations do not acquire the lock because they neither persist sessions nor run agents.

Stopping a turn terminates its process group so ordinary child processes do not continue after the UI says the turn has stopped. The bridge reports final exit state separately from message content; a convincing response cannot turn a failed command into success.

## Filesystem visibility

The live change module reads Git status and refreshes on a short interval. Git HEAD is the review baseline, so the file list describes the entire current working tree, including changes made before an agent turn. It is not proof that an agent authored every listed change.

File refresh respects Neovim's modified flag. External writes may reload an unmodified buffer; an unsaved buffer needs explicit reconciliation. Diff review uses scratch baseline buffers and never resets the repository or rewrites working files.

## Isolation

The standalone launcher changes the editor's runtime configuration and XDG paths only for the launched process. It does not modify the user's normal Neovim installation. The bridge restores the original XDG environment before starting a provider. An optional local `providers.json` can select isolated provider directories and require a specific email address; the launcher and bridge share the same account-checking helper. Existing default provider profiles are not changed or copied when isolated directories are configured.

The project has no web server, hosted deployment, or service-side database. Provider CLIs perform their own network access when the user submits a prompt or explicitly requests login.
