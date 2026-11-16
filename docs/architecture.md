# Architecture

## Visible execution and control

`presentation.lua` derives one current-action strip from the actual process, workflow, and editor state. The contextual action starts, takes over, resumes, or opens review. A cancellation request remains STOPPING while a provider job exists; human control is shown only after it exits. Saved handoff paths remain visible until the resumed provider turn acknowledges them.

`conversation.lua` renders a readable projection of the preserved event history. It folds only the dossier matching the accepted plan and groups consecutive commands, file events, and diagnostics into inspectable activity entries. Errors remain visible. Explanations link to the subsequent changed files through `gf`; neither messages nor source edits are fabricated by the display.

`evidence.lua` scopes changed files and command results to their dossier definition. Recognized test summaries come only from actual normalized tool output, never assistant messages. Failed and interrupted checks remain inspectable. Relevant file changes and manual saves mark earlier checks stale; an actual rerun replaces those results. This applies after implementation completion as well as during execution. Revision changes invalidate evidence for reset steps.

The left checklist renders compact outcomes and their observed file/check progress. Enter opens the full rationale and verification contract. Review groups actual files and checks by outcome, includes unrelated manual changes, and opens the corresponding diff or complete command result. Explicit file approval requires an idle workspace and saved code, and binds to exact regular-text bytes and mode. Subsequent source or mode changes invalidate approval; unsupported binary and symlink content cannot be approved through the text view.

Live source highlighting preserves the Git baseline while comparing successive observed versions to emphasize the newest edit. Earlier changes use quieter marks. Actual Vim navigation pins the code view without stopping the agent; pending refreshes cannot move the cursor after that handoff. `]c` and `[c` navigate real change anchors, including deletions. Saved human versions become the next observed baseline so resumed agent edits do not mislabel the manual work.

Kiln's default workflow is one continuous planning and implementation conversation. Neovim owns the chat, editable dossier, source buffers, and progress display. A workflow controller sends one dossier step at a time through the same provider session and workspace. The Python bridge owns provider processes and normalized event streams.

```text
Neovim workspace
  ├── left: complete dossier outline or editable Markdown
  ├── center: source and actual inline Git changes
  ├── right: one conversation and its message prompt
  ├── workflow controller: plan / ready / run / pause / review
  └── current-checkout context: files, following, human handoffs

Provider bridge (one process per turn)
  ├── Codex: exec / exec resume --json
  └── Claude: --print --output-format stream-json / --resume

Optional independent tasks
  ├── per-task Git worktrees and provider sessions
  └── Python backend: create / inspect / integrate
```

Before a valid dossier exists, the interface shows code and chat. A completed planning proposal adds the left step outline without replacing the source pane or starting implementation. The default sequence stays in the current checkout; it does not create worktrees or require integration after every step.

## Conversational planning

`lua/kiln/workflow.lua` initializes the default session in planning mode. Ordinary messages retain the same visible chat and native provider ID. The turn instructions ask the agent to inspect the repository, discuss missing decisions, and propose the smallest useful set of justified outcomes. Planning uses Codex's read-only sandbox or Claude's plan permission mode.

A coherent response includes the complete dossier in a fenced Markdown block. After the actual provider process exits successfully, the controller extracts and validates the current turn's proposal. `lua/kiln/planning.lua` applies it to the saved dossier and any clean editor buffer without changing keyboard focus. Unsaved code or dossier edits defer the proposal; the held proposal must be resolved before an older plan can run.

`lua/kiln/dossier.lua` parses the shared approach and its rationale, followed by named steps with `Outcome`, `Why`, and `Verify`. Dependencies require explicit IDs and a concrete reason. Parsing rejects invalid IDs, duplicate steps, missing fields, unknown dependencies, and cycles. The sequential controller also requires prerequisites to precede their consumers. Structural validity does not prove that the reasoning or proposed checks are substantively good.

Planning and implementation modes are reapplied on each native-session resume. Moving from planning to implementation changes provider permissions for that turn while preserving conversation continuity. A user can return to planning in the same chat at any point.

