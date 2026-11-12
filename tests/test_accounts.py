"""Account verification against offline CLI doubles; no real login is used."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import accounts


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kiln-account-test-")
        self.root = Path(self.temp.name)
        self.env = {"HOME": str(self.root), "PATH": os.environ.get("PATH", "")}

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, provider, source):
        executable = self.root / provider
        executable.write_text(f"#!{sys.executable}\n" + source)
        executable.chmod(0o755)
        self.env[f"KILN_{provider.upper()}_BIN"] = str(executable)
        return executable

    def profile(self, **values):
        (self.root / "providers.json").write_text(json.dumps(values))
        self.env["KILN_STATE_DIR"] = str(self.root)
        return values

    def claude(self, **payload):
        payload.setdefault("apiProvider", "firstParty")
        self.fake("claude", "import json, sys\nassert sys.argv[1:] == ['auth', 'status', '--json']\nprint(" + repr(json.dumps(payload)) + ")\n")

    def codex(self, account=None, requires_auth=True):
        requests = str(self.root / "requests.jsonl")
        payload = json.dumps({"id": 2, "result": {"account": account, "requiresOpenaiAuth": requires_auth}})
        self.fake("codex", f'''import json, sys
assert sys.argv[1:] == ['app-server', '--stdio']
def read():
    line = sys.stdin.readline()
    with open({requests!r}, 'a') as log: log.write(line)
    return json.loads(line)
assert read()['method'] == 'initialize'
print('{{"id":1,"result":{{"userAgent":"fake"}}}}', flush=True)
assert read()['method'] == 'initialized'
request = read()
assert request['method'] == 'account/read'
assert request['params'] == {{'refreshToken': False}}
print({payload!r}, flush=True)
sys.stdin.read()
''')

    def test_missing_profile_keeps_general_use_unguarded(self):
        self.assertEqual(accounts.load_profile(str(self.root)), {})
        with patch.object(accounts, "read_account") as read:
            accounts.enforce_account("codex", env=self.env)
        read.assert_not_called()

    def test_profile_paths_are_explicit_and_environment_is_restored(self):
        self.profile(expected_email="personal@example.com", claude_config_dir="/profiles/claude", codex_home="/profiles/codex")
        self.env.update(XDG_CONFIG_HOME="/isolated", KILN_ORIGINAL_XDG_CONFIG_HOME="/original",
                        XDG_DATA_HOME="/isolated/data", KILN_ORIGINAL_XDG_DATA_HOME="")
        env = accounts.provider_environment(self.env)
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/profiles/claude")
        self.assertEqual(env["CODEX_HOME"], "/profiles/codex")
        self.assertEqual(env["XDG_CONFIG_HOME"], "/original")
        self.assertNotIn("XDG_DATA_HOME", env)
        self.assertEqual(self.env["XDG_CONFIG_HOME"], "/isolated")

    def test_bad_profile_fails_closed(self):
        for value in ([], {"expected_email": ""}, {"expected_email": "no-email"}, {"claude_config_dir": "relative"}):
            (self.root / "providers.json").write_text(json.dumps(value))
            with self.assertRaises(accounts.AccountError):
                accounts.load_profile(str(self.root))
        (self.root / "providers.json").write_text("not json")
        with self.assertRaises(accounts.AccountError):
            accounts.load_profile(str(self.root))

    def test_claude_matching_subscription_identity(self):
        self.claude(loggedIn=True, authMethod="claude.ai", email="Personal@Example.com", configDirectory="/selected/claude")
        profile = self.profile(expected_email="personal@example.com")
        info = accounts.check_account("claude", profile, self.env)
        self.assertTrue(info["authenticated"])
        self.assertTrue(info["matches"])
        self.assertEqual(info["config_dir"], "/selected/claude")
        accounts.enforce_account("claude", profile, self.env)

    def test_claude_mismatch_is_blocked(self):
        self.claude(loggedIn=True, authMethod="claude.ai", email="work@example.com")
        profile = self.profile(expected_email="personal@example.com")
        with self.assertRaisesRegex(accounts.AccountError, "signed in as work@example.com"):
            accounts.enforce_account("claude", profile, self.env)

    def test_missing_or_unverified_identity_is_blocked(self):
        profile = self.profile(expected_email="personal@example.com")
        for payload in ({"loggedIn": False}, {"loggedIn": True, "authMethod": "api_key", "email": "personal@example.com"},
                        {"loggedIn": True, "authMethod": "third_party"},
                        {"loggedIn": True, "authMethod": "claude.ai", "email": "personal@example.com", "apiProvider": "bedrock"},
                        {"loggedIn": True, "authMethod": "claude.ai", "email": "personal@example.com", "apiProvider": None}):
            self.claude(**payload)
            with self.assertRaisesRegex(accounts.AccountError, "Cannot verify"):
                accounts.enforce_account("claude", profile, self.env)

    def test_api_environment_route_is_blocked_before_cli(self):
        profile = self.profile(expected_email="personal@example.com")
        self.env["ANTHROPIC_API_KEY"] = "do-not-print-this-secret"
        with patch.object(accounts, "read_account") as read:
            with self.assertRaises(accounts.AccountError) as caught:
                accounts.enforce_account("claude", profile, self.env)
        read.assert_not_called()
        self.assertIn("ANTHROPIC_API_KEY", str(caught.exception))
        self.assertNotIn("do-not-print", str(caught.exception))

    def test_codex_checks_sequential_metadata_only(self):
        self.codex({"type": "chatgpt", "email": "personal@example.com", "planType": "pro"})
        profile = self.profile(expected_email="personal@example.com")
        info = accounts.check_account("codex", profile, self.env)
        self.assertTrue(info["matches"])
        records = [json.loads(line) for line in (self.root / "requests.jsonl").read_text().splitlines()]
        self.assertEqual([r["method"] for r in records], ["initialize", "initialized", "account/read"])
        self.assertFalse(records[-1]["params"]["refreshToken"])
        self.assertEqual(info["config_dir"], str(self.root / ".codex"))

    def test_codex_api_and_third_party_accounts_are_unverifiable(self):
        profile = self.profile(expected_email="personal@example.com")
        for account, requires in (({"type": "apiKey"}, True), ({"type": "amazonBedrock"}, False),
                                  ({"type": "chatgpt", "email": "personal@example.com"}, False), (None, True)):
            self.codex(account, requires)
            with self.assertRaisesRegex(accounts.AccountError, "Cannot verify"):
                accounts.enforce_account("codex", profile, self.env)

    def test_codex_mismatch_is_blocked(self):
        self.codex({"type": "chatgpt", "email": "work@example.com"})
        profile = self.profile(expected_email="personal@example.com")
        with self.assertRaisesRegex(accounts.AccountError, "work@example.com"):
            accounts.enforce_account("codex", profile, self.env)

    def test_metadata_timeout_reaps_stubborn_server(self):
        pidfile = self.root / "server.pid"
        self.fake("codex", f'''import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open({str(pidfile)!r}, 'w').write(str(os.getpid()))
time.sleep(60)
''')
        before = time.monotonic()
        with self.assertRaisesRegex(accounts.AccountError, "timed out"):
            # Allow cold interpreter startup under the full parallel test load;
            # the process must reach the SIGTERM-ignore fixture before timeout.
            accounts.read_account("codex", self.env, timeout=1.5)
        self.assertLess(time.monotonic() - before, 3.5)
        self.assertTrue(pidfile.exists(), "metadata fixture started before timeout")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def test_claude_timeout_reaps_process(self):
        pidfile = self.root / "claude.pid"
        self.fake("claude", f"import os, time\nopen({str(pidfile)!r}, 'w').write(str(os.getpid()))\ntime.sleep(60)\n")
        with self.assertRaisesRegex(accounts.AccountError, "timed out"):
            accounts.read_account("claude", self.env, timeout=1.5)
        self.assertTrue(pidfile.exists(), "metadata fixture started before timeout")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def test_cli_output_whitelists_metadata(self):
        self.claude(loggedIn=True, authMethod="claude.ai", email="personal@example.com", secret="never-output-this")
        self.profile(expected_email="personal@example.com")
        result = subprocess.run([sys.executable, str(ROOT / "python/accounts.py"), "--provider", "claude", "--state-dir", str(self.root)],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(json.loads(result.stdout)), {"authenticated", "email", "matches", "config_dir"})
        self.assertNotIn("never-output", result.stdout + result.stderr)

    def test_streaming_bridge_never_starts_mismatched_account(self):
        marker = self.root / "agent-started"
        self.fake("claude", f'''import json, sys
if sys.argv[1:3] == ['auth', 'status']:
    print(json.dumps({{'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty', 'email': 'work@example.com'}}))
else:
    open({str(marker)!r}, 'w').write('bad')
''')
        self.profile(expected_email="personal@example.com")
        result = subprocess.run([sys.executable, str(ROOT / "python/bridge.py"), "--provider", "claude", "--cwd", str(self.root)],
                                input="Change code", env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(marker.exists())
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertIn("work@example.com", events[0]["text"])
        self.assertFalse(events[-1]["ok"])

    def test_native_takeover_never_starts_mismatched_account(self):
        marker = self.root / "agent-started"
        self.fake("claude", f'''import json, sys
if sys.argv[1:3] == ['auth', 'status']:
    print(json.dumps({{'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty', 'email': 'work@example.com'}}))
else:
    open({str(marker)!r}, 'w').write('bad')
''')
        self.profile(expected_email="personal@example.com")
        result = subprocess.run([sys.executable, str(ROOT / "python/bridge.py"), "--provider", "claude", "--cwd", str(self.root), "--interactive"],
                                input="", env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(marker.exists())
        self.assertIn("work@example.com", result.stderr)

    def test_cancel_during_account_probe_reaps_server_and_never_starts_agent(self):
        pidfile = self.root / "metadata.pid"
        marker = self.root / "agent-started"
        self.fake("codex", f'''import os, signal, sys, time
if sys.argv[1] == 'app-server':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open({str(pidfile)!r}, 'w').write(str(os.getpid()))
    time.sleep(60)
else:
    open({str(marker)!r}, 'w').write('bad')
''')
        self.profile(expected_email="personal@example.com")
        process = subprocess.Popen([sys.executable, str(ROOT / "python/bridge.py"), "--provider", "codex", "--cwd", str(self.root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=self.env)
        process.stdin.write("Change code")
        process.stdin.close()
        process.stdin = None
        try:
            deadline = time.monotonic() + 3
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pidfile.exists())
            process.terminate()
            stdout, stderr = process.communicate(timeout=3)
            self.assertNotEqual(process.returncode, 0, stderr)
            self.assertFalse(marker.exists())
            self.assertTrue(json.loads(stdout.splitlines()[-1])["cancelled"])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pidfile.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == "__main__":
    unittest.main()
