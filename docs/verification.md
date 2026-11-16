# Verification

Verified on macOS on November 16, 2026 (America/Denver).

## Environment

- Neovim 0.10.1
- Python 3.14.6
- Git 2.50.1
- Codex CLI 0.160.1
- Claude Code 2.1.323

The installed `kiln` shortcut resolves to this checkout. `kiln --doctor` confirms the local dependencies without starting an agent.

## Automated coverage

Run `make test` from the checkout. Tests use temporary Git repositories, executable provider doubles, and real headless Neovim processes. No model requests are submitted.

The latest verification passed 97 Python tests and 2,553 Neovim assertions across 19 Lua suites. `make test` passed; the complete Lua suite was repeated after the final control and missing-evidence refinements. Logs are retained locally under `.state/clarity-test.log` and `.state/clarity-final-lua.log`.

The current suite exercises actual concurrent Codex/Claude protocol fixtures in separate Git worktrees, editing the same filename without changing the main checkout. It covers scoped takeover, hidden unsaved buffers, resumed human handoffs, committed-change visibility, restored worktree identity, native writer leases across windows, exact review snapshots, clean integration, and conflict preflight that leaves both checkouts unchanged.

Dossier tests exercise read-only planning, explicit proposal adoption, justified outcome/rationale/verification fields, explicit dependency reasons, per-outcome provider/model assignment, parallel independent dispatch, dependency gates through actual integration, provider-switch bindings, immutable dispatched definitions, editable future work, and preservation of an open dossier while agent events arrive. These checks validate the planning structure and execution behavior; they do not establish that every generated rationale is substantively good.

The suite covers provider event normalization; fragmented streams; native session continuation; Unicode provider handoffs; subagent activity; full tool-output navigation; account isolation; permission denials; literal argument handling; terminal restoration; editor layout; multiline drafts; live diffs; deleted, renamed, and untracked files; unusual filenames; symlinked buffer paths; preservation of unsaved edits; and native error diagnostics. Long provider status diagnostics have a width-aware preview, with their exact full text available through Enter. Narrow-pane tests exercise that inspection path for both providers while preserving normal statuses, actionable errors, and assistant explanations.

End-to-end cases run the actual Neovim interface through the Python bridge into fake Codex and Claude executables, change files on disk, and inspect the resulting editor buffers. Cancellation cases run stubborn provider and child processes under Neovim's real `jobstop()` lifecycle and verify that they are gone before its forced-kill deadline.

The dossier driver tests additionally verify persistent right-side authoring and outline views, selected-outcome highlighting, full-width inline Git changes, and background updates that preserve keyboard focus. A real Neovim-to-bridge fixture takes control, saves a correction, resumes the same native session, and verifies both automatic live-follow restoration and the unchanged human edit. Inline-change tests cover asynchronous cancellation, buffer/tick/disk races, fixed baselines, renames, additions, and preservation of unsaved buffers. Compact narration tests verify bounded current-turn explanations, event-linked inspection, relevant errors, and human-save notices; the full transcript remains available.

## Terminal checks

The offline workspace was inspected in detached 180×52 and 160×46 terminals. Startup, prompt access, Ctrl-S delivery, narrow layout, and clean exit were also checked in an 80×24 terminal. No application was brought to the front. The preview image is rendered from the actual offline terminal capture.

The new dossier board was inspected in an isolated 156×42 detached terminal. The captured view displays the goal, approach and rationale, outcomes, verification criteria, explicit dependency reason, and readiness states. Evidence is retained in `.state/dossier-qa.png`. This was a local layout fixture, not a model run.

## Validation boundary

Installed CLI flags were checked against local help and official provider documentation. Both existing personal CLI logins were verified against the account explicitly authorized by the user. Kiln now reuses those sessions with an email check; separate authentication is optional.

The earlier November 12 validation included four live turns through the real Neovim UI and Python bridge in a disposable Git fixture:

| Provider | Selected model | Verified behavior |
| --- | --- | --- |
| Codex | `gpt-6-astra` | File edit, continuation using the same native session, tool/file events, assistant updates, live diff |
| Claude | `sonnet` | Provider handoff, file edit, continuation using the same native session, incremental text, tool/file events, live diff |

