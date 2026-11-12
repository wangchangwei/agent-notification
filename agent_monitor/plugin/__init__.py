from __future__ import annotations

import json
import os
import re
import uuid
from pathlib import Path
from threading import Lock
from typing import Any

from .queue import enqueue

_lock = Lock()
_active_tasks: dict[tuple[str, str], str] = {}
_active_turns_by_session: dict[str, str] = {}
_parent_tasks: dict[str, str] = {}
_titles: dict[tuple[str, str], str] = {}

TITLE_MAX = 24
# Anything that can carry a command, a credential or a personal path never reaches a title.
_TITLE_SCRUBBERS = (
    re.compile(r"```.*?```", re.S),
    re.compile(r"`[^`]*`"),
    re.compile(r"https?://\S+"),
    re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),
    re.compile(r"(?:/Users|/home|/private|/var|/opt|~)/\S*"),
    re.compile(r"[A-Za-z]:\\\\?\S*"),
    re.compile(r"\b[0-9a-fA-F]{24,}\b"),
)


def clean_title(raw: Any) -> str | None:
    """First meaningful line of the request, scrubbed of code, links, paths and long tokens."""
    text = str(raw or "")
    if not text.strip():
        return None
    for pattern in _TITLE_SCRUBBERS:
        text = pattern.sub(" ", text)
    candidate = ""
    for line in text.splitlines():
        stripped = re.sub(r"\s+", " ", line.strip().lstrip("#>-*·•0123456789. ")).strip()
        if stripped:
            candidate = stripped
            break
    candidate = "".join(ch for ch in candidate if ch.isprintable()).strip(" :;,.。，；：")
    if not candidate:
        return None
    if len(candidate) > TITLE_MAX:
        candidate = candidate[: TITLE_MAX - 1].rstrip() + "…"
    return candidate


def _resolve(session_id: Any, turn_id: Any) -> tuple[tuple[str, str], str]:
    session = str(session_id or "unknown")
    turn = str(turn_id or "")
    if not turn:
        with _lock:
            turn = _active_turns_by_session.get(session, "unknown")
    key = (session, turn)
    with _lock:
        if key not in _active_tasks:
            _active_tasks[key] = str(uuid.uuid4())
        return key, _active_tasks[key]


def _current_task(session_id: Any, turn_id: Any) -> str:
    return _resolve(session_id, turn_id)[1]


def _parent(session_id: Any) -> str | None:
    with _lock:
        return _parent_tasks.get(str(session_id or ""))


def _emit(*, session_id: Any, turn_id: Any, event_type: str, status: str,
          tool_name: Any = None, duration_ms: Any = None) -> None:
    _config()
    device_id = str(_CONFIG.get("device_id", ""))
    if not device_id:
        return
    key, task_id = _resolve(session_id, turn_id)
    title = None if _CONFIG.get("send_titles") is False else _titles.get(key)
    brand = str(_CONFIG.get("brand") or "hermes").strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,15}", brand):
        brand = "hermes"
    name = str(tool_name or "")
    if name and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", name):
        name = "tool"
    summaries = {
        "started": "Turn started", "tool_started": "Tool call", "tool_finished": "Tool finished",
        "waiting": "Waiting for input", "resumed": "Resumed", "completed": "Turn finished",
        "failed": "Failed", "interrupted": "Interrupted", "incomplete": "Did not finish",
    }
    _duration: int | None = None
    try:
        if duration_ms is not None:
            _duration = max(0, min(int(duration_ms), 86_400_000))
    except (ValueError, TypeError, OverflowError):
        pass
    try:
        enqueue(
            task_id=task_id,
            parent_task_id=_parent(session_id),
            device_id=device_id,
            event_type=event_type,
            status=status,
            tool_name=name or None,
            duration_ms=_duration,
            summary=summaries[event_type],
            title=title,
            brand=brand,
        )
    except Exception:
        # Observer hooks are read-only and fail open; never interfere with agent execution.
        return


_CONFIG: dict[str, str] = {}
_CONFIG_STAMP: tuple[int, int] | None = None


