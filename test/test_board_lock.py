#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Board locks (board_lock.py): one lock file per board, owner checks, all-or-nothing acquire.

import os
import sys
import tempfile
import unittest
import subprocess

import board_lock
from board_lock import BoardLockError

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "board_lock.py")

class TestBoardLock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_acquire_release(self):
        self.assertIsNone(board_lock.holder("1-3", self.dir))
        board_lock.acquire("1-3", "session-a", "stream test", self.dir)
        self.assertEqual(board_lock.holder("1-3", self.dir)["owner"], "session-a")
        # Same owner: no-op. Other owner: refused.
        board_lock.acquire("1-3", "session-a", lock_dir=self.dir)
        with self.assertRaisesRegex(BoardLockError, "locked by session-a"):
            board_lock.acquire("1-3", "session-b", lock_dir=self.dir)
        # Only the owner releases, unless forced.
        with self.assertRaisesRegex(BoardLockError, "not by 'session-b'"):
            board_lock.release("1-3", "session-b", lock_dir=self.dir)
        self.assertTrue(board_lock.release("1-3", "session-a", lock_dir=self.dir))
        self.assertFalse(board_lock.release("1-3", "session-a", lock_dir=self.dir))
        board_lock.acquire("1-5", "session-a", lock_dir=self.dir)
        self.assertTrue(board_lock.release("1-5", force=True, lock_dir=self.dir))

    def test_check(self):
        board_lock.check("1-3", None, self.dir) # Free: OK for anyone.
        board_lock.acquire("1-3", "session-a", lock_dir=self.dir)
        board_lock.check("1-3", "session-a", self.dir)
        with self.assertRaisesRegex(BoardLockError, "SOC2SOC_LOCK_OWNER"):
            board_lock.check("1-3", None, self.dir)
        with self.assertRaisesRegex(BoardLockError, "not by 'session-b'"):
            board_lock.check("1-3", "session-b", self.dir)

    def test_owner_required_and_names_checked(self):
        with self.assertRaisesRegex(BoardLockError, "owner is required"):
            board_lock.acquire("1-3", None, lock_dir=self.dir)
        with self.assertRaisesRegex(BoardLockError, "Invalid board"):
            board_lock.acquire("../etc", "session-a", lock_dir=self.dir)

    def test_cli_all_or_nothing(self):
        env = dict(os.environ, SOC2SOC_LOCK_DIR=self.dir)
        run = lambda *a: subprocess.run([sys.executable, SCRIPT, *a], env=env, capture_output=True, text=True)
        self.assertEqual(run("acquire", "1-5", "--owner=session-b").returncode, 0)
        # 1-3 is free but 1-5 is held by session-b: session-a gets neither.
        r = run("acquire", "1-3", "1-5", "--owner=session-a")
        self.assertEqual(r.returncode, 1)
        self.assertIn("locked by session-b", r.stderr)
        self.assertIsNone(board_lock.holder("1-3", self.dir))
        status = run("status").stdout
        self.assertIn("1-5: session-b", status)
        self.assertNotIn("1-3", status)
