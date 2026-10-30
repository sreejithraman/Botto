from __future__ import annotations

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import sqlite3
import stat


class Storage:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        if self.directory.is_symlink():
            raise ValueError("Notification storage must not be a symlink.")
        self.directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        self._private(self.directory, 0o700)
        self.path = self.directory / "push.sqlite3"
        self._create_private(self.path)
        self.lock_path = self.directory / "dispatch.lock"
        self._create_private(self.lock_path)
        with self.transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, generation INTEGER NOT NULL, active INTEGER NOT NULL,
                    record TEXT NOT NULL, key TEXT, presence_revision INTEGER NOT NULL DEFAULT 0,
                    sync_state TEXT NOT NULL DEFAULT 'pending');
                CREATE TABLE IF NOT EXISTS operations (
                    id TEXT PRIMARY KEY, digest TEXT NOT NULL, result TEXT NOT NULL, created INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, method TEXT NOT NULL, path TEXT NOT NULL,
                    body TEXT NOT NULL, device TEXT, generation INTEGER, kind TEXT NOT NULL,
                    available INTEGER NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS cancellations (id TEXT PRIMARY KEY, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS destinations (identity TEXT PRIMARY KEY, observed INTEGER NOT NULL);
            """)

    @staticmethod
    def _private(path, mode):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Notification storage must be owned by the current user.")
        os.chmod(path, mode)

    @classmethod
    def _create_private(cls, path):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        except FileExistsError:
            pass
        cls._private(path, 0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout = 10000")
        return db

    @contextmanager
    def transaction(self):
        db = self.connect()
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            if db.in_transaction:
                db.commit()
        except BaseException:
            if db.in_transaction:
                db.rollback()
            raise
        finally:
            db.close()

    @contextmanager
    def dispatch_lock(self, *, blocking=True):
        with self.lock_path.open("r+b") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                yield False
                return
            try:
                yield True
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

