from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import uuid
from datetime import UTC, datetime
from typing import Any, Literal

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field

app = FastAPI(title="Agent Monitor Bridge", version="0.1.0", docs_url=None, redoc_url=None)
HISTORY_DAYS = 7
HISTORY_LIMIT = 3000
HEARTBEAT_TTL = 120


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SetupRequest(StrictModel):
    owner_id: str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]{16,64}$")
    device_name: str = Field(default="Mac", min_length=1, max_length=48)


class PairRedeemRequest(StrictModel):
    code: str = Field(min_length=8, max_length=32)


class PushTokenRequest(StrictModel):
    token: str = Field(min_length=32, max_length=512, pattern=r"^[0-9a-fA-F]+$")


class DeviceRenameRequest(StrictModel):
    device_name: str = Field(min_length=1, max_length=40)


def _clean_device_name(raw: str) -> str:
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(raw or ""))
    return re.sub(r"\s+", " ", text).strip()[:40]


class MonitorEvent(StrictModel):
    event_id: str = Field(pattern=r"^[a-fA-F0-9-]{36}$")
    task_id: str = Field(pattern=r"^[a-fA-F0-9-]{36}$")
    parent_task_id: str | None = Field(default=None, pattern=r"^[a-fA-F0-9-]{36}$")
    device_id: str = Field(pattern=r"^[a-fA-F0-9-]{36}$")
    event_type: Literal["started", "tool_started", "tool_finished", "waiting", "resumed", "completed", "failed", "interrupted", "incomplete"]
    status: Literal["running", "waiting", "completed", "failed", "interrupted"]
    tool_name: str | None = Field(default=None, max_length=64, pattern=r"^[A-Za-z0-9_.:-]*$")
    duration_ms: int | None = Field(default=None, ge=0, le=86_400_000)
    occurred_at: float = Field(ge=1_600_000_000, le=4_102_444_800)
    # Optional and unused: the server always writes a fixed summary of its own, so a client
    # never needs to send prose at all.
    summary: str | None = Field(default=None, max_length=96)
    # A short, scrubbed request title. Re-scrubbed below: never trust caller-supplied prose.
    # Accept a generous bound and truncate in _clean_title: a single over-long title must not
    # reject the whole batch.
    title: str | None = Field(default=None, max_length=512)
    # Which agent produced the task (hermes, codex, pi, …). A slug, never free text.
    brand: str | None = Field(default=None, max_length=16)


class EventBatch(StrictModel):
    events: list[MonitorEvent] = Field(min_length=1, max_length=50)


def _redis_pipeline(commands: list[list[object]]) -> list[Any]:
    # Accept both the native Upstash names and the aliases the Vercel Marketplace integration injects.
    url = (os.getenv("UPSTASH_REDIS_REST_URL") or os.getenv("KV_REST_API_URL") or "").rstrip("/")
    token = os.getenv("UPSTASH_REDIS_REST_TOKEN") or os.getenv("KV_REST_API_TOKEN") or ""
    if not url or not token:
        raise HTTPException(status_code=503, detail="State store is not configured")
    try:
        with httpx.Client(timeout=4.0) as client:
            response = client.post(f"{url}/pipeline", headers={"Authorization": f"Bearer {token}"}, json=commands)
            response.raise_for_status()
            payload = response.json()
        if not isinstance(payload, list) or len(payload) != len(commands):
            raise ValueError("Unexpected pipeline response")
        results: list[object] = []
        for item in payload:
            if not isinstance(item, dict) or item.get("error"):
                raise ValueError("State-store command failed")
            results.append(item.get("result"))
        return results
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=503, detail="State store is temporarily unavailable") from exc


def _auth_context(authorization: str | None = Header(default=None)) -> dict[str, str]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Unauthorized")
    token = authorization[7:].strip()
    if not token or len(token) > 256:
        raise HTTPException(status_code=401, detail="Unauthorized")
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    values = _redis_pipeline([["GET", f"auth:{token_hash}"]])
    try:
        auth_value = values[0]
        if not isinstance(auth_value, str):
            raise ValueError
        context = json.loads(auth_value)
        if context.get("kind") not in {"mac", "phone"} or not context.get("owner_id"):
            raise ValueError
        context["token_hash"] = token_hash
        return context
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Unauthorized") from exc


def _require_kind(context: dict[str, str], expected: str) -> None:
    if context.get("kind") != expected:
        raise HTTPException(status_code=403, detail="This device is not allowed to perform that action")