## Sequential implementation

`/run`, `/resume`, `Space N`, and `:KilnRun` explicitly authorize the sequence. The controller chooses the first unfinished step in document order and sends the shared brief, current step, revision, and execution instructions to the same session. Internal dispatch is recorded as a notice in the visible conversation rather than a fabricated user message.

The agent is instructed to explain meaningful changes, identify files, run the specified checks, and stop if a decision, permission, or failed check blocks completion. It must not execute later steps within that turn. A standalone completion marker identifies the current step; it is hidden from normal chat display and remains available in the underlying event record.

A step advances only after the provider process has exited successfully and the final assistant response from that turn reports the matching completion marker. A successful process exit without the marker pauses the sequence for further conversation. A failed or interrupted turn cannot complete a step. Completion means agent-reported implementation, not human review, integration, or independent proof of passing checks.

The next dispatch is deferred briefly and guarded by workflow epoch, revision, session identity, pause state, and local edit checks. The controller never runs multiple steps simultaneously. After the last step, it disables automatic continuation and enters `review`. It does not commit, merge, push, publish, or deploy.

Runtime metadata lives on `session.workflow`: phase, current step ID, per-step status and fingerprint, plan revision, continuation epoch, held proposal, and prior records. The current-turn boundary excludes completion markers and proposals from older messages. These controls keep a late result from an interrupted or superseded turn from advancing a revised plan.

## Interruptions and edits

`/pause` and `Space x` invalidate automatic continuation and request provider cancellation. Submitting a new message during implementation stops the old turn before the new direction is sent. `Space h` also pauses file following and waits for the selected writer to stop before handing control to the code pane. Entering or modifying a source buffer during implementation requests the same takeover.

The dossier remains editable. Opening its editor pauses the sequence; saving a revised definition increments the plan revision and resets the changed step and later progress. A changed shared brief resets progress from the beginning. Earlier unchanged steps remain implemented. Old records are retained in workflow history, so revised requirements are not silently presented as already complete.

Neovim's modified-buffer checks block implementation while unsaved source or dossier edits remain. Actual `BufWritePost` events record saved human files, advance their context version, and invalidate optional review snapshots. A follow-up includes newer file paths and asks the provider to reread and preserve unrelated manual edits. That handoff is acknowledged only after successful completion. Sending an edit turn after handcoding restores file following.

Reopening a saved session disables automatic execution and presents interrupted work as paused. A user must explicitly resume. Runtime process handles and scheduled callbacks are not restored.

## Pane rendering and code visibility

`lua/kiln/workflow_view.lua` renders all numbered steps from the accepted dossier and statuses from the selected chat's runtime. The actual current step owns the highlight. Inspecting another step changes its detail text without moving execution. Completed steps are labeled `IMPLEMENTED`; final workflow state is `READY FOR REVIEW`. Long plans remain available in the scrollable buffer rather than being truncated to the window height.

The right pane retains the full conversation across planning, implementation, interruptions, and provider changes. Tool previews are bounded, with access to the original event. Provider text, file events, and test output are displayed as received; Kiln does not expose private reasoning or invent narration for hidden activity.

Only the selected workspace follows file events into the code pane. `changes.show_live` opens the actual editable file without adding a split. Neovim extmarks display additions and changed lines against the Git baseline, with deletion markers for removed lines. A deleted file falls back to side-by-side diff review so its old content remains inspectable. Explicit review remains available through `Space d`.

Inline highlights are computed from real baseline and current-file content. Asynchronous results are discarded if context, request, buffer, changed tick, disk signature, or window ownership no longer matches. Live updates do not overwrite modified buffers. External writes can reload clean buffers; unsaved conflicts require reconciliation. Focus remains with the user.

Each distinct workspace root owns a watcher, file attribution, human-edit versions, following state, and saved code position. Sessions sharing a root share that context. Main-checkout changes compare against Git HEAD. Optional isolated tasks compare against their fixed starting commit, keeping committed edits visible alongside staged, unstaged, and untracked files. A changed-file list is not proof that an agent authored every change.

