"""Kernel-held worktree writer leases shared by agents and integration."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import stat

@contextlib.contextmanager
def writer_lock(cwd: str, mode: str, *, inherit: bool = False):
    """One Kiln writer per canonical directory, across windows/state profiles.

    The kernel releases the lease when its owner exits. Keep the empty file:
    unlinking it would let a later process lock a different inode. Native
    takeover inherits the descriptor across exec for the CLI's lifetime.
    """
    if mode != "edit":
        yield
        return
    root = Path(cwd).resolve(strict=True)
    if not root.is_dir():
        raise ValueError(f"Workspace is not a directory: {root}")
    directory = Path("/tmp") / ("kiln-writers-" + str(os.getuid()))
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Kiln writer lock directory must be private and owned by the current user")
    identity = hashlib.sha256(os.fsencode(root)).hexdigest()
    flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(directory / (identity + ".lock"), flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Kiln writer lock file has invalid ownership")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another Kiln editing agent owns this worktree. Stop it or use a different task worktree.") from error
        if inherit:
            os.set_inheritable(descriptor, True)
        yield descriptor
    finally:
        os.close(descriptor)
