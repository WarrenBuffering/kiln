#!/usr/bin/env python3
"""Stream installed coding CLIs into Kiln's provider-neutral JSONL protocol.

Only the standard library is required. No credentials are read or stored by
Kiln: the selected provider CLI owns authentication and session persistence.
"""

from __future__ import annotations

import argparse
import codecs
import contextlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
from typing import Any, Callable

from accounts import enforce_account, provider_environment
from leases import writer_lock


INSTRUCTIONS = """You are working in Kiln, a live Neovim coding workspace.
Give concise, user-facing progress updates before making changes and when you
finish a meaningful step. Name the files and describe the reason for changes.
The user can see edits as they happen. Preserve unrelated and unsaved user work.
Follow the repository's instructions. Report tests actually run and any limits.
Never deploy, publish, submit to a store, or push branches from this session.
If permission prevents an action, explain the exact blocked action. Do not try
to bypass a denied permission. Do not claim unperformed work is complete.

User request:
"""

# Neovim jobstop() kills its job after roughly two seconds. Reap our detached
# provider group before that deadline, while the bridge is still alive.
STOP_GRACE_SECONDS = 0.75


def text_value(value: Any) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(part if isinstance(part, str) else text_value(part.get("text"))
                         for part in content if isinstance(part, str) or
                         (isinstance(part, dict) and part.get("type") == "text"))
    return text_value(content)


def validate_selection(provider: str, model: str, session: str, mode: str) -> None:
    if provider not in ("codex", "claude") or mode not in ("edit", "plan"):
        raise ValueError("Unsupported provider or mode")
    if any("\x00" in value or "\n" in value for value in (model, session)):
        raise ValueError("Model and session must be single-line values")
    if session.startswith("-"):
        raise ValueError("Session IDs cannot start with a dash")


def build_command(provider: str, model: str = "", session: str = "",
                  mode: str = "edit") -> list[str]:
    """Build argv without invoking a shell; defaults stay with the installed CLI."""
    validate_selection(provider, model, session, mode)
    if provider == "codex":
        sandbox = "read-only" if mode == "plan" else "workspace-write"
        cmd = [os.environ.get("KILN_CODEX_BIN", "codex"), "exec"]
        if session:
            cmd.append("resume")
        cmd += ["--json", "--skip-git-repo-check", "-c", 'approval_policy="never"',
                "-c", f'sandbox_mode="{sandbox}"']
        if model:
            cmd += ["--model", model]
        if session:
            cmd.append(session)
        return cmd + ["-"]
    cmd = [os.environ.get("KILN_CLAUDE_BIN", "claude"), "-p", "--output-format",
           "stream-json", "--verbose", "--include-partial-messages",
           "--forward-subagent-text", "--permission-mode",
           "plan" if mode == "plan" else "acceptEdits", "--permission-prompts",
           "none", "--no-chrome"]
    if model:
        cmd += ["--model", model]
    if session:
        cmd += ["--resume", session]
    return cmd


def build_interactive_command(provider: str, cwd: str, model: str = "",
                              session: str = "", mode: str = "edit") -> list[str]:
    """Explicit native terminal takeover, with provider-owned approval prompts.

    No prompt is supplied here, so opening the terminal never submits a task.
    Kiln normally uses this to resume a session that needs human approval.
    """
    validate_selection(provider, model, session, mode)
    if provider == "codex":
        cmd = [os.environ.get("KILN_CODEX_BIN", "codex")]
        if session:
            cmd += ["resume", "--include-non-interactive", session]
        cmd += ["--cd", str(Path(cwd).resolve()), "--sandbox",
                "read-only" if mode == "plan" else "workspace-write",
                "--ask-for-approval", "on-request"]
    else:
        cmd = [os.environ.get("KILN_CLAUDE_BIN", "claude")]
        if session:
            cmd += ["--resume", session]
        cmd += ["--permission-mode", "plan" if mode == "plan" else "acceptEdits",
                "--no-chrome"]
    if model:
        cmd += ["--model", model]
    return cmd