TITLE_MAX = 24
_TITLE_SCRUBBERS = (
    re.compile(r"```.*?```", re.S),
    re.compile(r"`[^`]*`"),
    re.compile(r"https?://\S+"),
    re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),
    re.compile(r"(?:/Users|/home|/private|/var|/opt|~)/\S*"),
    re.compile(r"[A-Za-z]:\\\\?\S*"),
    re.compile(r"\b[0-9a-fA-F]{24,}\b"),
    re.compile(r"[\x00-\x1f\x7f]"),
)


def _clean_title(raw: str | None) -> str | None:
    text = str(raw or "")
    if not text.strip():
        return None
    for pattern in _TITLE_SCRUBBERS:
        text = pattern.sub(" ", text)
    text = re.sub(r"\s+", " ", text).strip(" :;,.。，；：")
    if not text:
        return None
    return text if len(text) <= TITLE_MAX else text[: TITLE_MAX - 1].rstrip() + "…"


def _safe_event(event: MonitorEvent) -> dict[str, object]:
    allowed_summaries = {
        "started": "Turn started",
        "tool_started": "Tool call",
        "tool_finished": "Tool finished",
        "waiting": "Waiting for input",
        "resumed": "Resumed",
        "completed": "Turn finished",
        "failed": "Failed",
        "interrupted": "Interrupted",
        "incomplete": "Did not finish",
    }
    # Summary is generated from a fixed local string; never trust caller-supplied prose.
    summary = allowed_summaries[event.event_type]
    if event.event_type == "tool_started" and event.tool_name:
        summary = f"Tool: {event.tool_name}"
    brand = (event.brand or "").strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,15}", brand):
        brand = None
    return {
        "event_id": event.event_id.lower(),
        "task_id": event.task_id.lower(),
        "parent_task_id": event.parent_task_id.lower() if event.parent_task_id else None,
        "device_id": event.device_id.lower(),
        "event_type": event.event_type,
        "status": event.status,
        "tool_name": event.tool_name,
        "duration_ms": event.duration_ms,
        "occurred_at": event.occurred_at,
        "summary": summary,
        "title": _clean_title(event.title),
        "brand": brand,
    }


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _apns_jwt() -> tuple[str, str] | None:
    team = os.getenv("APNS_TEAM_ID")
    key_id = os.getenv("APNS_KEY_ID")
    encoded_key = os.getenv("APNS_PRIVATE_KEY_B64")
    if not team or not key_id or not encoded_key or not os.getenv("APNS_TOPIC"):
        return None
    try:
        pem = base64.b64decode(encoded_key, validate=True)
        key = serialization.load_pem_private_key(pem, password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            return None
        header = _b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
        claims = _b64url(json.dumps({"iss": team, "iat": int(time.time())}, separators=(",", ":")).encode())
        message = f"{header}.{claims}".encode("ascii")
        der = key.sign(message, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        signature = _b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        return f"{header}.{claims}.{signature}", os.getenv("APNS_TOPIC", "")
    except Exception:
        return None


def _send_apns(push_token: str, event: dict[str, object]) -> bool:
    signed = _apns_jwt()
    if signed is None:
        return False
    jwt, topic = signed
    host = "https://api.sandbox.push.apple.com" if os.getenv("APNS_USE_SANDBOX", "true").lower() == "true" else "https://api.push.apple.com"
    payload = {
        "aps": {
            "alert": {"title": "Agent Monitor", "body": str(event["summary"])},
            "sound": "default",
            "thread-id": str(event["task_id"]),
        },
        "event_id": event["event_id"],
        "device_id": event["device_id"],
    }
    try:
        with httpx.Client(http2=True, timeout=4.0) as client:
            result = client.post(
                f"{host}/3/device/{push_token}",
                headers={"authorization": f"bearer {jwt}", "apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10", "apns-collapse-id": str(event["task_id"])[:64], "content-type": "application/json"},
                json=payload,
            )
        return result.status_code == 200
    except Exception:
        return False


@app.get("/healthz")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "agent-monitor-bridge"}


@app.post("/v1/setup")
def setup(request: SetupRequest, x_monitor_bootstrap: str | None = Header(default=None)) -> dict[str, str]:
    expected = os.getenv("MONITOR_BOOTSTRAP_TOKEN", "")
    if not expected or not x_monitor_bootstrap or not hmac.compare_digest(expected, x_monitor_bootstrap):
        raise HTTPException(status_code=401, detail="Invalid bootstrap credential")
    owner_id = request.owner_id or secrets.token_urlsafe(18)
    device_id = str(uuid.uuid4())
    device_token = secrets.token_urlsafe(36)
    token_hash = hashlib.sha256(device_token.encode()).hexdigest()
    values = _redis_pipeline([
        ["SET", f"auth:{token_hash}", json.dumps({"kind": "mac", "owner_id": owner_id, "device_id": device_id})],
        ["SADD", f"owner:{owner_id}:devices", device_id],
        ["SET", f"device:{device_id}", json.dumps({"device_id": device_id, "device_name": request.device_name, "owner_id": owner_id, "token_hash": token_hash})],
    ])
    if values[0] != "OK":
        raise HTTPException(status_code=503, detail="Could not provision device")
    return {"owner_id": owner_id, "device_id": device_id, "device_token": device_token}


@app.post("/v1/pair-codes")
def create_pair_code(context: dict[str, str] = Depends(_auth_context)) -> dict[str, object]:
    _require_kind(context, "mac")
    for _ in range(3):
        code = secrets.token_urlsafe(9)
        values = _redis_pipeline([["SET", f"pair:{hashlib.sha256(code.encode()).hexdigest()}", context["owner_id"], "EX", 300, "NX"]])
        if values[0] == "OK":
            return {"code": code, "expires_in_seconds": 300, "deep_link": f"agent-monitor://pair?code={code}"}
    raise HTTPException(status_code=503, detail="Could not issue a pairing code")


@app.post("/v1/pair/redeem")
def redeem_pairing(request: PairRedeemRequest) -> dict[str, str]:
    code_hash = hashlib.sha256(request.code.encode()).hexdigest()
    results = _redis_pipeline([["GETDEL", f"pair:{code_hash}"]])
    owner_id = results[0]
    if not isinstance(owner_id, str) or not owner_id:
        raise HTTPException(status_code=410, detail="Pairing code is expired or already used")
    phone_token = secrets.token_urlsafe(36)
    phone_hash = hashlib.sha256(phone_token.encode()).hexdigest()
    values = _redis_pipeline([["SET", f"auth:{phone_hash}", json.dumps({"kind": "phone", "owner_id": owner_id})]])
    if values[0] != "OK":
        raise HTTPException(status_code=503, detail="Could not pair this phone")
    return {"owner_id": owner_id, "access_token": phone_token}


@app.post("/v1/events")
def ingest_events(batch: EventBatch, context: dict[str, str] = Depends(_auth_context)) -> dict[str, int]:
    _require_kind(context, "mac")
    if len(batch.events) > 50:
        raise HTTPException(status_code=413, detail="Event batch is too large")
    now = time.time()
    watermark_key = f"owner:{context['owner_id']}:events-cleared-before"
    cleared_raw = _redis_pipeline([["GET", watermark_key]])[0]
    try:
        cleared_before = float(cleared_raw or 0)
    except (TypeError, ValueError):
        cleared_before = 0.0
    commands: list[list[object]] = []
    written: list[tuple[str, str, float]] = []
    latest_batch_state: dict[str, tuple[float, dict[str, object]]] = {}
    for item in batch.events:
        if item.device_id.lower() != context.get("device_id", "").lower():
            raise HTTPException(status_code=403, detail="Device does not match credential")
        if item.occurred_at <= cleared_before:
            continue
        event = _safe_event(item)
        task_id = str(event["task_id"])
        prior = latest_batch_state.get(task_id)
        if prior is None or item.occurred_at > prior[0]:
            latest_batch_state[task_id] = (item.occurred_at, event)
        score = int(item.occurred_at * 1000)
        history_key = f"owner:{context['owner_id']}:device:{item.device_id.lower()}:events"
        encoded = json.dumps(event, ensure_ascii=True, separators=(",", ":"))
        written.append((history_key, encoded, item.occurred_at))
        commands.extend([
            ["ZADD", history_key, score, encoded],
            ["ZREMRANGEBYSCORE", history_key, "-inf", int((now - HISTORY_DAYS * 86400) * 1000)],
            ["ZREMRANGEBYRANK", history_key, 0, -HISTORY_LIMIT - 1],
        ])
    if commands:
        _redis_pipeline(commands)
        # A clear may have landed between the watermark read above and this write, which would
        # resurrect pre-clear history. Re-read the watermark and drop whatever it now excludes.
        rechecked_raw = _redis_pipeline([["GET", watermark_key]])[0]
        try:
            rechecked = float(rechecked_raw or 0)
        except (TypeError, ValueError):
            rechecked = 0.0
        if rechecked > cleared_before:
            resurrected: list[list[object]] = [
                ["ZREM", key, member] for key, member, occurred_at in written if occurred_at <= rechecked
            ]
            if resurrected:
                _redis_pipeline(resurrected)
    notifications = [
        event for timestamp, event in latest_batch_state.values()
        if event["event_type"] in {"waiting", "completed", "failed"}
        and now - 120 <= timestamp <= now + 30
    ]
    # Push calls are synchronous and bounded; no background work is scheduled after the function returns.
    if notifications:
        tokens = _redis_pipeline([["GET", f"owner:{context['owner_id']}:push-token"]])[0]
        if isinstance(tokens, str) and tokens:
            # Only alert when this event is still the task's latest stored state, so an older
            # queued event in a later batch cannot ring after a newer outcome was already shown.
            history_keys = [
                f"owner:{context['owner_id']}:device:{event['device_id']}:events" for event in notifications
            ]
            tops = _redis_pipeline([["ZREVRANGE", key, 0, 0] for key in history_keys])
            current: list[dict[str, object]] = []
            for event, top in zip(notifications, tops):
                latest_time = 0.0
                if isinstance(top, list) and top:
                    try:
                        latest_time = float(json.loads(top[0]).get("occurred_at", 0))
                    except (TypeError, ValueError, AttributeError):
                        latest_time = 0.0
                if float(str(event["occurred_at"])) >= latest_time:
                    current.append(event)
            # A retried batch must not re-alert: one push claim per event ID, released after 15 minutes.
            claimed = _redis_pipeline([
                ["SET", f"notify:{event['event_id']}", "1", "EX", 900, "NX"] for event in current
            ]) if current else []
            for event, claim in zip(current, claimed):
                if claim == "OK":
                    _send_apns(tokens, event)
    return {"accepted": len(batch.events)}


@app.delete("/v1/events")
def clear_events(context: dict[str, str] = Depends(_auth_context)) -> dict[str, bool]:
    _require_kind(context, "phone")
    owner_id = context["owner_id"]
    devices_raw = _redis_pipeline([["SMEMBERS", f"owner:{owner_id}:devices"]])[0]
    devices = devices_raw if isinstance(devices_raw, list) else []
    valid_ids = [str(value).lower() for value in devices if re.fullmatch(r"[a-fA-F0-9-]{36}", str(value))]
    commands: list[list[object]] = [["SET", f"owner:{owner_id}:events-cleared-before", time.time()]]
    commands.extend(["DEL", f"owner:{owner_id}:device:{device_id}:events"] for device_id in valid_ids)
    _redis_pipeline(commands)
    return {"cleared": True}


@app.post("/v1/heartbeat")
def heartbeat(context: dict[str, str] = Depends(_auth_context)) -> dict[str, int]:
    _require_kind(context, "mac")
    device_id = context.get("device_id", "")
    if not device_id:
        raise HTTPException(status_code=401, detail="Unauthorized")
    now = int(time.time())
    _redis_pipeline([["SET", f"device:{device_id}:last-seen", now, "EX", 7 * 86400]])
    return {"server_time": now, "stale_after_seconds": HEARTBEAT_TTL}


@app.get("/v1/snapshot")
def snapshot(context: dict[str, str] = Depends(_auth_context)) -> dict[str, object]:
    _require_kind(context, "phone")
    owner_id = context["owner_id"]
    devices_raw = _redis_pipeline([["SMEMBERS", f"owner:{owner_id}:devices"]])[0]
    device_values = devices_raw if isinstance(devices_raw, list) else []
    valid_ids = [str(value).lower() for value in device_values if re.fullmatch(r"[a-fA-F0-9-]{36}", str(value))]
    now = int(time.time())
    cutoff = int((now - HISTORY_DAYS * 86400) * 1000)
    event_commands: list[list[object]] = []
    for device_id in valid_ids:
        key = f"owner:{owner_id}:device:{device_id}:events"
        event_commands.extend([
            ["ZREMRANGEBYSCORE", key, "-inf", cutoff],
            ["ZREVRANGE", key, 0, HISTORY_LIMIT - 1],
        ])
    event_results = _redis_pipeline(event_commands) if event_commands else []
    seen_raw = _redis_pipeline([["MGET", *[f"device:{device_id}:last-seen" for device_id in valid_ids]]])[0] if valid_ids else []
    seen_items = seen_raw if isinstance(seen_raw, list) else []
    names_raw = _redis_pipeline([["MGET", *[f"device:{device_id}" for device_id in valid_ids]]])[0] if valid_ids else []
    names_items = names_raw if isinstance(names_raw, list) else []
    devices = []
    for index, (device_id, last_seen) in enumerate(zip(valid_ids, seen_items)):
        try:
            observed = int(last_seen)
        except (ValueError, TypeError):
            observed = 0
        device_name = ""
        if index < len(names_items) and isinstance(names_items[index], str):
            try:
                device_name = _clean_device_name(str(json.loads(names_items[index]).get("device_name") or ""))
            except (TypeError, ValueError):
                device_name = ""
        devices.append({"device_id": device_id, "device_name": device_name,
                        "last_seen": observed, "online": observed > 0 and now - observed <= HEARTBEAT_TTL})
    events: list[dict[str, object]] = []
    for index in range(1, len(event_results), 2):
        values = event_results[index]
        for value in values if isinstance(values, list) else []:
            try:
                item = json.loads(value)
                if isinstance(item, dict) and item.get("occurred_at", 0) >= now - HISTORY_DAYS * 86400:
                    events.append(item)
            except (TypeError, ValueError):
                continue
    events.sort(key=lambda item: item.get("occurred_at") if isinstance(item.get("occurred_at"), (int, float)) else 0, reverse=True)
    return {"server_time": now, "history_days": HISTORY_DAYS, "devices": devices, "events": events[:HISTORY_LIMIT]}


@app.put("/v1/push-token")
def set_push_token(request: PushTokenRequest, context: dict[str, str] = Depends(_auth_context)) -> dict[str, bool]:
    _require_kind(context, "phone")
    _redis_pipeline([["SET", f"owner:{context['owner_id']}:push-token", request.token]])
    return {"registered": True}


@app.delete("/v1/push-token")
def delete_push_token(context: dict[str, str] = Depends(_auth_context)) -> dict[str, bool]:
    _require_kind(context, "phone")
    _redis_pipeline([["DEL", f"owner:{context['owner_id']}:push-token"]])
    return {"registered": False}


@app.delete("/v1/pairing")
def unpair_phone(context: dict[str, str] = Depends(_auth_context)) -> dict[str, bool]:
    _require_kind(context, "phone")
    _redis_pipeline([
        ["DEL", f"auth:{context['token_hash']}"],
        ["DEL", f"owner:{context['owner_id']}:push-token"],
    ])
    return {"unpaired": True}


@app.put("/v1/devices/{device_id}")
def rename_device(device_id: str, request: DeviceRenameRequest,
                  context: dict[str, str] = Depends(_auth_context)) -> dict[str, str]:
    _require_kind(context, "phone")
    try:
        device_id = str(uuid.UUID(device_id))
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="Device not found") from exc
    name = _clean_device_name(request.device_name)
    if not name:
        raise HTTPException(status_code=422, detail="Device name is empty")
    owner = context["owner_id"]
    lookup = _redis_pipeline([["GET", f"device:{device_id}"]])[0]
    try:
        if not isinstance(lookup, str):
            raise ValueError
        record = json.loads(lookup)
        if record.get("owner_id") != owner:
            raise ValueError
    except Exception as exc:
        raise HTTPException(status_code=404, detail="Device not found") from exc
    record["device_name"] = name
    _redis_pipeline([["SET", f"device:{device_id}", json.dumps(record)]])
    return {"device_id": device_id, "device_name": name}


