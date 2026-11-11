#!/usr/bin/env python3

#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Board locks: one lock file per board on the host, so that several sessions (people or agents)
# sharing a bench do not load, reset or reconfigure the same board at the same time.
#
# A board is identified by its host USB port (e.g. 1-3, as for acorn_soc2soc.py --usb-port). The lock
# is a file created atomically in the lock directory (SOC2SOC_LOCK_DIR, default /tmp/soc2soc-locks),
# holding who took it, for what and since when. The owner is a free name that identifies the session
# (e.g. "stream-test-nuc"): pass it with --owner or the SOC2SOC_LOCK_OWNER environment variable.
#
#   ./board_lock.py status
#   ./board_lock.py acquire 1-3 1-5 --owner=<session> --purpose="stream test"
#   ./board_lock.py release 1-3 1-5 --owner=<session>
#   ./board_lock.py release 1-3 --force          # Only after checking the holder is gone.
#
# Locks are released explicitly (they survive the process that took them, as a session spans many
# commands) and disappear at reboot (/tmp).

import os
import sys
import json
import time
import socket
import argparse

LOCK_DIR = os.environ.get("SOC2SOC_LOCK_DIR", "/tmp/soc2soc-locks")

class BoardLockError(Exception):
    pass

def _path(board, lock_dir=None):
    if not board or ("/" in board) or board.startswith("."):
        raise BoardLockError(f"Invalid board name: {board!r}.")
    return os.path.join(lock_dir or LOCK_DIR, f"{board}.lock")

def holder(board, lock_dir=None):
    """Return the lock information of a board (dict), or None when it is free."""
    try:
        with open(_path(board, lock_dir)) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {"owner": "?", "purpose": "unreadable lock file"}

def describe(info):
    since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(info["since"])) if "since" in info else "?"
    return f"{info.get('owner', '?')} ({info.get('purpose', '')}, since {since}, host {info.get('host', '?')})"

def acquire(board, owner, purpose="", lock_dir=None):
    """Take the lock of a board for owner (no-op if owner already holds it)."""
    if not owner:
        raise BoardLockError("An owner is required (--owner or SOC2SOC_LOCK_OWNER).")
    path = _path(board, lock_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    info = {"owner": owner, "purpose": purpose, "since": time.time(), "host": socket.gethostname()}
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o664)
    except FileExistsError:
        current = holder(board, lock_dir)
        if current is not None and current.get("owner") == owner:
            return current
        raise BoardLockError(f"Board {board} is locked by {describe(current or {})}.")
    with os.fdopen(fd, "w") as f:
        json.dump(info, f)
    return info

def release(board, owner=None, force=False, lock_dir=None):
    """Release the lock of a board (only by its owner, unless force)."""
    current = holder(board, lock_dir)
    if current is None:
        return False
    if (not force) and (current.get("owner") != owner):
        raise BoardLockError(f"Board {board} is locked by {describe(current)}, not by {owner!r} "
            "(use --force only after checking the holder is gone).")
    os.remove(_path(board, lock_dir))
    return True

def check(board, owner=None, lock_dir=None):
    """Raise if the board is locked by someone else than owner."""
    current = holder(board, lock_dir)
    if current is not None and current.get("owner") != owner:
        raise BoardLockError(f"Board {board} is locked by {describe(current)}"
            + (f", not by {owner!r}." if owner else " (set SOC2SOC_LOCK_OWNER to its owner name)."))

def main():
    parser = argparse.ArgumentParser(description="Board locks (one per board, by host USB port).")
    parser.add_argument("command", choices=["status", "acquire", "release"])
    parser.add_argument("boards",    nargs="*", help="Boards (host USB ports, e.g. 1-3 1-5).")
    parser.add_argument("--owner",   default=os.environ.get("SOC2SOC_LOCK_OWNER"), help="Owner name (default: SOC2SOC_LOCK_OWNER).")
    parser.add_argument("--purpose", default="", help="What the boards are used for.")
    parser.add_argument("--force",   action="store_true", help="release: remove a lock held by another owner.")
    args = parser.parse_args()

    try:
        if args.command == "status":
            if args.boards:
                boards = args.boards
            elif os.path.isdir(LOCK_DIR):
                boards = sorted(f[:-len(".lock")] for f in os.listdir(LOCK_DIR) if f.endswith(".lock"))
            else:
                boards = []
            if not boards:
                print("No board locked.")
            for board in boards:
                info = holder(board)
                print(f"{board}: " + (describe(info) if info else "free"))
        elif args.command == "acquire":
            taken = []
            try:
                for board in args.boards:
                    already = (holder(board) or {}).get("owner") == args.owner
                    acquire(board, args.owner, args.purpose)
                    if not already:
                        taken.append(board)
            except BoardLockError:
                # All or nothing: release what this call took.
                for board in taken:
                    release(board, args.owner)
                raise
            print(f"Locked {' '.join(args.boards)} for {args.owner}.")
        elif args.command == "release":
            for board in args.boards:
                print(f"{board}: " + ("released" if release(board, args.owner, args.force) else "was not locked"))
    except BoardLockError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
