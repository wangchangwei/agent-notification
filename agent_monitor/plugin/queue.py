from __future__ import annotations

import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

def _data_dir() -> Path:
    override = os.getenv("AGENT_MONITOR_DATA_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Agent Monitor"
SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
 event_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, parent_task_id TEXT, device_id TEXT NOT NULL,
 event_type TEXT NOT NULL, status TEXT NOT NULL, tool_name TEXT, duration_ms INTEGER,
 occurred_at REAL NOT NULL, summary TEXT NOT NULL, title TEXT, brand TEXT, delivered INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS event_delivery_idx ON events(delivered, occurred_at);
"""

TITLE_LIMIT = 24


def enqueue(*, task_id: str, parent_task_id: str | None, device_id: str,
            event_type: str, status: str, tool_name: str | None = None,
            duration_ms: int | None = None, summary: str, title: str | None = None,
            brand: str | None = None) -> None:
    data_dir = _data_dir()
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(data_dir, 0o700)
    db_path = data_dir / "queue.sqlite3"
    db = sqlite3.connect(db_path, timeout=2)
    os.chmod(db_path, 0o600)
    try:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA busy_timeout=2000")
        db.executescript(SCHEMA)
        columns = {row[1] for row in db.execute("PRAGMA table_info(events)").fetchall()}
        if "title" not in columns:
            db.execute("ALTER TABLE events ADD COLUMN title TEXT")
        if "brand" not in columns:
            db.execute("ALTER TABLE events ADD COLUMN brand TEXT")
        stamp = time.time()
        db.execute(
            "INSERT INTO events(event_id,task_id,parent_task_id,device_id,event_type,status,tool_name,duration_ms,occurred_at,summary,title,brand) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), task_id, parent_task_id, device_id, event_type,
             status, tool_name, duration_ms, stamp, summary[:96], title[:TITLE_LIMIT] if title else None,
             brand[:16] if brand else None),
        )
        db.execute("DELETE FROM events WHERE occurred_at < ?", (stamp - 7 * 86400,))
        db.execute("DELETE FROM events WHERE event_id IN (SELECT event_id FROM events ORDER BY occurred_at DESC LIMIT -1 OFFSET 4000)")
        db.commit()
    finally:
        db.close()
