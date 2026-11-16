# Kiln single-chat Elixir showcase

The recording is retained locally as `docs/kiln-one-chat.mp4`; generated media is excluded from Git. It documents the November 13 single-chat workflow, before the November 16 clarity improvements.

This 112.8-second recording follows one planning conversation into a justified dossier and a sequence of visible Elixir changes. The steps appear on the left, source stays in the middle, and the same chat continues on the right. The only added overlay shows actual input keys at the bottom right. The recording contains no added titles, captions, music, or simulated agent activity.

## Flow

1. Ask the real Codex agent to inspect the existing Elixir files and recommend the capacity and ordering contract. Continue the same planning chat to agree on negative capacity, alphabetical ties, and the operator report.
2. Codex proposes two justified outcomes: admit pending jobs, then show operator decisions. The second consumes the first outcome's ordered GO/HOLD groups. Kiln extracts the dossier and displays its steps on the left; implementation has not begun.
3. Run the plan. Codex edits the admission implementation and its tests while Kiln follows the actual files and highlights Git changes. The current step stays visible in the outline.
4. Press `Space h` while the admission agent is still running. Kiln stops the writer. Open `order.ex` and use deliberate Vim motions to replace the existing verbose comparator with `Enum.sort_by(&{-&1.priority, &1.title})`, then save.
5. Send a follow-up in the same chat. Codex receives the saved-file handoff, rereads the human edit, preserves it, and checks the admission behavior. After the step completes, Kiln automatically advances to the operator report and demo in that same conversation and checkout.
6. Finish with both outcomes implemented and `READY FOR REVIEW`. This status reports implementation completion; it does not claim human approval or perform a commit or merge.

## Pacing and provenance

Agent execution is accelerated 8×, with idle intervals removed and brief holds for readable results. Prompt entry and the complete Vim interruption remain at their recorded speed. The slow manual sequence includes navigation, the change inside parentheses, the method rename, saving, and the follow-up prompt. All 336 captured frames in that interval are retained at 1×, from 38.8 to 72.4 seconds in the film.

Every terminal cell, cursor position, and key label comes from the actual detached terminal capture. The image contains only the dark terminal area. There are no task-board or session-picker overlays, and no native application was brought to the front.

The comparator existed before the agent started. The agent was asked to preserve it for the operator's cleanup, so this is a real refactor of existing code. Its saved content remains byte-for-byte unchanged after the agent resumes and finishes the feature.

The installed Codex CLI uses `gpt-6-astra` throughout. The two planning turns, initial admission turn, resumed admission turn, and report turn share one native conversation and one working directory. No additional chat or worktree is created for an implementation step. Claude is not used in this recording.

A product fix made long provider status diagnostics compact and inspectable through Enter before this take. Full diagnostic text remains in the event history. Provider credentials and the regular Neovim configuration are unchanged; the recording uses the existing personal profile authorized by the user.

## Verification

At the time of recording, the product passed 97 Python tests and 2,151 Neovim assertions. The real agent's final checks report six scheduler tests and five board tests passing, plus a successful demo showing two GO jobs and one HOLD job. Native tool output records those commands and results.

An independent recording audit passes all 17 checks. It confirms one conversation across five native turns, planning before source edits, correct left-side active-step highlighting, visible changes across all five agent-edited files, interruption while the writer is active, a manual save while it is stopped, the subsequent editor handoff, unchanged manual content after resumption, and both steps reaching implementation completion. No capture errors were recorded.

The final silent H.264 video is 1872×840 at 30 fps. All 1,128 selected terminal frames match their source capture's ANSI content, cursor, key labels, phase, and chronological order. The complete video decodes successfully; the poster, an 18-frame montage, and full-size Vim frames were visually inspected.

Raw terminal frames, window geometry, native-session references, filesystem changes, handoff evidence, and edit provenance are retained under the ignored `.state/video/one-chat-flow/` directory. Earlier raw recordings remain as historical evidence of previous interface prototypes; the local recording demonstrates the current single-chat flow.

The fixture has a local baseline commit authored as WarrenBuffering. The implemented source remains available for review. No deployment, push, public posting, package installation, or integration is performed.