class Normalizer:
    """Normalize full records and token deltas into stable, updatable records."""

    def __init__(self, provider: str, emit: Callable[[dict], None]):
        self.provider = provider
        self.emit = emit
        self.completed = False
        self.failed = False
        self.blocked = False
        self.session = ""
        self.messages: dict[str, str] = {}
        self.tools: dict[str, dict] = {}
        self.streams: dict[str, dict] = {}
        self.last_message = ""
        self.counter = 0

    def unique_id(self, prefix: str) -> str:
        self.counter += 1
        return f"{prefix}-{self.counter}"

    def message(self, identity: str, text: str, parent: str | None = None) -> None:
        if self.messages.get(identity) == text or not text:
            return
        self.messages[identity] = text
        if not parent:
            self.last_message = identity
        event = {"type": "message", "id": identity, "role": "assistant", "text": text}
        if parent:
            event.update(parent_id=parent, agent="subagent")
        self.emit(event)

    def tool(self, identity: str, name: str, text: str, status: str,
             parent: str | None = None, **extra: Any) -> None:
        record = {"type": "tool", "id": identity, "name": name,
                  "text": text, "status": status, **extra}
        if parent:
            record.update(parent_id=parent, agent="subagent")
        if self.tools.get(identity) != record:
            self.tools[identity] = record
            self.emit(record)

    def error(self, text: str, **extra: Any) -> None:
        self.emit({"type": "error", "text": text, **extra})

    def feed(self, record: Any) -> None:
        if not isinstance(record, dict):
            self.error("Provider emitted a non-object JSON record")
            return
        session = record.get("session_id") if self.provider == "claude" else record.get("thread_id")
        if session and session != self.session and not record.get("parent_tool_use_id"):
            self.session = session
            self.emit({"type": "session", "id": session})
        try:
            if self.provider == "codex":
                self.codex(record)
            else:
                self.claude(record)
        except (AttributeError, TypeError, KeyError) as error:
            self.failed = True
            self.error(f"Unexpected {self.provider} event shape ({record.get('type', 'unknown')}): {error}")

    def usage(self, usage: dict) -> None:
        self.emit({"type": "usage", "input_tokens": usage.get("input_tokens", 0),
                   "output_tokens": usage.get("output_tokens", 0),
                   "cached_input_tokens": usage.get("cached_input_tokens", usage.get("cache_read_input_tokens", 0))})

    def codex(self, record: dict) -> None:
        kind = record.get("type", "")
        if kind == "turn.started":
            self.emit({"type": "status", "text": "Working", "status": "running"})
        elif kind == "turn.completed":
            self.completed = True
            self.failed = False
            self.usage(record.get("usage") or {})
        elif kind in ("turn.failed", "error"):
            if kind == "turn.failed":
                self.failed = True
            error = record.get("error") or record.get("message") or record
            self.error(text_value(error.get("message", error) if isinstance(error, dict) else error))
        elif kind.startswith("item."):
            item = record.get("item") or {}
            identity = item.get("id") or self.unique_id("item")
            item_type = item.get("type")
            status = "done" if kind == "item.completed" else "running"
            if item.get("status") in ("failed", "error") or item.get("exit_code", 0) not in (None, 0):
                status = "error"
            if item_type == "agent_message":
                self.message(identity, item.get("text", ""))
            elif item_type == "command_execution":
                body = item.get("command", "")
                if item.get("aggregated_output"):
                    body += "\n" + item["aggregated_output"]
                if item.get("exit_code") is not None:
                    body += f"\n[exit {item['exit_code']}]"
                self.tool(identity, "Shell", body, status)
            elif item_type == "file_change":
                changes = item.get("changes") or []
                self.tool(identity, "Files", "\n".join(
                    f"{change.get('kind', 'update')}: {change.get('path', '')}"
                    for change in changes), status)
                if status == "done":
                    for change in changes:
                        if change.get("path"):
                            self.emit({"type": "file", "path": change["path"],
                                       "action": change.get("kind", "update")})
            elif item_type == "mcp_tool_call":
                body = text_value(item.get("arguments"))
                result = item.get("result") or item.get("error")
                if result:
                    body += "\n" + text_value(result)
                self.tool(identity, f"{item.get('server', 'MCP')}/{item.get('tool', 'tool')}", body, status)
            elif item_type == "web_search":
                self.tool(identity, "Search", item.get("query", ""), status)
            elif item_type == "todo_list":
                self.tool(identity, "Plan", "\n".join(
                    ("[x] " if todo.get("completed") else "[ ] ") + todo.get("text", "")
                    for todo in item.get("items", [])), status)
            elif item_type in ("collab_agent_tool_call", "collab_tool_call"):
                body = item.get("prompt", "")
                if item.get("agents_states"):
                    body += "\n" + text_value(item["agents_states"])
                self.tool(identity, item.get("tool", item.get("tool_name", "Agent")), body, status)
            elif item_type == "error":
                self.error(item.get("message", "Provider tool error"))

    def claude_tool(self, block: dict, parent: str | None) -> None:
        identity = block.get("id") or self.unique_id("tool")
        old = self.tools.get(identity, {})
        inputs = block.get("input") or {}
        name = block.get("name", old.get("name", "Tool"))
        text = text_value(inputs)
        self.tool(identity, name, text, old.get("status", "running"), parent,
                  path=inputs.get("file_path", inputs.get("notebook_path", "")) if isinstance(inputs, dict) else "")

    def claude(self, record: dict) -> None:
        kind = record.get("type")
        parent = record.get("parent_tool_use_id")
        if kind == "stream_event":
            event = record.get("event") or {}
            event_type = event.get("type")
            stream_key = parent or "main"
            if event_type == "message_start":
                message = event.get("message") or {}
                self.streams[stream_key] = {"id": message.get("id") or self.unique_id("message"), "blocks": {}}
            stream = self.streams.get(stream_key)
            if not stream:
                return
            index = event.get("index", 0)
            if event_type == "content_block_start":
                block = dict(event.get("content_block") or {})
                stream["blocks"][index] = block
                if block.get("type") == "tool_use":
                    self.claude_tool(block, parent)
            elif event_type == "content_block_delta":
                delta = event.get("delta") or {}
                block = stream["blocks"].setdefault(index, {"type": "text", "text": ""})
                if delta.get("type") == "text_delta":
                    block["text"] = block.get("text", "") + delta.get("text", "")
                elif delta.get("type") == "input_json_delta":
                    block["partial_json"] = block.get("partial_json", "") + delta.get("partial_json", "")
            elif event_type == "content_block_stop":
                block = stream["blocks"].get(index, {})
                if block.get("type") == "tool_use" and block.get("partial_json"):
                    try:
                        block["input"] = json.loads(block["partial_json"])
                    except json.JSONDecodeError:
                        pass  # A complete assistant record may supply the input next.
                    self.claude_tool(block, parent)
            blocks = [stream["blocks"][i] for i in sorted(stream["blocks"])]
            self.message(stream["id"], content_text(blocks), parent)
        elif kind == "assistant":
            message = record.get("message") or {}
            identity = message.get("id") or record.get("uuid") or self.unique_id("message")
            self.message(identity, content_text(message.get("content", [])), parent)
            for block in message.get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    self.claude_tool(block, parent)
            if record.get("error"):
                self.error(text_value(record["error"]))
        elif kind == "user":
            content = (record.get("message") or {}).get("content", [])
            if not isinstance(content, list):
                return
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                identity = block.get("tool_use_id") or self.unique_id("tool")
                old = self.tools.get(identity, {})
                result = content_text(block.get("content", ""))
                body = old.get("text", "") + ("\n" if old.get("text") and result else "") + result
                self.tool(identity, old.get("name", "Tool"), body,
                          "error" if block.get("is_error") else "done", parent, path=old.get("path", ""))
                if not block.get("is_error") and old.get("path") and old.get("name") in ("Edit", "Write", "NotebookEdit"):
                    self.emit({"type": "file", "path": old["path"], "action": "update"})
        elif kind == "result":
            self.completed = True
            self.failed = bool(record.get("is_error")) or record.get("subtype", "success").startswith("error")
            result = record.get("result", "")
            if result:
                identity = self.last_message or self.unique_id("result")
                self.message(identity, result)
            if self.failed:
                self.error(content_text(record.get("errors")) or result or record.get("subtype", "Provider failed"))
            for denial in record.get("permission_denials", []):
                self.permission_denied(denial)
            self.usage(record.get("usage") or {})
        elif kind == "system":
            subtype = record.get("subtype", "")
            if subtype == "permission_denied":
                self.permission_denied(record)
            elif subtype in ("task_started", "task_progress", "task_notification"):
                identity = record.get("task_id") or record.get("tool_use_id") or self.unique_id("agent")
                state = record.get("status", "running")
                self.tool(identity, "Agent", record.get("description", record.get("summary", "Agent working")),
                          "done" if state in ("completed", "success") else "error" if state in ("failed", "stopped") else "running", parent)
            elif subtype in ("warning", "error"):
                self.emit({"type": "status" if subtype == "warning" else "error",
                           "text": record.get("message", text_value(record))})
        elif kind == "rate_limit_event":
            info = record.get("rate_limit_info") or {}
            if info.get("status") in ("rejected", "allowed_warning"):
                self.emit({"type": "status", "text": "Provider rate limit: " + text_value(info)})

    def permission_denied(self, denial: dict) -> None:
        self.blocked = True
        identity = denial.get("tool_use_id", denial.get("id")) or self.unique_id("denial")
        name = denial.get("tool_name", denial.get("name", "Tool"))
        self.tool(identity, name, "Permission denied: " + text_value(denial.get("tool_input", denial.get("input", denial))),
                  "error", blocked=True)
        self.error(f"{name} needs permission. Open the provider's interactive CLI to approve it, then resume this session.", blocked=True)


