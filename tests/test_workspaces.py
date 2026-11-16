import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "python" / "workspaces.py"
sys.path.insert(0, str(MODULE.parent))
spec = importlib.util.spec_from_file_location("kiln_workspaces", MODULE)
workspaces = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspaces)


class WorkspacesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kiln workspaces ")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name).resolve()
        self.root = self.parent / "project with spaces"
        self.root.mkdir()
        self.storage = self.parent / "private state" / "worktrees"
        self.git(self.root, "init", "-b", "main")
        self.git(self.root, "config", "user.name", "Test User")
        self.git(self.root, "config", "user.email", "test@example.test")
        (self.root / "queue.ex").write_text("defmodule Queue do\n  def limit, do: 3\nend\n")
        (self.root / ".gitignore").write_text("ignored.txt\n")
        self.git(self.root, "add", ".")
        self.git(self.root, "commit", "-m", "Initial project")
        self.base = self.git(self.root, "rev-parse", "HEAD").stdout.strip()

    def git(self, root, *args):
        return subprocess.run(["git", "-c", "commit.gpgSign=false", "-C", str(root), *args],
                              check=True, capture_output=True, text=True, timeout=10)

    def create(self, task="one"):
        return workspaces.create(self.root, self.storage, task)

    def inspect(self, task):
        return workspaces.inspect(self.root, task["root"], task["branch"], task["base"])

    def integrate(self, task, expected=None):
        return workspaces.integrate(self.root, task["root"], task["branch"], task["base"],
                                    expected or self.inspect(task)["fingerprint"])

    def error(self, code, action):
        with self.assertRaises(workspaces.WorkspaceError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_independent_tasks_share_committed_base_but_not_files(self):
        one, two = self.create("one"), self.create("two")
        first, second = Path(one["root"]), Path(two["root"])
        (first / "queue.ex").write_text("first agent\n")
        (second / "queue.ex").write_text("second agent\n")
        self.assertEqual(one["base"], two["base"])
        self.assertNotEqual(one["branch"], two["branch"])
        self.assertEqual((first / "queue.ex").read_text(), "first agent\n")
        self.assertEqual((second / "queue.ex").read_text(), "second agent\n")
        self.assertIn("defmodule", (self.root / "queue.ex").read_text())
        self.assertEqual(self.git(self.root, "status", "--porcelain").stdout, "")

    def test_dirty_source_is_reported_and_never_copied(self):
        (self.root / "queue.ex").write_text("uncommitted human work\n")
        (self.root / "private.ex").write_text("untracked\n")
        task = self.create()
        self.assertTrue(task["source_dirty"])
        self.assertIn("defmodule", (Path(task["root"]) / "queue.ex").read_text())
        self.assertFalse((Path(task["root"]) / "private.ex").exists())
        self.assertEqual((self.root / "queue.ex").read_text(), "uncommitted human work\n")

    def test_inspect_includes_committed_and_untracked_changes(self):
        task = self.create()
        path = Path(task["root"])
        (path / "queue.ex").write_text("new implementation\n")
        self.git(path, "add", "queue.ex")
        self.git(path, "commit", "-m", "Agent commit")
        (path / "new test.exs").write_text("assert Queue.limit() == 3\n")
        info = self.inspect(task)
        self.assertTrue(info["dirty"])
        self.assertNotEqual(info["head"], task["base"])
        self.assertEqual([(f["path"], f["status"]) for f in info["files"]],
                         [("new test.exs", "??"), ("queue.ex", "M")])

    def test_review_fingerprint_detects_equal_length_same_mtime_untracked_edits(self):
        task = self.create()
        path = Path(task["root"]) / "untracked.bin"
        path.write_bytes(b"a\0b")
        stamp = self.inspect(task)["fingerprint"]
        before = path.stat()
        path.write_bytes(b"c\0d")
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertNotEqual(stamp, self.inspect(task)["fingerprint"])

    def test_integrates_reviewed_files_without_losing_human_edit(self):
        task = self.create()
        path = Path(task["root"])
        content = "defmodule Queue do\n  def order(jobs), do: Enum.sort_by(jobs, &{-&1.priority, &1.title})\nend\n"
        (path / "queue.ex").write_text(content)
        (path / "board.ex").write_text("defmodule Board do\nend\n")
        result = self.integrate(task)
        self.assertTrue(result["integrated"])
        self.assertEqual((self.root / "queue.ex").read_text(), content)
        self.assertEqual((path / "queue.ex").read_text(), content)
        self.assertTrue((self.root / "board.ex").exists())
        self.assertEqual(self.git(path, "status", "--porcelain").stdout, "")
        self.assertEqual(self.git(self.root, "status", "--porcelain").stdout, "")
        self.assertEqual(self.git(self.root, "log", "-1", "--format=%an <%ae>").stdout.strip(),
                         "WarrenBuffering <WarrenBuffering@users.noreply.github.com>")
        self.assertEqual(len(self.git(self.root, "rev-list", "--parents", "-n", "1", "HEAD").stdout.split()), 3)

    def test_integrates_two_parallel_nonconflicting_tasks(self):
        first, second = self.create("first"), self.create("second")
        (Path(first["root"]) / "board.ex").write_text("defmodule Board do\nend\n")
        (Path(second["root"]) / "queue_test.exs").write_text("assert true\n")
        self.integrate(first)
        self.integrate(second)
        self.assertTrue((self.root / "board.ex").exists())
        self.assertTrue((self.root / "queue_test.exs").exists())

    def test_conflict_preserves_destination_and_dirty_task_exactly(self):
        first, second = self.create("first"), self.create("second")
        (Path(first["root"]) / "queue.ex").write_text("first\n")
        other = Path(second["root"])
        (other / "queue.ex").write_text("second\n")
        self.git(other, "add", "queue.ex")
        (other / "queue.ex").write_text("second plus hand edit\n")
        self.integrate(first)
        head = self.git(self.root, "rev-parse", "HEAD").stdout
        task_head = self.git(other, "rev-parse", "HEAD").stdout
        index = self.git(other, "diff", "--cached").stdout
        stamp = self.inspect(second)["fingerprint"]
        self.error("conflict", lambda: self.integrate(second, stamp))
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git(other, "rev-parse", "HEAD").stdout, task_head)
        self.assertEqual(self.git(other, "diff", "--cached").stdout, index)
        self.assertEqual(self.inspect(second)["fingerprint"], stamp)
        self.assertEqual((self.root / "queue.ex").read_text(), "first\n")
        self.assertEqual((other / "queue.ex").read_text(), "second plus hand edit\n")
        self.assertFalse((self.root / ".git" / "MERGE_HEAD").exists())

    def test_refuses_review_drift_without_checkpointing(self):
        task = self.create()
        path = Path(task["root"])
        (path / "queue.ex").write_text("reviewed\n")
        stamp = self.inspect(task)["fingerprint"]
        (path / "queue.ex").write_text("changed after review\n")
        self.error("review_changed", lambda: self.integrate(task, stamp))
        self.assertEqual(self.git(path, "rev-parse", "HEAD").stdout.strip(), self.base)
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD").stdout.strip(), self.base)

    def test_refuses_dirty_destination_even_for_nonoverlapping_file(self):
        task = self.create()
        (Path(task["root"]) / "board.ex").write_text("agent\n")
        (self.root / "human.ex").write_text("human\n")
        self.error("dirty_destination", lambda: self.integrate(task))
        self.assertFalse((self.root / "board.ex").exists())
        self.assertEqual((self.root / "human.ex").read_text(), "human\n")

    def test_never_runs_hooks_when_creating_checkpoint_or_integrating(self):
        hooks = self.root / ".git" / "hooks"
        for name in ("post-checkout", "pre-commit", "commit-msg", "post-commit", "post-merge", "pre-merge-commit"):
            hook = hooks / name
            hook.write_text("#!/bin/sh\nprintf called >> '" + str(self.parent / "hook-called") + "'\nexit 1\n")
            hook.chmod(0o755)
        task = self.create()
        (Path(task["root"]) / "board.ex").write_text("agent\n")
        self.integrate(task)
        self.assertFalse((self.parent / "hook-called").exists())

    def test_ignored_files_are_not_checkpointed(self):
        task = self.create()
        path = Path(task["root"])
        (path / "ignored.txt").write_text("local only\n")
        (path / "board.ex").write_text("tracked\n")
        self.integrate(task)
        self.assertFalse((self.root / "ignored.txt").exists())
        self.assertEqual((path / "ignored.txt").read_text(), "local only\n")

    def test_requires_owned_workspace_matching_project_branch_and_base(self):
        task = self.create()
        self.error("ownership", lambda: workspaces.inspect(self.root, task["root"], "main", task["base"]))
        self.error("ownership", lambda: workspaces.inspect(self.root, self.root, task["branch"], task["base"]))
        marker = workspaces.manifest_path(Path(task["worktree"]))
        marker.unlink()
        self.error("ownership", lambda: self.inspect(task))

    def test_refuses_workspace_after_branch_switch(self):
        task = self.create()
        path = Path(task["root"])
        self.git(path, "checkout", "-b", "unrelated")
        self.error("ownership", lambda: self.inspect(task))

    def test_rejects_invalid_ids_storage_and_duplicate_task(self):
        for value in ("../escape", "-bad/branch", "", "x" * 65):
            self.error("invalid_id", lambda: self.create(value))
        self.error("invalid_storage", lambda: workspaces.create(self.root, self.root / ".git" / "trees", "test"))
        task = self.create()
        workspaces.manifest_path(Path(task["worktree"])).unlink()
        self.error("exists", lambda: self.create())

    def test_create_recovers_owned_task_after_lost_callback(self):
        task = self.create()
        (Path(task["root"]) / "queue.ex").write_text("unfinished task work\n")
        (self.root / "extra.ex").write_text("main changed later\n")
        self.git(self.root, "add", "extra.ex")
        self.git(self.root, "commit", "-m", "Advance main")
        recovered = self.create()
        self.assertTrue(recovered["recovered"])
        self.assertEqual(recovered["root"], task["root"])
        self.assertEqual(recovered["base"], task["base"])
        self.assertEqual((Path(task["root"]) / "queue.ex").read_text(), "unfinished task work\n")
        self.assertFalse((Path(task["root"]) / "extra.ex").exists())

    def test_in_repository_storage_must_be_ignored(self):
        self.error("invalid_storage", lambda: workspaces.create(self.root, self.root / "worktrees", "bad"))
        self.assertFalse((self.root / "worktrees").exists())
        with (self.root / ".gitignore").open("a") as stream:
            stream.write(".state/\n")
        task = workspaces.create(self.root, self.root / ".state" / "worktrees", "good")
        self.assertTrue(Path(task["root"]).exists())
        self.assertNotIn(".state", self.git(self.root, "status", "--porcelain").stdout)

    def test_malformed_ownership_record_is_rejected(self):
        task = self.create()
        workspaces.manifest_path(Path(task["worktree"])).write_text("[]")
        self.error("ownership", lambda: self.inspect(task))

    def test_subdirectory_launch_requires_root_for_isolation(self):
        child = self.root / "lib"
        child.mkdir()
        self.error("project_subdirectory", lambda: workspaces.create(child, self.storage, "test"))

    def test_noop_integration_preserves_head(self):
        task = self.create()
        result = self.integrate(task)
        self.assertTrue(result["integrated"])
        self.assertEqual(result["head"], self.base)

    def test_cli_returns_parseable_structured_error(self):
        result = subprocess.run(["python3", str(MODULE), "create", "--root", str(self.root),
                                 "--storage", str(self.storage), "--id", "../bad"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["code"], "invalid_id")
        self.assertEqual(result.stderr, "")

    def test_integration_refuses_an_agent_lease_in_either_checkout(self):
        task = self.create()
        task_path = Path(task["root"])
        (task_path / "queue.ex").write_text("reviewed task\n")
        before = self.inspect(task)["fingerprint"]
        for root in (self.root, task_path):
            with self.subTest(root=root), workspaces.writer_lock(str(root), "edit"):
                self.error("writer_busy", lambda: self.integrate(task, before))
                self.assertEqual(self.git(self.root, "rev-parse", "HEAD").stdout.strip(), self.base)
                self.assertEqual(self.inspect(task)["fingerprint"], before)
        # Refusal released every partially acquired lease.
        self.assertTrue(self.integrate(task, before)["integrated"])

    def test_integration_holds_both_writer_leases_but_not_unrelated_task(self):
        task = self.create()
        sibling = self.create("sibling")
        (Path(task["root"]) / "queue.ex").write_text("reviewed task\n")
        original = workspaces.snapshot
        observed = []

        def while_merging(root, head):
            for cwd in (self.root, Path(task["root"])):
                with self.assertRaisesRegex(ValueError, "Another Kiln editing agent"):
                    with workspaces.writer_lock(str(cwd), "edit"):
                        self.fail("Integration lease was missing")
                observed.append(str(cwd))
            with workspaces.writer_lock(sibling["root"], "edit"):
                observed.append("parallel sibling")
            return original(root, head)

        with mock.patch.object(workspaces, "snapshot", side_effect=while_merging):
            result = self.integrate(task)
        self.assertTrue(result["integrated"])
        self.assertEqual(len(observed), 3)
        for cwd in (self.root, Path(task["root"])):
            with workspaces.writer_lock(str(cwd), "edit"):
                pass

    def test_review_required(self):
        task = self.create()
        self.error("review_required", lambda: workspaces.integrate(self.root, task["root"], task["branch"], task["base"], ""))


if __name__ == "__main__":
    unittest.main()