Each turn completed successfully with the requested disk content displayed in the code buffer. The sidebar width and prompt focus were preserved. Both resumed turns retained their original provider session IDs. Normalized transcripts and results are retained under `.state/live-verification/`.

Narration timing depends on provider behavior: assistant updates arrived before the edit in three of the four turns. Claude's initial turn exposed Read/Edit activity before the file change and narrated its result afterward. This check does not establish that every provider turn will produce explanatory text before every edit. Existing Codex plugin configuration also emitted unrelated Notion authentication diagnostics; the coding turns still completed successfully.

The probe's `visible_narration_before_disk` field samples only when an event arrives, before the deferred UI refresh. It does not measure when rendered narration becomes visible and is not used as evidence of screen timing.

The existing provider logins and normal Neovim configuration were left intact. No deployment, push, public posting, package installation, or API-key purchase was performed. The live checks used the authorized personal subscription sessions. Linux portability has not been exercised on a Linux host.

## Recorded dossier and parallel worktrees

An earlier November 13 prototype recording used the real installed Codex and Claude CLIs with the user's explicit authorization. A read-only Codex planner proposed two independent Elixir implementations and one dependent integration deliverable. The operator adopted the proposal and clarified its shared contract before dispatching Codex and Claude into separate worktrees.

The first implementation jobs overlap for approximately 23 seconds; the resumed refinement jobs also overlap. Both providers make real file changes. The main checkout stays unchanged until explicit review and integration. The final deliverable starts from a base containing both reviewed implementations.

The recorded manual refactor replaces an existing comparator with `Enum.sort_by/2`. The same native Codex session receives the automatic editor handoff, rereads the human edit, preserves it byte-for-byte, and adds a regression in another file. The preserved edit reaches the integrated main checkout.

All three worktree snapshots receive review fingerprints before integration with no writer running. The integrated fixture is clean. Its scheduler, board, and integration suites pass 9, 6, and 2 tests respectively, and the runnable demo exits successfully. Ten independent audit tests also pass, including 66 capacity/input combinations, whitespace isolation in board rows, and a separate demo subprocess check.

Claude's Bash test commands were permission-blocked. Its real Write/Edit changes succeeded; the six board tests were verified on camera by the operator and subsequently by the final Codex task. Existing unrelated Notion authentication diagnostics did not prevent Codex's coding work. The recording omits a failed initial keyboard shortcut and its recovery before any planner work; the actual native planning prompt excludes the accidental unsaved paste.

Raw terminal frames, native-session references, filesystem evidence, review fingerprints, edit provenance, and the independent audit for that earlier prototype are retained under `.state/video/dossier-flow/`.

## Recorded single-operator dossier driver

The earlier driver prototype recording uses a persistent right-side dossier and a single wide code pane. A human-authored brief defines two justified outcomes: admission, then an operator report/demo that consumes the integrated admission contract. The real Codex and Claude CLIs implement these outcomes in separate worktrees, sequentially. The operator drives outcome selection, handcoding, review, and integration through actual editor input.

The left code area stays 116 columns wide and the right panes 39 columns, with four ordinary windows. Dossier-bound changes appear as real Git hunks inline. The selected outcome stays highlighted; a saved manual comparator refactor is acknowledged and preserved by the same resumed Codex session. The six scheduler tests and three board tests pass. Both reviewed outcomes are integrated, and the independent nine-test audit passes against main, including 66 capacity/input combinations and an actual demo subprocess.

The capture resumes the same persisted session after fixing the compact narration layout. All source bytes match across that restart, and no implementation turn is replayed. Claude's tests are run by the operator; its native log includes one successful read-only shell discovery command. The filmed final demo runs from the integrated task worktree, while the independent audit runs the corresponding main-checkout demo. Evidence is retained under `.state/video/driver-flow/`.

## Continuous planning conversation

The default workflow now begins with one planning chat. A complete dossier proposal appears on the left without creating another chat. Running the plan sends one implementation step at a time through the same provider-native conversation and checkout; successful, explicitly reported completion advances the sequence. Implementation reports remain distinct from human review. The default flow performs no automatic commit or integration.

