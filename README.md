# Kiln

**Keep the code in view. Keep the agents in reach.**

Kiln is a terminal workspace for programming with Codex and Claude. The code takes three quarters of the window; an agent sidebar takes the remaining quarter. Both sides are Neovim buffers, so your normal motions, search, selection, and yank commands work throughout the workspace.

It runs the CLIs already installed on your machine. It does not require another API key, download plugins, or replace your Neovim configuration.

```sh
kiln /path/to/your/project
```

To open a particular file:

```sh
kiln /path/to/your/project src/main.py
```

The local setup provides `kiln` on your PATH. From any other checkout, use `./bin/kiln` directly or add its `bin` directory to your PATH. `--help` lists the arguments. No agent starts until you submit a prompt.

## Workspace

```text
┌────────────────────────────────────────────────────┬──────────────────┐
│                                                    │ KILN             │
│                                                    │ Provider / model │
│                                                    ├──────────────────┤
│                     NEOVIM                         │ Live transcript  │
│                                                    │ Tools and agents │
│              Your code and live diffs              │ Changed files    │
│                                                    ├──────────────────┤
│                                                    │ Editable prompt  │
└────────────────────────────────────────────────────┴──────────────────┘
```

The sidebar is a Vim interface rather than a terminal emulator. Use `j`/`k`, `gg`/`G`, `/`, visual mode, and `y` to inspect the transcript. Press `gf` on a referenced filename to open it in the code pane. Prompts are normal editable buffers with multiline editing, registers, and undo. Agent responses and tool activity appear as the provider emits them.

Changed files are available for inspection while work is running. Following is enabled initially: provider file events open a live diff in the code area while keyboard focus stays where you left it. Use `Space f` to pause following while you inspect another file. Native Neovim diff views compare the working tree with Git HEAD, including staged changes and newly created files. Files with unsaved editor changes are protected from automatic reload.

## Keys

The leader key is **Space**.

| Key | Action |
| --- | --- |
| `Space a` | Focus the prompt |
| `Space e` | Focus the code |
| `Space p` | Choose Codex or Claude |
| `Space m` | Choose or enter a model |
| `Space o` | Choose edit or plan mode |
| `Space n` | Start a new agent session |
| `Space s` | Switch agent sessions |
| `Space d` | Inspect changed files and diffs |
| `Space D` | Close the diff |
| `Space f` | Toggle following agent file changes |
| `Space b` | Browse project files |
| `Space c` | Add the visual selection to the prompt |
| `Space r` | Reuse the current transcript entry in the prompt |
| `Space x` | Stop the active agent |
| `Space t` | Open this session in the native provider interface for approvals |
| `Space Space` | Open the command palette |
| `Space ?` | Open help |
| `Ctrl s` | Submit the prompt, in normal or insert mode |
| `Ctrl h/j/k/l` | Move between panes |
| `Ctrl w` followed by `h/j/k/l` | Standard Neovim window navigation |

Use `Esc` to return from insert mode. `:w` saves code, and `:qa` exits the workspace. The launcher gives `Ctrl s` to Neovim by temporarily disabling terminal flow control, then restores the terminal settings when Kiln exits.

## Providers and models

Codex and Claude keep their own authentication, configuration, and native session history. Kiln checks account identity when a local account profile requires it and never copies authentication credentials.

The default model is the provider CLI's configured default. Enter a model name supported by your account to override it. Availability and account limits remain controlled by the provider. Changing providers creates a separate native conversation and adds a visible handoff of recent conversation text to your next prompt. The prior provider's native history stays separate and remains selectable.

An edit agent owns the workspace while it runs. Use plan mode for parallel reviewers; Kiln prevents a second editing agent from writing over the first agent's work. `:KilnProvider codex`, `:KilnModel default`, and `:KilnMode plan` also provide direct command access.

One Kiln window owns a project's saved sessions at a time. A second launch for the same project and state directory asks you to use sessions in the existing workspace, preventing concurrent history writes and competing editing agents. Different projects can run simultaneously; offline demos are exempt.

Inspect the selected accounts or explicitly start a provider's login flow:

```sh
kiln --accounts
kiln --login claude
kiln --login codex
```

Account separation is configured locally in `$KILN_STATE_DIR/providers.json`, or `.state/providers.json` when the state directory is not overridden:

```json
{
  "expected_email": "you@example.com",
  "claude_config_dir": "/absolute/path/to/private/claude-profile",
  "codex_home": "/absolute/path/to/private/codex-profile"
}
```

The profile paths are optional. A configured path selects that isolated CLI profile without changing the default profile or copying its credentials. When `expected_email` is set, streamed and native agent sessions require that account. A missing or different account is reported before the agent starts. Without a local profile, Kiln uses the normal CLI configuration.

`--login` runs only when explicitly requested. Claude's subscription login receives the expected email when configured. Codex uses device authorization; open its displayed link in the browser profile you intend to use. The selected account is checked again after login.

The bridge asks agents to explain the work they are doing, identify changed files, and report validation. Codex emits structured activity events; Claude additionally supports incremental text. Visibility is limited to the events and filesystem writes a provider exposes. Kiln does not display private internal reasoning or claim to observe hidden provider work.

Codex uses its workspace sandbox. Claude uses its normal edit permission mode. Kiln does not enable unrestricted permission bypasses. Actions that cannot be approved in a streamed run are reported as blocked; they do not receive silent blanket approval. Once a session exists, `Space t` opens its native provider interface to handle approvals and continue work. Press `Ctrl ]` to enter terminal normal mode, then `q` to close it. The next streamed turn resumes the same provider history; output from the native interface is not copied into the Kiln transcript.

## Offline preview and checks

```sh
./bin/kiln --demo .
./bin/kiln --doctor
make test
```

The demonstration is offline and does not invoke Codex or Claude. `--doctor` checks executable availability and versions, without signing in or sending a prompt. The automated tests use fixtures and temporary repositories, not paid model calls.

Requirements: macOS or Linux, Neovim 0.10 or newer, Python 3, Git, and at least one of the Codex or Claude CLIs. A wide terminal gives the sidebar enough room; approximately 140 columns or more is comfortable. Below 100 columns, the sidebar keeps a minimum usable width rather than an exact quarter of the screen.

## Local data

The launcher isolates Neovim's configuration, cache, data, and state under `.state/` in this checkout. That directory is excluded from Git. Set `KILN_STATE_DIR` to choose a different location. Provider processes receive the original XDG environment, with any explicitly configured provider profile applied, so editor isolation does not accidentally select another account or configuration.

No swap, backup, or persistent undo copies are created by the standalone editor configuration. Normal provider session storage remains under each provider's control.

## Development

- `bin/kiln` — standalone launcher and environment checks.
- `init.lua` — isolated Neovim configuration.
- `lua/kiln/` — workspace UI, theme, and live change review.
- `python/bridge.py` — provider process management and normalized event stream.
- `tests/` — offline provider and editor verification.

See [architecture](docs/architecture.md) for the event boundary and [provider references](docs/providers.md) for the protocols used.

See the [offline terminal preview](docs/preview.png) and [verification report](docs/verification.md) for the tested layout and behavior.