class JsonLines:
    """Incremental UTF-8 and JSONL framing, including final unterminated lines."""

    def __init__(self, callback: Callable[[str], None]):
        self.callback = callback
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = ""

    def feed(self, chunk: bytes, final: bool = False) -> None:
        self.pending += self.decoder.decode(chunk, final=final)
        lines = self.pending.split("\n")
        self.pending = lines.pop()
        for line in lines:
            if line.strip():
                self.callback(line.rstrip("\r"))
        if final and self.pending.strip():
            self.callback(self.pending)
            self.pending = ""
        if len(self.pending) > 16 * 1024 * 1024:
            raise ValueError("Provider output exceeded the 16 MiB JSON line limit")




def run(args: argparse.Namespace, prompt: str, emit: Callable[[dict], None]) -> int:
    normalizer = Normalizer(args.provider, emit)
    process = None
    stopped_at = None
    old_handlers = {}
    stderr_tail: list[str] = []
    leases = contextlib.ExitStack()

    def stop(signum: int, _frame: Any) -> None:
        nonlocal stopped_at
        if stopped_at is None:
            stopped_at = time.monotonic()
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def stdout_line(line: str) -> None:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            normalizer.error("Unrecognized provider output: " + line[:2000])
            return
        normalizer.feed(record)

    def stderr_line(line: str) -> None:
        stderr_tail.append(line)
        del stderr_tail[:-12]
        emit({"type": "status", "text": line})

    exit_code = 1
    try:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            old_handlers[sig] = signal.signal(sig, stop)
        command = build_command(args.provider, args.model, args.session, args.mode)
        if not Path(args.cwd).is_dir():
            raise ValueError(f"Workspace does not exist: {args.cwd}")
        if not prompt.strip():
            raise ValueError("Prompt is empty")
        leases.enter_context(writer_lock(args.cwd, args.mode))
        environment = provider_environment()
        enforce_account(args.provider, env=environment)
        if stopped_at is not None:
            raise ValueError("Stopped before the provider started")
        process = subprocess.Popen(command, cwd=args.cwd, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True, bufsize=0,
                                   env=environment)
        streams = {process.stdout: JsonLines(stdout_line), process.stderr: JsonLines(stderr_line)}
        # Use a selector for stdin too: large prompts must not deadlock a child
        # that emits startup diagnostics before it reads the request.
        pending_input = memoryview((INSTRUCTIONS + prompt).encode("utf-8"))
        with selectors.DefaultSelector() as selector:
            for pipe in streams:
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ)
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE)
            while selector.get_map():
                if stopped_at is not None and time.monotonic() - stopped_at > STOP_GRACE_SECONDS:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                for key, _events in selector.select(0.1):
                    pipe = key.fileobj
                    if pipe is process.stdin:
                        try:
                            size = os.write(pipe.fileno(), pending_input[:65536])
                            pending_input = pending_input[size:]
                        except (BrokenPipeError, OSError):
                            pending_input = memoryview(b"")
                        if not pending_input:
                            selector.unregister(pipe)
                            pipe.close()
                    else:
                        try:
                            chunk = os.read(pipe.fileno(), 65536)
                        except BlockingIOError:
                            continue
                        streams[pipe].feed(chunk, final=not chunk)
                        if not chunk:
                            selector.unregister(pipe)
                            pipe.close()
            # Keep signal escalation alive even if the provider closes both
            # output pipes before it exits.
            while process.poll() is None:
                if stopped_at is not None and time.monotonic() - stopped_at > STOP_GRACE_SECONDS:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    process.wait(timeout=0.1)
                except subprocess.TimeoutExpired:
                    pass
            exit_code = process.returncode
        if stopped_at is not None:
            exit_code = 130
            emit({"type": "status", "text": "Stopped by user", "status": "cancelled"})
        elif exit_code:
            normalizer.error(f"{args.provider} exited with status {exit_code}" +
                             (": " + stderr_tail[-1] if stderr_tail else ""))
        elif not normalizer.completed:
            normalizer.error("Provider exited without reporting a completed turn")
            exit_code = 1
    except BrokenPipeError:
        # jobstop() may close Neovim's read end before our cancellation status
        # is delivered. Losing the consumer cancels the entire provider group.
        if stopped_at is None:
            stopped_at = time.monotonic()
        raise
    except (OSError, ValueError) as error:
        normalizer.error(str(error))
        exit_code = 1
    finally:
        if process is not None:
            if stopped_at is not None:
                # A child may ignore SIGTERM even when the CLI exits promptly.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=STOP_GRACE_SECONDS)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    pass
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe is not None and not pipe.closed:
                    pipe.close()
        leases.close()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    ok = exit_code == 0 and normalizer.completed and not normalizer.failed and not normalizer.blocked
    emit({"type": "done", "ok": ok, "exit_code": exit_code,
          "blocked": normalizer.blocked, "cancelled": stopped_at is not None})
    return 0 if ok else (exit_code if exit_code > 0 else 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--session", default="")
    parser.add_argument("--mode", default="edit", choices=("edit", "plan"))
    parser.add_argument("--interactive", action="store_true",
                        help="Replace the bridge with the native interactive CLI; do not read or submit a prompt")
    args = parser.parse_args()

    if args.interactive:
        try:
            command = build_interactive_command(args.provider, args.cwd, args.model, args.session, args.mode)
            with writer_lock(args.cwd, args.mode, inherit=True):
                environment = provider_environment()
                enforce_account(args.provider, env=environment)
                os.chdir(args.cwd)
                os.execvpe(command[0], command, environment)
        except (OSError, ValueError) as error:
            print(f"Kiln: {error}", file=sys.stderr)
            return 1

    def emit(record: dict) -> None:
        print(json.dumps(record, ensure_ascii=False, separators=(",", ":")), flush=True)

    try:
        return run(args, sys.stdin.read(), emit)
    except BrokenPipeError:
        # Neovim has gone away. run() still kills the child in its finally block.
        sys.stdout = open(os.devnull, "w")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
