from __future__ import annotations

import json
import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from .paths import data_dir

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    event_id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    parent_task_id TEXT,
    device_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    status TEXT NOT NULL,
    tool_name TEXT,
    duration_ms INTEGER,
    occurred_at REAL NOT NULL,
    summary TEXT NOT NULL,
    title TEXT,
    brand TEXT,
    delivered INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS event_delivery_idx ON events(delivered, occurred_at);
"""

TITLE_LIMIT = 24


def _migrate(db: sqlite3.Connection) -> None:
    """An existing queue predates the title column; add it instead of dropping history."""
    columns = {row[1] for row in db.execute("PRAGMA table_info(events)").fetchall()}
    if "title" not in columns:
        db.execute("ALTER TABLE events ADD COLUMN title TEXT")
    if "brand" not in columns:
        db.execute("ALTER TABLE events ADD COLUMN brand TEXT")


def database_path() -> Path:
    return data_dir() / "queue.sqlite3"


def connect() -> sqlite3.Connection:
    path = database_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    connection = sqlite3.connect(path, timeout=3)
    os.chmod(path, 0o600)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=3000")
    connection.executescript(SCHEMA)
    _migrate(connection)
    return connection


def enqueue(*, task_id: str, parent_task_id: str | None, device_id: str,
            event_type: str, status: str, tool_name: str | None = None,
            duration_ms: int | None = None, summary: str, title: str | None = None,
            brand: str | None = None) -> str:
    event_id = str(uuid.uuid4())
    stamp = time.time()
    with connect() as db:
        db.execute(
            "INSERT OR IGNORE INTO events(event_id,task_id,parent_task_id,device_id,event_type,status,tool_name,duration_ms,occurred_at,summary,title,brand) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (event_id, task_id, parent_task_id, device_id, event_type, status,
             tool_name, duration_ms, stamp, summary[:96], title[:TITLE_LIMIT] if title else None,
             brand[:16] if brand else None),
        )
        db.execute("DELETE FROM events WHERE occurred_at < ?", (stamp - 7 * 86400,))
        db.execute("DELETE FROM events WHERE event_id IN (SELECT event_id FROM events ORDER BY occurred_at DESC LIMIT -1 OFFSET 4000)")
    return event_id


def pending(limit: int = 50, device_id: str | None = None) -> list[dict[str, Any]]:
    query = ("SELECT event_id,task_id,parent_task_id,device_id,event_type,status,tool_name,duration_ms,occurred_at,summary,title,brand "
             "FROM events WHERE delivered=0")
    params: list[Any] = []
    if device_id:
        query += " AND device_id=?"
        params.append(device_id)
    query += " ORDER BY occurred_at DESC LIMIT ?"
    params.append(max(1, min(limit, 50)))
    with connect() as db:
        rows = db.execute(query, tuple(params)).fetchall()
    fields = ("event_id", "task_id", "parent_task_id", "device_id", "event_type", "status", "tool_name", "duration_ms", "occurred_at", "summary", "title", "brand")
    return [dict(zip(fields, row)) for row in rows]


def drop_other_devices(device_id: str) -> int:
    """Events stamped by a previous device registration can never be accepted by the bridge."""
    with connect() as db:
        cursor = db.execute("DELETE FROM events WHERE device_id != ?", (device_id,))
        return cursor.rowcount


def mark_delivered(event_ids: list[str]) -> None:
    if not event_ids:
        return
    with connect() as db:
        db.executemany("UPDATE events SET delivered=1 WHERE event_id=?", [(item,) for item in event_ids])


def queued_count() -> int:
    with connect() as db:
        return int(db.execute("SELECT COUNT(*) FROM events WHERE delivered=0").fetchone()[0])


def clear_history() -> int:
    with connect() as db:
        cursor = db.execute("DELETE FROM events")
        return cursor.rowcount
