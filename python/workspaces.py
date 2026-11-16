#!/usr/bin/env python3
"""Local, owned Git workspaces for Kiln tasks.

This process never contacts providers. JSON results form the Neovim boundary.
Worktree creation starts from committed HEAD; integration is a separate, explicit
operation guarded by an exact review fingerprint and a clean destination.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

from leases import writer_lock

TIMEOUT = 30
IDENTITY = {"GIT_AUTHOR_NAME": "WarrenBuffering", "GIT_AUTHOR_EMAIL": "WarrenBuffering@users.noreply.github.com",
            "GIT_COMMITTER_NAME": "WarrenBuffering", "GIT_COMMITTER_EMAIL": "WarrenBuffering@users.noreply.github.com"}


class WorkspaceError(Exception):
    def __init__(self, message, code="workspace_error"):
        super().__init__(message)
        self.code = code


def git(root, *args, check=True, env=None, data=None):
    environment = dict(os.environ)
    # A caller's alternate index or repository must never redirect these writes.
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        environment.pop(name, None)
    environment.update(IDENTITY)
    environment.update({"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"})
    if env:
        environment.update(env)
    result = subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
         "-c", "merge.gpgSign=false", "-c", "core.fsmonitor=false", "-C", str(root), *args],
        input=data, capture_output=True, env=environment, timeout=TIMEOUT)
    if check and result.returncode:
        message = result.stderr.decode("utf-8", "replace").strip() or result.stdout.decode("utf-8", "replace").strip()
        raise WorkspaceError(message or "Git operation failed.", "git_error")
    return result


def output(root, *args):
    return git(root, *args).stdout.decode("utf-8", "surrogateescape").strip()


def repo(root):
    root = Path(root).expanduser().resolve(strict=True)
    top = Path(output(root, "rev-parse", "--show-toplevel")).resolve()
    common = Path(output(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    head = output(root, "rev-parse", "--verify", "HEAD^{commit}")
    return root, top, common, head


def dirty(root):
    return bool(git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all").stdout)


def manifest_path(worktree):
    return worktree.parent / (worktree.name + ".json")


def create(root, storage, task_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", task_id):
        raise WorkspaceError("Task ID must contain only letters, numbers, underscores, or hyphens (1–64 characters).", "invalid_id")
    project, top, common, head = repo(root)
    if project != top:
        raise WorkspaceError("Open the repository root to create isolated tasks; subdirectory workspaces are not supported.", "project_subdirectory")
    source_dirty = dirty(top)
    storage = Path(storage).expanduser().resolve()
    if storage == top or storage == common or common in storage.parents:
        raise WorkspaceError("Worktree storage must be separate from the repository and its Git metadata.", "invalid_storage")
    if top in storage.parents:
        candidate = str(storage.relative_to(top) / "kiln-workspace-probe")
        if git(top, "check-ignore", "--quiet", "--no-index", "--", candidate, check=False).returncode:
            raise WorkspaceError("Worktree storage inside the project must be ignored by Git. Use an external state directory or ignore it first.", "invalid_storage")
    group = storage / hashlib.sha256(str(project).encode()).hexdigest()[:20]
    group.mkdir(parents=True, exist_ok=True, mode=0o700)
    worktree = group / task_id
    branch = "kiln/task-" + task_id
    marker = manifest_path(worktree)
    if worktree.exists() or marker.exists():
        # A successful create can outlive its editor callback (for example a
        # crash while closing). Recover only the exact task we own; never adopt
        # an unrelated directory or a worktree with missing provenance.
        try:
            record = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise WorkspaceError("This task path already exists without a readable Kiln ownership record.", "exists") from None
        if not isinstance(record, dict) or record.get("id") != task_id or not isinstance(record.get("base"), str):
            raise WorkspaceError("This task path belongs to a different workspace.", "ownership")
        _, _, _, task_root, owned_tree, _ = validate(project, worktree, branch, record["base"])
        return {"ok": True, "root": str(task_root), "worktree": str(owned_tree), "branch": branch,
                "base": record["base"], "repo_root": str(top), "source_dirty": source_dirty, "recovered": True}
    git(top, "worktree", "add", "-b", branch, "--", str(worktree), head)
    relative = project.relative_to(top)
    task_root = worktree / relative
    record = {"version": 1, "project": str(project), "repo_root": str(top), "common": str(common),
              "worktree": str(worktree), "root": str(task_root), "branch": branch, "base": head, "id": task_id}
    # Exclusive creation prevents adopting an unrelated pre-existing worktree.
    with marker.open("x", encoding="utf-8") as stream:
        json.dump(record, stream, ensure_ascii=True)
    marker.chmod(0o600)
    return {"ok": True, "root": str(task_root), "worktree": str(worktree), "branch": branch,
            "base": head, "repo_root": str(top), "source_dirty": source_dirty}


def validate(root, workspace, branch, base):
    project, top, common, _ = repo(root)
    task_root = Path(workspace).expanduser().resolve(strict=True)
    _, worktree, task_common, head = repo(task_root)
    if worktree == top or common != task_common or not re.fullmatch(r"kiln/task-[A-Za-z0-9_-]{1,64}", branch):
        raise WorkspaceError("This is not an isolated Kiln workspace for the project.", "ownership")
    try:
        record = json.loads(manifest_path(worktree).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise WorkspaceError("Workspace ownership record is missing or unreadable.", "ownership") from None
    expected = {"project": str(project), "repo_root": str(top), "common": str(common), "root": str(task_root),
                "worktree": str(worktree), "branch": branch, "base": base}
    if not isinstance(record, dict) or any(record.get(key) != value for key, value in expected.items()):
        raise WorkspaceError("Workspace identity does not match the saved task.", "ownership")
    if output(task_root, "symbolic-ref", "--quiet", "--short", "HEAD") != branch:
        raise WorkspaceError("The task worktree is no longer on its assigned branch.", "ownership")
    if not re.fullmatch(r"[0-9a-f]{40,64}", base) or git(worktree, "merge-base", "--is-ancestor", base, head, check=False).returncode:
        raise WorkspaceError("The task branch no longer descends from its recorded base.", "ownership")
    return project, top, common, task_root, worktree, head


def fingerprint(worktree, base):
    """Read actual content, including untracked files; mtimes alone are not evidence."""
    head = output(worktree, "rev-parse", "HEAD")
    state = git(worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all").stdout
    diff = git(worktree, "diff", "--binary", "--no-ext-diff", "--no-textconv", "--no-renames", base, "--").stdout
    digest = hashlib.sha256()
    for value in (base.encode(), head.encode(), state, diff):
        digest.update(len(value).to_bytes(8, "big")); digest.update(value)
    untracked = git(worktree, "ls-files", "--others", "--exclude-standard", "-z").stdout.split(b"\0")
    for raw in sorted(path for path in untracked if path):
        path = worktree / os.fsdecode(raw)
        info = path.lstat()
        digest.update(raw + b"\0" + str(stat.S_IMODE(info.st_mode)).encode() + b"\0")
        if stat.S_ISLNK(info.st_mode):
            digest.update(os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(info.st_mode):
            with path.open("rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
        else:
            raise WorkspaceError("Unsupported untracked file type: " + os.fsdecode(raw), "unsupported_file")
        digest.update(b"\0")
    return digest.hexdigest(), head, bool(state)


def changed_files(worktree, base, task_root):
    raw = git(worktree, "diff", "--name-status", "--no-renames", "-z", base, "--").stdout.split(b"\0")
    found = {}
    for index in range(0, len(raw) - 1, 2):
        if raw[index] and raw[index + 1]:
            found[os.fsdecode(raw[index + 1])] = raw[index].decode("ascii", "replace")
    for raw_path in git(worktree, "ls-files", "--others", "--exclude-standard", "-z").stdout.split(b"\0"):
        if raw_path:
            found[os.fsdecode(raw_path)] = "??"
    prefix = str(task_root.relative_to(worktree))
    prefix = "" if prefix == "." else prefix + "/"
    return [{"path": path[len(prefix):] if path.startswith(prefix) else path,
             "repo_path": path, "status": value} for path, value in sorted(found.items())]


def inspect(root, workspace, branch, base):
    _, _, _, task_root, worktree, _ = validate(root, workspace, branch, base)
    stamp, head, is_dirty = fingerprint(worktree, base)
    return {"ok": True, "root": str(task_root), "worktree": str(worktree), "branch": branch,
            "base": base, "head": head, "dirty": is_dirty, "fingerprint": stamp,
            "files": changed_files(worktree, base, task_root)}


def destination(top):
    branch = output(top, "symbolic-ref", "--quiet", "HEAD")
    if not branch.startswith("refs/heads/"):
        raise WorkspaceError("The destination must be on a local branch.", "destination")
    if dirty(top):
        raise WorkspaceError("Save and commit or stash changes in the main checkout before integrating. Your files were not changed.", "dirty_destination")
    for name in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        path = Path(output(top, "rev-parse", "--git-path", name))
        if not path.is_absolute():
            path = top / path
        if path.exists():
            raise WorkspaceError("Finish the current Git operation before integrating a task.", "git_in_progress")
    return output(top, "rev-parse", "HEAD"), branch


@contextlib.contextmanager
def integration_lock(common):
    # Serializes Kiln integrations across processes, while Git retains its own locks.
    with (common / "kiln-integration.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise WorkspaceError("Another Kiln task is being integrated. Try again when it finishes.", "busy") from None
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def snapshot(worktree, head):
    """Build a commit without changing the task's branch, real index, or files."""
    with tempfile.TemporaryDirectory(prefix="kiln-index-") as temporary:
        environment = {"GIT_INDEX_FILE": str(Path(temporary) / "index")}
        git(worktree, "read-tree", head, env=environment)
        git(worktree, "add", "--all", "--", ".", env=environment)
        tree = git(worktree, "write-tree", env=environment).stdout.strip().decode()
    if tree == output(worktree, "rev-parse", head + "^{tree}"):
        return head
    return git(worktree, "commit-tree", tree, "-p", head,
               data=b"Checkpoint reviewed Kiln task\n").stdout.strip().decode()


