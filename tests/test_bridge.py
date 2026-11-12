"""Protocol and subprocess tests. No real provider or paid request is invoked."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


BRIDGE = Path(__file__).resolve().parents[1] / "python" / "bridge.py"
sys.path.insert(0, str(BRIDGE.parent))
spec = importlib.util.spec_from_file_location("bridge", BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class CommandTests(unittest.TestCase):
    def test_codex_defaults_keep_sandbox(self):
        cmd = bridge.build_command("codex")
        self.assertEqual(cmd[:2], ["codex", "exec"])
        self.assertIn('sandbox_mode="workspace-write"', cmd)
        self.assertIn('approval_policy="never"', cmd)
        self.assertNotIn("--model", cmd)
        self.assertEqual(cmd[-1], "-")

    def test_codex_resume_supports_read_only_and_model(self):
        cmd = bridge.build_command("codex", "chosen-model", "session-123", "plan")
        self.assertEqual(cmd[:3], ["codex", "exec", "resume"])
        self.assertIn('sandbox_mode="read-only"', cmd)
        self.assertEqual(cmd[-4:], ["--model", "chosen-model", "session-123", "-"])
        self.assertNotIn("--sandbox", cmd)  # Not supported by exec resume.

    def test_claude_has_edit_permissions_but_no_bypass(self):
        cmd = bridge.build_command("claude", "opus", "session-123")
        self.assertIn("acceptEdits", cmd)
        self.assertIn("--include-partial-messages", cmd)
        self.assertIn("--forward-subagent-text", cmd)
        self.assertIn("--no-chrome", cmd)
        self.assertEqual(cmd[-4:], ["--model", "opus", "--resume", "session-123"])
        self.assertFalse(any("bypass" in item or "skip-permissions" in item for item in cmd))

    def test_claude_plan_and_no_model(self):
        cmd = bridge.build_command("claude", mode="plan")
        self.assertIn("plan", cmd)
        self.assertNotIn("--model", cmd)

    def test_argument_injection_is_not_a_shell_command(self):
        model = "chosen; touch /tmp/should-not-exist"
        cmd = bridge.build_command("codex", model)
        self.assertIn(model, cmd)
        with self.assertRaises(ValueError):
            bridge.build_command("codex", session="--dangerously-bypass-approvals-and-sandbox")

    def test_invalid_provider_is_rejected(self):
        with self.assertRaises(ValueError):
            bridge.build_command("unknown")

    def test_original_xdg_is_restored_for_provider(self):
        with patch.dict(os.environ, {
            "XDG_CONFIG_HOME": "/isolated/config",
            "KILN_ORIGINAL_XDG_CONFIG_HOME": "/original/config",
            "XDG_STATE_HOME": "/isolated/state",
            "KILN_ORIGINAL_XDG_STATE_HOME": "",
        }):
            env = bridge.provider_environment()
        self.assertEqual(env["XDG_CONFIG_HOME"], "/original/config")
        self.assertNotIn("XDG_STATE_HOME", env)
        self.assertNotIn("KILN_ORIGINAL_XDG_CONFIG_HOME", env)

    def test_interactive_codex_resume_restores_approval_prompts(self):
        cmd = bridge.build_interactive_command("codex", "/tmp/work space", "chosen", "session-1")
        self.assertEqual(cmd[:4], ["codex", "resume", "--include-non-interactive", "session-1"])
        self.assertEqual(cmd[cmd.index("--ask-for-approval") + 1], "on-request")
        self.assertEqual(cmd[cmd.index("--sandbox") + 1], "workspace-write")
        self.assertEqual(cmd[-2:], ["--model", "chosen"])
        self.assertNotIn("exec", cmd)
        self.assertNotIn("-", cmd)

    def test_interactive_codex_new_plan_does_not_send_a_prompt(self):
        cmd = bridge.build_interactive_command("codex", "/tmp", mode="plan")
        self.assertEqual(cmd, ["codex", "--cd", str(Path("/tmp").resolve()), "--sandbox",
                               "read-only", "--ask-for-approval", "on-request"])

    def test_interactive_claude_keeps_native_approvals(self):
        cmd = bridge.build_interactive_command("claude", "/tmp", "opus", "session-1")
        self.assertEqual(cmd, ["claude", "--resume", "session-1", "--permission-mode",
                               "acceptEdits", "--no-chrome", "--model", "opus"])
        self.assertNotIn("--permission-prompts", cmd)
        self.assertNotIn("-p", cmd)
        self.assertIn("plan", bridge.build_interactive_command("claude", "/tmp", mode="plan"))

    def test_interactive_rejects_session_option_injection(self):
        with self.assertRaises(ValueError):
            bridge.build_interactive_command("codex", "/tmp", session="--last")


class CodexTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.parser = bridge.Normalizer("codex", self.events.append)

    def test_session_messages_and_completion(self):
        self.parser.feed({"type": "thread.started", "thread_id": "thread-1"})
        self.parser.feed({"type": "item.updated", "item": {"type": "agent_message", "id": "msg-1", "text": "Editing"}})
        self.parser.feed({"type": "item.completed", "item": {"type": "agent_message", "id": "msg-1", "text": "Editing file.py"}})
        self.parser.feed({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 5}})
        self.assertEqual(self.events[0], {"type": "session", "id": "thread-1"})
        messages = [e for e in self.events if e["type"] == "message"]
        self.assertEqual([e["id"] for e in messages], ["msg-1", "msg-1"])
        self.assertEqual(messages[-1]["text"], "Editing file.py")
        self.assertTrue(self.parser.completed)
        self.assertEqual(self.events[-1]["input_tokens"], 10)

    def test_commands_include_failure_and_output(self):
        self.parser.feed({"type": "item.started", "item": {"type": "command_execution", "id": "cmd", "command": "pytest"}})
        self.parser.feed({"type": "item.completed", "item": {"type": "command_execution", "id": "cmd", "command": "pytest", "aggregated_output": "FAIL", "exit_code": 1}})
        self.assertEqual(self.events[0]["status"], "running")
        self.assertEqual(self.events[-1]["status"], "error")
        self.assertIn("FAIL", self.events[-1]["text"])
        self.assertIn("exit 1", self.events[-1]["text"])

    def test_file_events_only_after_success(self):
        item = {"type": "file_change", "id": "files", "changes": [{"path": "src/a.py", "kind": "update"}]}
        self.parser.feed({"type": "item.started", "item": item})
        self.assertFalse(any(e["type"] == "file" for e in self.events))
        self.parser.feed({"type": "item.completed", "item": item})
        self.assertEqual(self.events[-1], {"type": "file", "path": "src/a.py", "action": "update"})

    def test_failed_turn_and_subagent_activity(self):
        self.parser.feed({"type": "item.started", "item": {"type": "collab_agent_tool_call", "id": "agent", "tool": "spawn_agent", "prompt": "Inspect tests"}})
        self.assertEqual(self.events[-1]["name"], "spawn_agent")
        self.parser.feed({"type": "turn.failed", "error": {"message": "Not authenticated"}})
        self.assertTrue(self.parser.failed)
        self.assertEqual(self.events[-1]["text"], "Not authenticated")

    def test_reasoning_is_not_displayed_as_user_commentary(self):
        self.parser.feed({"type": "item.completed", "item": {"type": "reasoning", "id": "thinking", "text": "internal"}})
        self.assertEqual(self.events, [])

    def test_malformed_event_shape_is_reported_without_crashing(self):
        self.parser.feed({"type": "item.completed", "item": "bad-shape"})
        self.assertTrue(self.parser.failed)
        self.assertIn("Unexpected codex event shape", self.events[-1]["text"])


class ClaudeTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.parser = bridge.Normalizer("claude", self.events.append)

    def stream(self, event, parent=None):
        self.parser.feed({"type": "stream_event", "event": event, "parent_tool_use_id": parent})

    def test_streamed_message_and_final_are_same_record(self):
        self.parser.feed({"type": "system", "subtype": "init", "session_id": "session-1"})
        self.stream({"type": "message_start", "message": {"id": "msg-1"}})
        self.stream({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        self.stream({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello "}})
        self.stream({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "world"}})
        self.parser.feed({"type": "assistant", "message": {"id": "msg-1", "content": [{"type": "text", "text": "Hello world"}]}})
        self.parser.feed({"type": "result", "subtype": "success", "result": "Hello world", "usage": {"input_tokens": 3, "output_tokens": 2}})
        messages = [e for e in self.events if e["type"] == "message"]
        self.assertEqual(len(messages), 2)
        self.assertEqual({e["id"] for e in messages}, {"msg-1"})
        self.assertTrue(self.parser.completed)

    def test_interleaved_subagent_and_parent_streams(self):
        self.stream({"type": "message_start", "message": {"id": "parent-msg"}})
        self.stream({"type": "message_start", "message": {"id": "child-msg"}}, "agent-tool")
        self.stream({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Parent"}})
        self.stream({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Child"}}, "agent-tool")
        self.assertEqual(self.events[-1]["agent"], "subagent")
        self.assertEqual(self.events[-1]["parent_id"], "agent-tool")
        self.assertEqual(self.parser.last_message, "parent-msg")

    def test_edit_tool_input_and_result_produce_file_event(self):
        self.stream({"type": "message_start", "message": {"id": "m"}})
        self.stream({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "edit-1", "name": "Edit", "input": {}}})
        self.stream({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": '{"file_path": "src/app.py"}'}})
        self.stream({"type": "content_block_stop", "index": 0})
        self.parser.feed({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "edit-1", "content": "Changed", "is_error": False}]}})
        self.assertEqual(self.events[-1], {"type": "file", "path": "src/app.py", "action": "update"})
        self.assertEqual(self.parser.tools["edit-1"]["status"], "done")
        self.assertIn("Changed", self.parser.tools["edit-1"]["text"])

    def test_denied_permissions_are_explicit_and_block_completion(self):
        self.parser.feed({"type": "result", "subtype": "success", "permission_denials": [{"tool_name": "Bash", "tool_use_id": "shell-1", "tool_input": {"command": "pytest"}}]})
        self.assertTrue(self.parser.blocked)
        self.assertEqual(self.parser.tools["shell-1"]["status"], "error")
        self.assertTrue(any(e.get("blocked") for e in self.events if e["type"] == "error"))

    def test_failed_result_uses_error_strings(self):
        self.parser.feed({"type": "result", "subtype": "error_during_execution", "is_error": True, "errors": ["Invalid API key"]})
        self.assertTrue(self.parser.failed)
        self.assertEqual(self.events[0]["text"], "Invalid API key")

    def test_failed_write_emits_no_file_event(self):
        self.parser.feed({"type": "assistant", "message": {"id": "m", "content": [{"type": "tool_use", "id": "write", "name": "Write", "input": {"file_path": "bad.py"}}]}})
        self.parser.feed({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "write", "content": "Denied", "is_error": True}]}})
        self.assertFalse(any(e["type"] == "file" for e in self.events))


class FramingTests(unittest.TestCase):
    def test_fragmented_utf8_and_final_line(self):
        lines = []
        parser = bridge.JsonLines(lines.append)
        payload = '{"text":"café"}\r\n{"last":true}'.encode()
        for byte in payload:
            parser.feed(bytes([byte]))
        parser.feed(b"", final=True)
        self.assertEqual([json.loads(line) for line in lines], [{"text": "café"}, {"last": True}])


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kiln-bridge-test-")
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def fake(self, source):
        script = self.root / "fake-cli"
        script.write_text(f"#!{sys.executable}\n" + source)
        script.chmod(0o755)
        return script

    def invoke(self, source, provider="codex", prompt="Inspect source", **kwargs):
        script = self.fake(source)
        env = dict(os.environ, **{f"KILN_{provider.upper()}_BIN": str(script)})
        result = subprocess.run([sys.executable, str(BRIDGE), "--provider", provider, "--cwd", str(self.root)],
                                input=prompt, capture_output=True, text=True, env=env, timeout=10, **kwargs)
        return result, [json.loads(line) for line in result.stdout.splitlines()]

    def test_successful_process_with_stderr_and_split_output(self):
        result, events = self.invoke('''import os, sys, time
prompt = sys.stdin.read()
assert "User request:" in prompt
sys.stderr.write("Startup diagnostic\\n")
os.write(1, b'{"type":"thread.')
time.sleep(0.01)
os.write(1, b'started","thread_id":"s1"}\\n')
os.write(1, b'{"type":"turn.completed","usage":{"input_tokens":5}}')
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(e["type"] == "done" for e in events), 1)
        self.assertTrue(events[-1]["ok"])
        self.assertTrue(any(e["type"] == "status" and "Startup" in e["text"] for e in events))

    def test_nonzero_exit_has_diagnostics(self):
        result, events = self.invoke('''import sys
sys.stdin.read()
sys.stderr.write("Login required\\n")
sys.exit(7)
''')
        self.assertEqual(result.returncode, 7)
        self.assertFalse(events[-1]["ok"])
        self.assertIn("Login required", next(e["text"] for e in events if e["type"] == "error"))

    def test_zero_exit_without_completed_turn_is_failure(self):
        result, events = self.invoke("import sys\nsys.stdin.read()\n")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(events[-1]["ok"])

    def test_large_prompt_and_startup_output_do_not_deadlock(self):
        result, events = self.invoke('''import json, sys
sys.stderr.write("diagnostic " * 12000 + "\\n")
sys.stderr.flush()
assert len(sys.stdin.read()) > 500000
print(json.dumps({"type":"turn.completed"}))
''', prompt="x" * 600000)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(events[-1]["ok"])

    def test_empty_prompt_never_spawns_provider(self):
        result, events = self.invoke("raise RuntimeError('must not run')\n", prompt=" ")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(events[0]["text"], "Prompt is empty")

    def test_interactive_exec_preserves_stdin_and_original_environment(self):
        script = self.fake('''import json, os, sys
print(json.dumps({"argv": sys.argv[1:], "input": sys.stdin.read(),
                  "cwd": os.getcwd(), "config": os.environ.get("XDG_CONFIG_HOME")}))
''')
        env = dict(os.environ, KILN_CLAUDE_BIN=str(script), XDG_CONFIG_HOME="/isolated",
                   KILN_ORIGINAL_XDG_CONFIG_HOME="/original")
        result = subprocess.run([sys.executable, str(BRIDGE), "--provider", "claude",
                                 "--cwd", str(self.root), "--interactive", "--session", "session-1"],
                                input="Native input, unchanged", text=True, capture_output=True, env=env, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["input"], "Native input, unchanged")
        self.assertEqual(payload["config"], "/original")
        self.assertEqual(payload["cwd"], str(self.root.resolve()))
        self.assertEqual(payload["argv"], ["--resume", "session-1", "--permission-mode", "acceptEdits", "--no-chrome"])

    def test_interactive_invalid_workspace_reports_error(self):
        result = subprocess.run([sys.executable, str(BRIDGE), "--provider", "codex",
                                 "--cwd", str(self.root / "missing"), "--interactive"],
                                input="", text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Kiln:", result.stderr)

    def test_cancellation_terminates_entire_process_group(self):
        pidfile = self.root / "child.pid"
        source = f'''import os, signal, subprocess, sys, time
sys.stdin.read()
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
open({str(pidfile)!r}, "w").write(str(child.pid))
def stop(*args):
    child.wait(timeout=3)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
print('{{"type":"thread.started","thread_id":"cancel-me"}}', flush=True)
time.sleep(60)
'''
        script = self.fake(source)
        env = dict(os.environ, KILN_CODEX_BIN=str(script))
        process = subprocess.Popen([sys.executable, str(BRIDGE), "--provider", "codex", "--cwd", str(self.root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env)
        process.stdin.write("Run test")
        process.stdin.close()
        process.stdin = None
        try:
            deadline = time.monotonic() + 5
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pidfile.exists())
            child_pid = int(pidfile.read_text())
            process.terminate()
            stdout, stderr = process.communicate(timeout=6)
            events = [json.loads(line) for line in stdout.splitlines()]
            self.assertEqual(process.returncode, 130, stderr)
            self.assertTrue(events[-1]["cancelled"])
            self.assertFalse(events[-1]["ok"])
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_cancellation_escalates_after_output_pipes_close(self):
        ready = self.root / "ready"
        source = f'''import os, signal, sys, time
sys.stdin.read()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.close(1)
os.close(2)
open({str(ready)!r}, "w").write("ready")
time.sleep(60)
'''
        script = self.fake(source)
        env = dict(os.environ, KILN_CODEX_BIN=str(script))
        process = subprocess.Popen([sys.executable, str(BRIDGE), "--provider", "codex", "--cwd", str(self.root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env)
        process.stdin.write("Run test")
        process.stdin.close()
        process.stdin = None
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            process.terminate()
            stdout, stderr = process.communicate(timeout=6)
            self.assertEqual(process.returncode, 130, stderr)
            self.assertTrue(json.loads(stdout.splitlines()[-1])["cancelled"])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_consumer_pipe_closed_during_stop_is_cancellation_and_reaps_provider(self):
        ready = self.root / "provider.pid"
        script = self.fake(f'''import os, signal, sys, time
sys.stdin.read()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open({str(ready)!r}, 'w').write(str(os.getpid()))
time.sleep(60)
''')
        env = dict(os.environ, KILN_CODEX_BIN=str(script), KILN_STATE_DIR=str(self.root))
        process = subprocess.Popen([sys.executable, str(BRIDGE), "--provider", "codex", "--cwd", str(self.root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env)
        process.stdin.write("Inspect source")
        process.stdin.close()
        provider_pid = None
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            provider_pid = int(ready.read_text())
            # Reproduce Neovim closing its read pipe before the final status.
            process.stdout.close()
            started = time.monotonic()
            process.terminate()
            process.wait(timeout=1.8)
            self.assertEqual(process.returncode, 130, process.stderr.read())
            self.assertLess(time.monotonic() - started, 1.8)
            with self.assertRaises(ProcessLookupError):
                os.kill(provider_pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for pipe in (process.stdout, process.stderr):
                if not pipe.closed:
                    pipe.close()
            if provider_pid:
                try:
                    os.kill(provider_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    @unittest.skipUnless(shutil.which("nvim"), "Neovim is required for jobstop integration")
    def test_neovim_jobstop_reaps_stubborn_provider_and_child_before_forced_kill(self):
        for close_pipes in (False, True):
            with self.subTest(close_pipes=close_pipes):
                case = self.root / ("closed-pipes" if close_pipes else "open-pipes")
                case.mkdir()
                pidfile = case / "pids.json"
                resultfile = case / "result.json"
                childready = case / "child-ready"
                child_code = f'''import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open({str(childready)!r}, 'w').write('ready')
time.sleep(60)
'''
                source = f'''import json, os, signal, subprocess, sys, time
sys.stdin.read()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, '-c', {child_code!r}],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
while not os.path.exists({str(childready)!r}): time.sleep(0.01)
if {close_pipes!r}:
    os.close(1)
    os.close(2)
with open({str(pidfile)!r}, 'w') as stream:
    json.dump({{'provider': os.getpid(), 'child': child.pid}}, stream)
time.sleep(60)
'''
                script = self.fake(source)
                lua = case / "jobstop.lua"
                argv = [sys.executable, str(BRIDGE), "--provider", "codex", "--cwd", str(case)]
                lua.write_text(f'''
local fn = vim.fn
local uv = vim.uv or vim.loop
local exit_code = nil
local output = {{}}
local errors = {{}}
local argv = vim.json.decode([==[{json.dumps(argv)}]==])
local job = fn.jobstart(argv, {{
  env = {{ KILN_CODEX_BIN = {json.dumps(str(script))}, KILN_STATE_DIR = {json.dumps(str(case))} }},
  on_stdout = function(_, data) for _, line in ipairs(data) do output[#output + 1] = line end end,
  on_stderr = function(_, data) for _, line in ipairs(data) do errors[#errors + 1] = line end end,
  on_exit = function(_, code) exit_code = code end,
}})
assert(job > 0, 'bridge started')
fn.chansend(job, 'Inspect source\\n')
fn.chanclose(job, 'stdin')
assert(vim.wait(8000, function() return fn.filereadable({json.dumps(str(pidfile))}) == 1 end, 10), 'provider and child reached stubborn fixture')
local started = uv.hrtime()
assert(fn.jobstop(job) == 1, 'jobstop accepted')
assert(vim.wait(1800, function() return exit_code ~= nil end, 10), 'bridge reaped provider before Neovim forced kill')
local observation = {{exit_code = exit_code, elapsed = (uv.hrtime() - started) / 1000000000, output = output, errors = errors}}
fn.writefile({{vim.json.encode(observation)}}, {json.dumps(str(resultfile))})
assert(exit_code == 130, 'bridge cancellation diagnostic: ' .. vim.json.encode(observation))
vim.cmd('qa!')
''')
                pids = {}
                try:
                    result = subprocess.run([shutil.which("nvim"), "--headless", "-u", "NONE", "-i", "NONE", "-l", str(lua)],
                                            capture_output=True, text=True, timeout=12)
                    if pidfile.exists():
                        pids = json.loads(pidfile.read_text())
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    observation = json.loads(resultfile.read_text())
                    self.assertEqual(observation["exit_code"], 130)
                    self.assertLess(observation["elapsed"], 1.8)
                    self.assertTrue(pids)
                    # Init may briefly own the killed child before reaping it.
                    deadline = time.monotonic() + 3
                    remaining = set(pids.values())
                    while remaining and time.monotonic() < deadline:
                        for pid in tuple(remaining):
                            try:
                                os.kill(pid, 0)
                            except ProcessLookupError:
                                remaining.remove(pid)
                        if remaining:
                            time.sleep(0.02)
                    self.assertFalse(remaining, f"Provider processes survived jobstop: {remaining}")
                finally:
                    if not pids and pidfile.exists():
                        pids = json.loads(pidfile.read_text())
                    for pid in pids.values():
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == "__main__":
    unittest.main()
