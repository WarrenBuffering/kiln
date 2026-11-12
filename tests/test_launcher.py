import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import termios
import types
import unittest
from unittest import mock


LAUNCHER = Path(__file__).resolve().parents[1] / "bin" / "kiln"
loader = importlib.machinery.SourceFileLoader("kiln_launcher", str(LAUNCHER))
spec = importlib.util.spec_from_loader(loader.name, loader)
launcher = importlib.util.module_from_spec(spec)
loader.exec_module(launcher)


class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.original = [termios.IXON | termios.ICRNL, 3, 4, 5, 6, 7, [b"x"]]

    def test_disables_flow_control_and_restores_exact_terminal(self):
        with mock.patch.object(launcher.sys, "stdin") as stdin, \
             mock.patch.object(launcher.termios, "tcgetattr", return_value=self.original), \
             mock.patch.object(launcher.termios, "tcsetattr") as setattrs, \
             mock.patch.object(launcher.subprocess, "Popen") as popen, \
             mock.patch.object(launcher.signal, "signal"):
            stdin.isatty.return_value = True
            stdin.fileno.return_value = 12
            popen.return_value.wait.return_value = 0
            self.assertEqual(launcher.run_editor(["nvim"], {"TEST": "1"}, "/tmp"), 0)
            first = setattrs.call_args_list[0].args[2]
            self.assertEqual(first[0] & termios.IXON, 0)
            self.assertEqual(first[1:], self.original[1:])
            self.assertEqual(setattrs.call_args_list[-1].args, (12, termios.TCSANOW, self.original))
            popen.assert_called_once_with(["nvim"], env={"TEST": "1"}, cwd="/tmp")

    def test_restores_terminal_when_editor_cannot_start(self):
        with mock.patch.object(launcher.sys, "stdin") as stdin, \
             mock.patch.object(launcher.termios, "tcgetattr", return_value=self.original), \
             mock.patch.object(launcher.termios, "tcsetattr") as setattrs, \
             mock.patch.object(launcher.subprocess, "Popen", side_effect=OSError("failed")):
            stdin.isatty.return_value = True
            stdin.fileno.return_value = 12
            with self.assertRaises(OSError):
                launcher.run_editor(["missing"], {}, "/tmp")
            self.assertEqual(setattrs.call_args_list[-1].args[2], self.original)

    def test_non_terminal_preserves_exit_status(self):
        with mock.patch.object(launcher.sys, "stdin") as stdin, \
             mock.patch.object(launcher.termios, "tcgetattr") as getattrs, \
             mock.patch.object(launcher.subprocess, "Popen") as popen, \
             mock.patch.object(launcher.signal, "signal"):
            stdin.isatty.return_value = False
            popen.return_value.wait.return_value = -15
            self.assertEqual(launcher.run_editor(["nvim"], {}, "/tmp"), 143)
            getattrs.assert_not_called()


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kiln-launcher-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project with spaces"
        self.project.mkdir()
        self.fake = self.root / "nvim"
        self.fake.write_text(
            "#!/usr/bin/env python3\n"
            "import json,os,sys\n"
            "if '--version' in sys.argv: print('NVIM v0.10.1')\n"
            "else: print(json.dumps({'argv':sys.argv,'cwd':os.getcwd(),'root':os.environ['KILN_ROOT'],"
            "'xdg':os.environ['XDG_CONFIG_HOME'],'original':os.environ['KILN_ORIGINAL_XDG_CONFIG_HOME'],"
            "'demo':os.environ['KILN_DEMO']}))\n"
        )
        self.fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        KILN_STATE_DIR=str(self.root / "private state"), XDG_CONFIG_HOME="/original/config")

    def call(self, *args):
        return subprocess.run([str(LAUNCHER), *args], env=self.env, stdin=subprocess.DEVNULL,
                              text=True, capture_output=True, timeout=10)

    def test_literal_paths_and_original_provider_environment(self):
        result = self.call("--demo", str(self.project), "a $(touch dangerous).py")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout)
        self.assertEqual(info["argv"][-2:], ["--", "a $(touch dangerous).py"])
        self.assertEqual(info["cwd"], str(self.project))
        self.assertEqual(info["root"], str(self.project))
        self.assertEqual(info["original"], "/original/config")
        self.assertEqual(info["xdg"], str(self.root / "private state" / "config"))
        self.assertEqual(info["demo"], "1")
        self.assertFalse((self.project / "dangerous").exists())
        self.assertEqual((self.root / "private state").stat().st_mode & 0o777, 0o700)

    def test_missing_project_has_actionable_error(self):
        result = self.call(str(self.root / "missing"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a directory", result.stderr)

    def test_rejects_unsupported_neovim(self):
        self.fake.write_text("#!/bin/sh\nprintf 'NVIM v0.9.5\\n'\n")
        result = self.call(str(self.project))
        self.assertEqual(result.returncode, 2)
        self.assertIn("0.10 or newer", result.stderr)


class AccountCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kiln-account-command-")
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.profile = {"expected_email": "personal@example.invalid",
                        "claude_config_dir": str(self.state / "claude-personal"),
                        "codex_home": str(self.state / "codex-personal")}
        self.env = {"CLAUDE_CONFIG_DIR": self.profile["claude_config_dir"],
                    "CODEX_HOME": self.profile["codex_home"]}
        self.accounts = types.SimpleNamespace(
            AccountError=RuntimeError,
            load_profile=mock.Mock(return_value=self.profile),
            provider_environment=mock.Mock(return_value=self.env),
            check_account=mock.Mock(return_value={"authenticated": True, "matches": True,
                                                  "email": "personal@example.invalid", "config_dir": "isolated"}),
        )

    def test_claude_login_only_uses_configured_profile_and_subscription(self):
        with mock.patch.object(launcher, "account_tools", return_value=self.accounts), \
             mock.patch.object(launcher.subprocess, "run") as run, \
             mock.patch("builtins.print"):
            run.return_value.returncode = 0
            self.assertEqual(launcher.login_provider(LAUNCHER.parent.parent, self.state, "claude", "/fake/claude"), 0)
            run.assert_called_once_with(
                ["/fake/claude", "auth", "login", "--claudeai", "--email", "personal@example.invalid"],
                env=self.env, check=False)
            self.assertTrue(Path(self.profile["claude_config_dir"]).is_dir())
            self.accounts.check_account.assert_called_once_with("claude", profile=self.profile, env=self.env)

    def test_codex_login_uses_device_authorization_and_isolated_environment(self):
        with mock.patch.object(launcher, "account_tools", return_value=self.accounts), \
             mock.patch.object(launcher.subprocess, "run") as run, \
             mock.patch("builtins.print"):
            run.return_value.returncode = 0
            self.assertEqual(launcher.login_provider(LAUNCHER.parent.parent, self.state, "codex", "/fake/codex"), 0)
            run.assert_called_once_with(["/fake/codex", "login", "--device-auth"], env=self.env, check=False)

    def test_successful_cli_exit_does_not_hide_wrong_account(self):
        self.accounts.check_account.return_value["matches"] = False
        with mock.patch.object(launcher, "account_tools", return_value=self.accounts), \
             mock.patch.object(launcher.subprocess, "run") as run, \
             mock.patch("builtins.print"):
            run.return_value.returncode = 0
            self.assertEqual(launcher.login_provider(LAUNCHER.parent.parent, self.state, "claude", "/fake/claude"), 1)

    def test_account_listing_never_runs_login(self):
        with mock.patch.object(launcher, "account_tools", return_value=self.accounts), \
             mock.patch.object(launcher.subprocess, "run") as run, \
             mock.patch("builtins.print"):
            self.assertEqual(launcher.show_accounts(LAUNCHER.parent.parent, self.state), 0)
            run.assert_not_called()
            self.assertEqual(self.accounts.check_account.call_count, 2)

    def test_account_metadata_error_is_reported_without_mutating_profile(self):
        self.accounts.check_account.side_effect = RuntimeError("metadata unavailable")
        with mock.patch.object(launcher, "account_tools", return_value=self.accounts), \
             mock.patch.object(launcher.subprocess, "run") as run, \
             mock.patch("builtins.print"):
            self.assertEqual(launcher.show_accounts(LAUNCHER.parent.parent, self.state), 1)
            run.assert_not_called()
            self.assertFalse(Path(self.profile["claude_config_dir"]).exists())


class ProjectLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kiln-project-lock-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        self.state = self.directory / "state"
        self.project = self.directory / "project"
        self.other = self.directory / "other"
        self.project.mkdir()
        self.other.mkdir()

    def test_second_owner_is_denied_and_different_roots_are_independent(self):
        with launcher.project_lock(self.state, self.project):
            with self.assertRaisesRegex(launcher.WorkspaceInUseError, "already open for this project"):
                with launcher.project_lock(self.state, self.project):
                    self.fail("a second owner acquired the same project")
            with launcher.project_lock(self.state, self.other):
                pass
        with launcher.project_lock(self.state, self.project):
            pass

    def test_root_symlink_cannot_bypass_the_lock(self):
        alias = self.directory / "alias"
        alias.symlink_to(self.project, target_is_directory=True)
        with launcher.project_lock(self.state, self.project):
            with self.assertRaises(launcher.WorkspaceInUseError):
                with launcher.project_lock(self.state, alias):
                    self.fail("a symlink acquired the same project")

    def test_lock_releases_after_exception(self):
        with self.assertRaisesRegex(RuntimeError, "editor failed"):
            with launcher.project_lock(self.state, self.project):
                raise RuntimeError("editor failed")
        with launcher.project_lock(self.state, self.project):
            pass

    def launch(self, *options):
        with mock.patch.object(launcher.sys, "argv", [str(LAUNCHER), *options, str(self.project)]), \
             mock.patch.dict(os.environ, {"KILN_STATE_DIR": str(self.state)}), \
             mock.patch.object(launcher.shutil, "which", side_effect=lambda name: "/fake/" + name), \
             mock.patch.object(launcher, "supported_neovim", return_value=True):
            return launcher.main()

    def test_launcher_holds_real_lock_while_editor_runs(self):
        def editor(*_args):
            with self.assertRaises(SystemExit) as error, mock.patch.object(launcher.sys, "stderr"):
                self.launch()
            self.assertEqual(error.exception.code, 2)
            return 0
        with mock.patch.object(launcher, "run_editor", side_effect=editor) as run:
            self.assertEqual(self.launch(), 0)
            run.assert_called_once()
        with launcher.project_lock(self.state, self.project):
            pass

    def test_demo_is_exempt_from_existing_project_lock(self):
        with launcher.project_lock(self.state, self.project), \
             mock.patch.object(launcher, "run_editor", return_value=0) as run:
            self.assertEqual(self.launch("--demo"), 0)
            run.assert_called_once()

    def test_launcher_releases_lock_when_editor_raises(self):
        with mock.patch.object(launcher, "run_editor", side_effect=RuntimeError("editor failed")):
            with self.assertRaisesRegex(RuntimeError, "editor failed"):
                self.launch()
        with launcher.project_lock(self.state, self.project):
            pass


if __name__ == "__main__":
    unittest.main()