def _config() -> dict[str, str]:
    """Re-read when the config file changes: re-running `setup` must reach a live gateway."""
    global _CONFIG, _CONFIG_STAMP
    try:
        configured = os.getenv("AGENT_MONITOR_CONFIG")
        path = Path(configured).expanduser() if configured else (
            Path.home() / "Library" / "Application Support" / "Agent Monitor" / "config.json"
        )
        stat = path.stat()
        stamp = (stat.st_mtime_ns, stat.st_size)
        if _CONFIG and stamp == _CONFIG_STAMP:
            return _CONFIG
        _CONFIG = json.loads(path.read_text(encoding="utf-8"))
        _CONFIG_STAMP = stamp
    except Exception:
        _CONFIG = {}
        _CONFIG_STAMP = None
    return _CONFIG


def _on_pre_llm(**kw: Any) -> None:
    _config()
    session, turn = str(kw.get("session_id") or "unknown"), str(kw.get("turn_id") or "unknown")
    title = clean_title(kw.get("user_message"))
    with _lock:
        _active_turns_by_session[session] = turn
        if title:
            _titles[(session, turn)] = title
        else:
            _titles.pop((session, turn), None)
    _emit(session_id=session, turn_id=turn, event_type="started", status="running")


def _on_pre_tool(**kw: Any) -> None:
    _emit(session_id=kw.get("session_id"), turn_id=kw.get("turn_id"), event_type="tool_started", status="running", tool_name=kw.get("tool_name"))


def _on_post_tool(**kw: Any) -> None:
    _emit(session_id=kw.get("session_id"), turn_id=kw.get("turn_id"), event_type="tool_finished", status="running", tool_name=kw.get("tool_name"), duration_ms=kw.get("duration_ms"))


def _on_human_request(**kw: Any) -> None:
    # Deliberately discard the prompt: it may contain a command, path or sensitive content.
    _emit(session_id=kw.get("session_id"), turn_id=kw.get("turn_id"), event_type="waiting", status="waiting")


def _on_human_resolved(**kw: Any) -> None:
    _emit(session_id=kw.get("session_id"), turn_id=kw.get("turn_id"), event_type="resumed", status="running")


def _on_session_end(**kw: Any) -> None:
    session_id = str(kw.get("session_id") or "unknown")
    turn_id = str(kw.get("turn_id") or "")
    if not turn_id:
        with _lock:
            turn_id = _active_turns_by_session.get(session_id, "unknown")
    if kw.get("interrupted"):
        event_type, status = "interrupted", "interrupted"
    elif kw.get("failed"):
        event_type, status = "failed", "failed"
    elif kw.get("completed") is True:
        event_type, status = "completed", "completed"
    else:
        # completed=False without a terminal failure is ambiguous; do not claim success or failure.
        event_type, status = "incomplete", "interrupted"
    _emit(session_id=session_id, turn_id=turn_id, event_type=event_type, status=status)
    key = (session_id, turn_id)
    with _lock:
        _active_tasks.pop(key, None)
        _titles.pop(key, None)
        if _active_turns_by_session.get(key[0]) == key[1]:
            _active_turns_by_session.pop(key[0], None)


def _on_subagent_start(**kw: Any) -> None:
    parent_id = _current_task(kw.get("parent_session_id"), kw.get("parent_turn_id"))
    child_session = str(kw.get("child_session_id", ""))
    if child_session:
        with _lock:
            _parent_tasks[child_session] = parent_id


def _on_subagent_stop(**kw: Any) -> None:
    child_session = str(kw.get("child_session_id", ""))
    with _lock:
        _parent_tasks.pop(child_session, None)


def register(ctx: Any) -> None:
    hooks = {
        "pre_llm_call": _on_pre_llm,
        "pre_tool_call": _on_pre_tool,
        "post_tool_call": _on_post_tool,
        "on_human_input_request": _on_human_request,
        "on_human_input_resolved": _on_human_resolved,
        "on_session_end": _on_session_end,
        "subagent_start": _on_subagent_start,
        "subagent_stop": _on_subagent_stop,
    }
    for name, callback in hooks.items():
        ctx.register_hook(name, callback)