## Provider process boundary

The editor starts the Python bridge with an argument list and sends prompt text over standard input. The bridge starts the provider the same way, avoiding shell interpretation of prompts, paths, models, and session IDs. Normalized JSON Lines events identify native sessions, messages, tool calls, files, usage, errors, and completion. Stable event IDs update streamed entries without duplication.

Codex runs `exec` or `exec resume --json`; Claude runs its print/stream-JSON interface with `--resume` when a native ID exists. Mode selection controls each turn's sandbox or permission mode. Kiln does not enable unrestricted permission bypasses. A permission-blocked streamed action stays visible and prevents successful turn completion.

Each provider owns its native conversation ID. In the default workflow, switching providers pauses implementation but preserves the visible chat and current workspace. The session stores provider-specific native IDs and models. A conversation handoff accompanies the next prompt, and switching back resumes that provider's own ID. Model overrides are passed to the CLI; omitting an override retains its configured default.

The bridge holds a kernel writer lease for the canonical workspace path, independent of the state directory. A second window or symlink alias cannot start another editing owner there. Different worktrees can each have a writer, and read-only planning is separate. Native provider takeover inherits the writer lease until it exits. Stopping a turn terminates its process group and escalates cancellation when necessary so children do not outlive a reported stop.

The launcher also holds an advisory lock for the canonical project and state directory for Neovim's lifetime. A second launch cannot overwrite that project's saved history. The operating system releases the lock on exit. Empty lock files remain to avoid unlink races; their existence does not indicate a running process. Offline demos neither persist sessions nor run providers.

## Optional task worktrees

The advanced task interface remains separate from the default single-chat sequence. `:KilnNew` creates a task worktree and branch through `python/workspaces.py`, starting at committed HEAD. Dirty main-checkout files are not copied. Ownership metadata records the repository, Git common directory, worktree path, branch, and baseline.

Before a provider runs in an isolated task, the backend verifies ownership, branch identity, and ancestry. Missing or changed worktrees are reported rather than silently recreated. Different tasks can run concurrently, with a single editing owner per worktree. Task reviewers can share their task's context in plan mode.

The earlier dossier dispatcher still binds independently dispatched deliverables to task sessions. It supports per-step provider/model assignment and integration-gated dependencies. Dispatched definitions remain immutable in that interface; corrections are new deliverables. Its right-side task rail and optional overview are not the primary single-chat layout.

## Optional review and integration

`:KilnReviewed` requires saved buffers and no running task work. For isolated tasks, the backend fingerprints HEAD, Git changes, and untracked contents. New turns, human saves, detected external edits, or a changed fingerprint invalidate the review.

`:KilnIntegrate` explicitly integrates one reviewed isolated task into a clean, idle main checkout. It validates ownership and the exact reviewed fingerprint, acquires an integration lock and writer leases for source and destination, and previews the merge with `git merge-tree --write-tree`. Conflicts leave both working trees unchanged. A successful merge checkpoints reviewed content without replacing the working files through a temporary index, then merges locally with hooks and signing disabled for the managed operation.

Integration blocks competing editor saves to the involved checkouts and finishes outstanding workspace operations before closing. Unrelated external Git commands do not honor Kiln's leases. Task branches and worktrees remain available afterward; no automatic deletion, push, publication, or deployment occurs.

## Persistence and isolation

Version-2 state stores the visible conversation, provider-specific native sessions, accepted dossier, workflow progress and revision history, optional task metadata, and human-edit acknowledgments. The editable Markdown lives in the state directory's `dossiers/` folder. Context state is keyed by canonical workspace root. Existing task histories remain available when the default planning chat is introduced; files and prior conversations are not relocated.

The standalone launcher changes Neovim's configuration and XDG paths only for its process. It does not modify the user's normal editor installation. The bridge restores the original XDG environment before starting a provider. Optional `providers.json` settings select isolated provider directories or require an expected account; credentials are never copied or switched implicitly.

Kiln has no hosted server or service database. Provider CLIs perform their normal network access when the user sends a message or explicitly requests login.
