from __future__ import annotations

import os
from pathlib import Path

APP_NAME = "Agent Monitor"


def data_dir() -> Path:
    override = os.getenv("AGENT_MONITOR_DATA_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / APP_NAME


def config_path() -> Path:
    override = os.getenv("AGENT_MONITOR_CONFIG")
    return Path(override).expanduser() if override else data_dir() / "config.json"