@app.delete("/v1/devices/{device_id}")
def revoke_device(device_id: str, context: dict[str, str] = Depends(_auth_context)) -> dict[str, bool]:
    _require_kind(context, "phone")
    try:
        device_id = str(uuid.UUID(device_id))
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="Device not found") from exc
    owner = context["owner_id"]
    lookup = _redis_pipeline([["GET", f"device:{device_id}"]])[0]
    try:
        if not isinstance(lookup, str):
            raise ValueError
        record = json.loads(lookup)
        if record.get("owner_id") != owner:
            raise ValueError
        token_hash = record["token_hash"]
    except Exception as exc:
        raise HTTPException(status_code=404, detail="Device not found") from exc
    _redis_pipeline([
        ["DEL", f"auth:{token_hash}"],
        ["DEL", f"device:{device_id}"],
        ["DEL", f"device:{device_id}:last-seen"],
        ["DEL", f"owner:{owner}:device:{device_id}:events"],
        ["SREM", f"owner:{owner}:devices", device_id],
    ])
    return {"revoked": True}


@app.delete("/v1/device")
def revoke_own_device(context: dict[str, str] = Depends(_auth_context)) -> dict[str, bool]:
    _require_kind(context, "mac")
    owner = context["owner_id"]
    device_id = context.get("device_id", "")
    if not device_id:
        raise HTTPException(status_code=401, detail="Unauthorized")
    _redis_pipeline([
        ["DEL", f"auth:{context['token_hash']}"],
        ["DEL", f"device:{device_id}"],
        ["DEL", f"device:{device_id}:last-seen"],
        ["DEL", f"owner:{owner}:device:{device_id}:events"],
        ["SREM", f"owner:{owner}:devices", device_id],
    ])
    return {"revoked": True}