def integrate(root, workspace, branch, base, expected):
    if not re.fullmatch(r"[0-9a-f]{64}", expected or ""):
        raise WorkspaceError("Review the task's current changes before integrating.", "review_required")
    _, top, common, task_root, worktree, _ = validate(root, workspace, branch, base)
    with integration_lock(common), contextlib.ExitStack() as leases:
        # UI ownership is not enough: a separate Kiln window/state profile may
        # have a writer. Both directories share the bridge's kernel lease.
        for directory in sorted({str(top), str(task_root)}):
            try:
                leases.enter_context(writer_lock(directory, "edit"))
            except ValueError as error:
                raise WorkspaceError(str(error), "writer_busy") from error
        before, destination_branch = destination(top)
        stamp, old_head, _ = fingerprint(worktree, base)
        if stamp != expected:
            raise WorkspaceError("The task changed after review. Inspect and mark it reviewed again.", "review_changed")
        task_head = snapshot(worktree, old_head)
        preview = git(top, "merge-tree", "--write-tree", before, task_head, check=False)
        if preview.returncode:
            detail = preview.stdout.decode("utf-8", "replace").strip()
            if preview.returncode == 1:
                raise WorkspaceError("This task conflicts with the main checkout. Both worktrees are unchanged. Reconcile the task branch and review again.\n" + detail, "conflict")
            raise WorkspaceError(preview.stderr.decode("utf-8", "replace").strip() or "Could not preview task integration.", "merge_preview")
        if fingerprint(worktree, base)[0] != expected:
            raise WorkspaceError("The task changed while integration was being prepared. Review again.", "review_changed")
        if destination(top) != (before, destination_branch):
            raise WorkspaceError("The destination changed while integration was being prepared. Try again.", "destination_changed")
        if task_head != old_head:
            git(worktree, "update-ref", "refs/heads/" + branch, task_head, old_head)
            # A checkpoint includes every reviewed file. Update only the index;
            # working files remain byte-for-byte intact (no reset/checkout).
            git(worktree, "read-tree", task_head)
        merged = git(top, "merge", "--no-ff", "--no-edit", task_head, check=False)
        if merged.returncode:
            raise WorkspaceError("Git could not complete integration. The task checkpoint is preserved on " + branch + ".\n" +
                                 (merged.stderr or merged.stdout).decode("utf-8", "replace").strip(), "merge_failed")
        return {"ok": True, "integrated": True, "root": str(task_root), "branch": branch,
                "base": base, "head": output(top, "rev-parse", "HEAD"), "task_head": task_head,
                "destination_branch": destination_branch.removeprefix("refs/heads/"),
                "fingerprint": fingerprint(worktree, base)[0]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    add = sub.add_parser("create")
    add.add_argument("--root", required=True); add.add_argument("--storage", required=True); add.add_argument("--id", required=True)
    for name in ("inspect", "integrate"):
        command = sub.add_parser(name)
        for argument in ("root", "workspace", "branch", "base"):
            command.add_argument("--" + argument, required=True)
        if name == "integrate":
            command.add_argument("--expected", required=True)
    args = parser.parse_args(argv)
    try:
        if args.operation == "create":
            result = create(args.root, args.storage, args.id)
        elif args.operation == "inspect":
            result = inspect(args.root, args.workspace, args.branch, args.base)
        else:
            result = integrate(args.root, args.workspace, args.branch, args.base, args.expected)
    except WorkspaceError as error:
        result = {"ok": False, "error": str(error), "code": error.code}
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        result = {"ok": False, "error": str(error), "code": "io_error"}
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