The actual Neovim-to-bridge integration test runs the same scenarios through offline Codex and Claude protocol fixtures. It verifies multiple planning turns, automatic dossier extraction, plan-to-edit CLI arguments, one native ID and working directory, sequential dispatch, live code changes, left-side highlighting, missing completion reports, failed turns, and code/plan handoffs. Pausing after a native completion event but before process exit prevents advancement. A second pause cancels a queued interruption. Submitted text is captured exactly while later unsent text remains in the prompt. An unsent message also pauses automatic advancement.

Nested Neovim restart checks verify restored conversation identity, draft text, history, and completed/pending step state, with no automatic provider request on reopen. Unit checks cover queued callback invalidation, deferred proposals, editable definitions and retained revision history, dependency order, and ordinary chat continuation at the first unfinished step.

Detached visual checks at 156×42, 160×46, and 80×24 show the left step list, central source, and right chat without overlap or floating panels. These are explicitly offline layout fixtures; no agent activity or live provider run is claimed for those checks. Screenshots and geometry are retained in `.state/chat-layout/`.

## Recorded single-chat Elixir workflow

The November 13 local recording uses the real installed Codex CLI with `gpt-6-astra` and the existing personal profile explicitly authorized by the user. Two actual planning turns establish the contract before a dossier appears on the left. Its two justified steps are admission and an operator report that consumes the ordered GO/HOLD groups. Planning, initial implementation, interruption, resumed implementation, and the second step share one Kiln session, one native provider conversation, and one working directory.

The operator presses `Space h` while the admission writer is active, then replaces the existing comparator in `order.ex` with a tuple sort through slow Vim motions. Filesystem evidence records that save while the provider is stopped. The next native prompt includes the editor handoff; the agent rereads the edit and preserves its exact saved bytes through completion. Automatic continuation starts the report step after admission succeeds. The resulting source remains uncommitted and the workflow ends at `READY FOR REVIEW`, distinct from human approval or integration.

The independent provenance audit passes all 17 checks. All five agent-edited files appear in the live code pane while an implementation turn is active. The left outline occupies 28 columns, the middle source 81, and the right chat 45 in the 156×42 terminal. Across 482 sampled outline states, the highlighted step matches the actual current step, with no capture errors. Native tool results confirm six scheduler tests and five board tests passing with zero failures. The demo succeeds and prints two GO rows, Atlas and Beacon, followed by one HOLD row, Cargo.

Raw frames, window geometry, native-session evidence, filesystem history, the preserved manual hash, and the audit are retained in `.state/video/one-chat-flow/`, including `verification.json`. The 112.8-second film accelerates agent execution 8× with brief readability holds and retains prompt entry and the full manual interruption at recorded speed. All 336 captured frames of that interruption remain at 1×. Render QA verifies exact source fidelity and chronological order for all 1,128 selected terminal frames, a complete video decode, and the silent 1872×840 H.264 output at 30 fps. The poster, an 18-frame montage, and full-size Vim frames were visually inspected. See [recording notes](video-notes.md) for its pacing and scope. Earlier prototype evidence above remains historical and is not the source of this film's agent activity.


## November 16 clarity pass

The continuous workflow now has one current-action and control strip, a contextual Start/Take over/Resume/Review action, a compact evidence-based checklist, grouped inspectable activity, and folded accepted plans. Explanations link to their subsequent changed files. Newest observed edits receive stronger marks while earlier Git changes remain quiet. Vim navigation pins the view without stopping the writer.

The real Neovim-to-bridge offline integration suite passes 260 assertions across Codex and Claude protocol fixtures. It exercises planning, extraction, implementation, actual tool-output evidence, active cancellation, ownership transfer, saved-file resumption, failed checks and retries, change navigation, grouped inspection, and review navigation. Additional regression checks verify stale results after post-completion manual saves, concurrent writer approval guards, and mode-sensitive review snapshots.

The complete product suite includes 59 evidence assertions, 72 conversation projection assertions, 175 action-strip assertions, 125 live-code assertions, and 516 checklist assertions. Source edits make earlier check evidence stale; absent verification remains unresolved. No model requests were submitted for this clarity pass.

Detached terminal checks inspect 14 states at 156×42 and 80×24, including planning, ready, running, stopping, human control, resuming, review, and latest-change emphasis. Actual `f(` input pins the view. The current screenshot is an explicitly offline layout fixture. Geometry, captures, and report are retained locally under `.state/clarity-layout/`; no application was brought to the front.
