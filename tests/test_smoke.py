"""Local, dependency-free verification for the bridge, probe, plugin and CLI.

Run with: python3 -m unittest discover -s tests -v
No cloud account, Apple credential or network access is required.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
import uuid
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

BOOTSTRAP = "local-test-bootstrap"


class FakeRedis:
    """Minimal in-memory stand-in for the Upstash REST pipeline."""

    def __init__(self) -> None:
        self.strings: dict[str, str] = {}
        self.sets: dict[str, set[str]] = {}
        self.zsets: dict[str, dict[str, float]] = {}

    def pipeline(self, commands: list[list[object]]) -> list[object]:
        return [self._run(command) for command in commands]

    def _run(self, command: list[object]) -> object:
        op, *args = command
        op = str(op).upper()
        if op == "GET":
            return self.strings.get(str(args[0]))
        if op == "GETDEL":
            return self.strings.pop(str(args[0]), None)
        if op == "SET":
            key, value, *options = [str(item) for item in args]
            flags = {option.upper() for option in options}
            if "NX" in flags and key in self.strings:
                return None
            self.strings[key] = value
            return "OK"
        if op == "DEL":
            removed = 0
            for raw in args:
                key = str(raw)
                for store in (self.strings, self.sets, self.zsets):
                    if key in store:
                        del store[key]
                        removed += 1
            return removed
        if op == "SADD":
            self.sets.setdefault(str(args[0]), set()).add(str(args[1]))
            return 1
        if op == "SREM":
            self.sets.setdefault(str(args[0]), set()).discard(str(args[1]))
            return 1
        if op == "SMEMBERS":
            return list(self.sets.get(str(args[0]), set()))
        if op == "MGET":
            return [self.strings.get(str(key)) for key in args]
        if op == "ZADD":
            key, score, member = str(args[0]), float(str(args[1])), str(args[2])
            self.zsets.setdefault(key, {})[member] = score
            return 1
        if op == "ZREMRANGEBYSCORE":
            key, high = str(args[0]), float(str(args[2]))
            members = self.zsets.setdefault(key, {})
            expired = [member for member, score in members.items() if score <= high]
            for member in expired:
                del members[member]
            return len(expired)
        if op == "ZREMRANGEBYRANK":
            key, start, stop = str(args[0]), int(str(args[1])), int(str(args[2]))
            members = self.zsets.setdefault(key, {})
            ordered = sorted(members, key=lambda member: (members[member], member))
            total = len(ordered)
            low = start if start >= 0 else total + start
            high = stop if stop >= 0 else total + stop
            expired = ordered[max(low, 0):high + 1] if high >= max(low, 0) else []
            for member in expired:
                del members[member]
            return len(expired)
        if op == "ZREM":
            key = str(args[0])
            members = self.zsets.get(key, {})
            removed = 0
            for raw in args[1:]:
                if str(raw) in members:
                    del members[str(raw)]
                    removed += 1
            return removed
        if op == "ZREVRANGE":
            key, start, stop = str(args[0]), int(str(args[1])), int(str(args[2]))
            members = self.zsets.get(key, {})
            ordered = sorted(members, key=lambda member: (members[member], member), reverse=True)
            return ordered[start:stop + 1]
        raise AssertionError(f"unsupported command: {command}")


class BridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        os.environ["MONITOR_BOOTSTRAP_TOKEN"] = BOOTSTRAP
        from fastapi.testclient import TestClient
        from agent_monitor import bridge

        self.bridge = bridge
        self.redis = FakeRedis()
        self.pushes: list[str] = []
        self._original_pipeline = bridge._redis_pipeline
        self._original_apns = bridge._send_apns
        bridge._redis_pipeline = self.redis.pipeline
        bridge._send_apns = lambda token, event: self.pushes.append(str(event["event_id"])) or True
        self.client = TestClient(bridge.app)

    def tearDown(self) -> None:
        self.bridge._redis_pipeline = self._original_pipeline
        self.bridge._send_apns = self._original_apns

    def _pair(self) -> tuple[dict[str, str], dict[str, str], dict[str, str]]:
        setup = self.client.post(
            "/v1/setup",
            headers={"x-monitor-bootstrap": BOOTSTRAP},
            json={"device_name": "Mac"},
        ).json()
        mac = {"Authorization": "Bearer " + setup["device_token"]}
        code = self.client.post("/v1/pair-codes", headers=mac, json={}).json()["code"]
        access = self.client.post("/v1/pair/redeem", json={"code": code}).json()["access_token"]
        return setup, mac, {"Authorization": "Bearer " + access}

    def _event(self, setup: dict[str, str], **overrides: object) -> dict[str, object]:
        event: dict[str, object] = {
            "event_id": str(uuid.uuid4()),
            "task_id": str(uuid.uuid4()),
            "device_id": setup["device_id"],
            "event_type": "completed",
            "status": "completed",
            "occurred_at": time.time(),
            "summary": "PRIVATE PROMPT MUST BE DISCARDED",
        }
        event.update(overrides)
        return event

    def test_setup_requires_bootstrap(self) -> None:
        self.assertEqual(self.client.post("/v1/setup", json={}).status_code, 401)
        self.assertEqual(
            self.client.post("/v1/setup", headers={"x-monitor-bootstrap": "wrong"}, json={}).status_code, 401
        )

    def test_pairing_code_is_single_use(self) -> None:
        _, mac, _ = self._pair()
        code = self.client.post("/v1/pair-codes", headers=mac, json={}).json()["code"]
        self.assertEqual(self.client.post("/v1/pair/redeem", json={"code": code}).status_code, 200)
        self.assertEqual(self.client.post("/v1/pair/redeem", json={"code": code}).status_code, 410)

    def test_event_summary_is_rewritten_and_unauthenticated_reads_fail(self) -> None:
        setup, mac, phone = self._pair()
        self.assertEqual(self.client.get("/v1/snapshot").status_code, 401)
        self.assertEqual(self.client.post("/v1/events", json={"events": [self._event(setup)]}).status_code, 401)
        self.assertEqual(self.client.post("/v1/heartbeat", headers=mac, json={}).status_code, 200)
        accepted = self.client.post("/v1/events", headers=mac, json={"events": [self._event(setup)]}).json()
        self.assertEqual(accepted, {"accepted": 1})
        snapshot = self.client.get("/v1/snapshot", headers=phone).json()
        self.assertEqual(len(snapshot["events"]), 1)
        self.assertEqual(snapshot["events"][0]["summary"], "Turn finished")
        self.assertNotIn("PRIVATE PROMPT", json.dumps(snapshot))
        self.assertTrue(snapshot["devices"][0]["online"])

    def test_title_is_scrubbed_again_by_the_bridge(self) -> None:
        setup, mac, phone = self._pair()
        self.client.post("/v1/heartbeat", headers=mac, json={})
        hostile = self._event(setup, title="Fix login https://x.test/a /Users/luyan/x.py")
        self.assertEqual(self.client.post("/v1/events", headers=mac, json={"events": [hostile]}).status_code, 200)
        stored = self.client.get("/v1/snapshot", headers=phone).json()["events"][0]
        self.assertEqual(stored["title"], "Fix login")
        self.assertNotIn("x.test", json.dumps(stored))
        self.assertNotIn("/Users", json.dumps(stored))
        long_event = self._event(setup, title="Reorganise the dense layout across every iOS screen and add a status display")
        self.client.post("/v1/events", headers=mac, json={"events": [long_event]})
        capped = [item for item in self.client.get("/v1/snapshot", headers=phone).json()["events"]
                  if item["event_id"] == long_event["event_id"]][0]["title"]
        self.assertLessEqual(len(capped), 24)
        self.assertTrue(capped.endswith("…"))

    def test_device_cannot_post_events_for_another_device(self) -> None:
        setup, mac, _ = self._pair()
        forged = self._event(setup, device_id=str(uuid.uuid4()))
        self.assertEqual(self.client.post("/v1/events", headers=mac, json={"events": [forged]}).status_code, 403)

    def test_phone_token_cannot_post_events(self) -> None:
        setup, _, phone = self._pair()
        self.assertEqual(self.client.post("/v1/events", headers=phone, json={"events": [self._event(setup)]}).status_code, 403)

    def test_clear_watermark_blocks_queued_events_but_accepts_new_ones(self) -> None:
        setup, mac, phone = self._pair()
        old = self._event(setup)
        self.client.post("/v1/events", headers=mac, json={"events": [old]})
        self.assertEqual(self.client.delete("/v1/events", headers=phone).json(), {"cleared": True})
        self.assertEqual(self.client.get("/v1/snapshot", headers=phone).json()["events"], [])
        self.client.post("/v1/events", headers=mac, json={"events": [old]})
        self.assertEqual(self.client.get("/v1/snapshot", headers=phone).json()["events"], [])
        fresh = self._event(setup, occurred_at=time.time() + 1)
        self.client.post("/v1/events", headers=mac, json={"events": [fresh]})
        self.assertEqual(len(self.client.get("/v1/snapshot", headers=phone).json()["events"]), 1)

    def test_retried_batch_does_not_repeat_push_but_new_event_does(self) -> None:
        setup, mac, phone = self._pair()
        self.assertEqual(self.client.put("/v1/push-token", headers=phone, json={"token": "a" * 64}).status_code, 200)
        event = self._event(setup, occurred_at=time.time() + 1)
        self.client.post("/v1/events", headers=mac, json={"events": [event]})
        self.assertEqual(len(self.pushes), 1)
        self.client.post("/v1/events", headers=mac, json={"events": [dict(event)]})
        self.assertEqual(len(self.pushes), 1)
        self.assertEqual(len(self.client.get("/v1/snapshot", headers=phone).json()["events"]), 1)
        newer = self._event(setup, occurred_at=time.time() + 2)
        self.client.post("/v1/events", headers=mac, json={"events": [newer]})
        self.assertEqual(len(self.pushes), 2)

    def test_stale_event_never_alerts(self) -> None:
        setup, mac, phone = self._pair()
        self.client.put("/v1/push-token", headers=phone, json={"token": "b" * 64})
        self.client.post("/v1/events", headers=mac, json={"events": [self._event(setup, occurred_at=time.time() - 600)]})
        self.assertEqual(self.pushes, [])

    def test_revoke_device_rejects_old_credential_and_deletes_history(self) -> None:
        setup, mac, phone = self._pair()
        self.client.post("/v1/events", headers=mac, json={"events": [self._event(setup)]})
        self.assertEqual(self.client.delete("/v1/devices/" + setup["device_id"], headers=phone).json(), {"revoked": True})
        self.assertEqual(self.client.post("/v1/heartbeat", headers=mac, json={}).status_code, 401)
        self.assertEqual(self.client.get("/v1/snapshot", headers=phone).json()["events"], [])

    def test_mac_self_revoke_and_phone_unpair(self) -> None:
        _, _, phone = self._pair()
        second = self.client.post(
            "/v1/setup", headers={"x-monitor-bootstrap": BOOTSTRAP}, json={"device_name": "Mac 2"}
        ).json()
        mac2 = {"Authorization": "Bearer " + second["device_token"]}
        self.assertEqual(self.client.post("/v1/heartbeat", headers=mac2, json={}).status_code, 200)
        self.assertEqual(self.client.delete("/v1/device", headers=mac2).json(), {"revoked": True})
        self.assertEqual(self.client.post("/v1/heartbeat", headers=mac2, json={}).status_code, 401)
        self.assertEqual(self.client.delete("/v1/pairing", headers=phone).json(), {"unpaired": True})
        self.assertEqual(self.client.get("/v1/snapshot", headers=phone).status_code, 401)

    def test_clear_landing_during_ingest_does_not_resurrect_history(self) -> None:
        setup, mac, phone = self._pair()
        watermark_key = f"owner:{setup['owner_id']}:events-cleared-before"
        base = self.redis.pipeline
        state = {"raced": False}

        def racing(commands: list[list[object]]) -> list[object]:
            results = base(commands)
            if not state["raced"] and any(str(command[0]).upper() == "ZADD" for command in commands):
                state["raced"] = True
                # A concurrent phone "clear" lands right after the ingest write.
                self.redis.strings[watermark_key] = str(time.time() + 5)
            return results

        self.bridge._redis_pipeline = racing
        self.assertEqual(
            self.client.post("/v1/events", headers=mac, json={"events": [self._event(setup)]}).status_code, 200
        )
        self.assertTrue(state["raced"])
        self.assertEqual(self.client.get("/v1/snapshot", headers=phone).json()["events"], [])

    def test_older_event_arriving_after_a_newer_outcome_does_not_alert(self) -> None:
        setup, mac, phone = self._pair()
        self.client.put("/v1/push-token", headers=phone, json={"token": "c" * 64})
        task = str(uuid.uuid4())
        newer = self._event(setup, task_id=task, occurred_at=time.time())
        self.client.post("/v1/events", headers=mac, json={"events": [newer]})
        self.assertEqual(len(self.pushes), 1)
        older = self._event(
            setup, task_id=task, event_type="waiting", status="waiting", occurred_at=time.time() - 30
        )
        self.client.post("/v1/events", headers=mac, json={"events": [older]})
        self.assertEqual(len(self.pushes), 1, "a stale waiting event must not ring after a newer completion")
        self.assertEqual(len(self.client.get("/v1/snapshot", headers=phone).json()["events"]), 2)

    def test_snapshot_reports_device_names_and_rename_is_scoped(self) -> None:
        setup, mac, phone = self._pair()
        snapshot = self.client.get("/v1/snapshot", headers=phone).json()
        self.assertEqual(snapshot["devices"][0]["device_name"], "Mac")

        renamed = self.client.put(
            "/v1/devices/" + setup["device_id"], headers=phone, json={"device_name": "  Studio MacBook  "}
        )
        self.assertEqual(renamed.status_code, 200, renamed.text)
        self.assertEqual(renamed.json()["device_name"], "Studio MacBook")
        self.assertEqual(self.client.get("/v1/snapshot", headers=phone).json()["devices"][0]["device_name"], "Studio MacBook")

        # The Mac's own credential may not rename devices, and control characters are scrubbed.
        self.assertEqual(
            self.client.put("/v1/devices/" + setup["device_id"], headers=mac, json={"device_name": "x"}).status_code, 403
        )
        scrubbed = self.client.put(
            "/v1/devices/" + setup["device_id"], headers=phone, json={"device_name": "a\nb\tc"}
        )
        self.assertEqual(scrubbed.json()["device_name"], "a b c")
        self.assertEqual(
            self.client.put("/v1/devices/" + str(uuid.uuid4()), headers=phone, json={"device_name": "x"}).status_code, 404
        )

    def test_apns_is_disabled_without_credentials(self) -> None:
        self.assertIsNone(self.bridge._apns_jwt())


class ObserverPluginTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="agent-monitor-plugin-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"device_id": "11111111-1111-4111-8111-111111111111"}))
        os.environ["AGENT_MONITOR_DATA_DIR"] = str(self.root / "data")
        os.environ["AGENT_MONITOR_CONFIG"] = str(self.config)
        from agent_monitor import plugin, queue

        self.plugin, self.queue = plugin, queue
        plugin._CONFIG = {}
        plugin._active_tasks.clear()
        plugin._active_turns_by_session.clear()
        plugin._parent_tasks.clear()
        self.addCleanup(os.environ.pop, "AGENT_MONITOR_DATA_DIR", None)
        self.addCleanup(os.environ.pop, "AGENT_MONITOR_CONFIG", None)

    def _register(self) -> dict[str, Any]:
        hooks: dict[str, Any] = {}
        context = types.SimpleNamespace(register_hook=lambda name, callback: hooks.__setitem__(name, callback))
        self.plugin.register(context)
        return hooks

    def test_turn_lifecycle_and_privacy(self) -> None:
        hooks = self._register()
        message = (
            "Polish login states\n"
            "see https://example.com/secret?token=abc123 and /Users/luyan/.ssh/id_rsa\n"
            "also run `sudo rm -rf /tmp/x` with token 0123456789abcdef0123456789abcdef\n"
        )
        hooks["pre_llm_call"](session_id="session-private", turn_id="turn-1", user_message=message)
        hooks["pre_tool_call"](session_id="session-private", turn_id="turn-1", tool_name="terminal", tool_input={"command": "cat ~/.ssh/id_rsa"})
        hooks["post_tool_call"](session_id="session-private", turn_id="turn-1", tool_name="terminal", duration_ms=1200, tool_result="SECRET OUTPUT")
        hooks["on_human_input_request"](session_id="session-private", turn_id="turn-1", prompt="Approve sudo rm?")
        hooks["on_human_input_resolved"](session_id="session-private", turn_id="turn-1")
        hooks["on_session_end"](session_id="session-private", turn_id="turn-1", completed=True, failed=False, interrupted=False)
        items = self.queue.pending(50)
        chronological = sorted(items, key=lambda item: item["occurred_at"])
        self.assertEqual([item["event_type"] for item in chronological], [
            "started", "tool_started", "tool_finished", "waiting", "resumed", "completed",
        ])
        self.assertGreaterEqual(items[0]["occurred_at"], items[-1]["occurred_at"])
        serialized = json.dumps(items)
        for secret in ("example.com", "id_rsa", "sudo rm", "0123456789abcdef", "SECRET OUTPUT", "Approve sudo", "session-private", "turn-1"):
            self.assertNotIn(secret, serialized)
        # Only the scrubbed first line travels; every other line of the request is dropped.
        self.assertEqual({item["title"] for item in items}, {"Polish login states"})
        self.assertEqual({item["device_id"] for item in items}, {"11111111-1111-4111-8111-111111111111"})
        self.assertEqual(chronological[-1]["summary"], "Turn finished")

    def test_title_scrubbing_edge_cases(self) -> None:
        self.assertIsNone(self.plugin.clean_title(""))
        self.assertIsNone(self.plugin.clean_title("   \n  "))
        self.assertIsNone(self.plugin.clean_title("```\nrm -rf /\n```"))
        self.assertEqual(self.plugin.clean_title("## Fix the login bug\nsecond line"), "Fix the login bug")
        self.assertEqual(self.plugin.clean_title("1. Add list filters"), "Add list filters")
        long_title = self.plugin.clean_title("Reorganise the dense layout on every iOS screen and add status")
        self.assertIsNotNone(long_title)
        self.assertLessEqual(len(long_title), self.plugin.TITLE_MAX)
        self.assertTrue(long_title.endswith("…"))
        self.assertIsNone(self.plugin.clean_title("https://example.com/only-a-link"))

    def test_titles_can_be_switched_off(self) -> None:
        self._register()
        config = json.loads(Path(os.environ["AGENT_MONITOR_CONFIG"]).read_text())
        config["send_titles"] = False
        Path(os.environ["AGENT_MONITOR_CONFIG"]).write_text(json.dumps(config))
        self.plugin._on_pre_llm(session_id="s", turn_id="t", user_message="this title must not be uploaded")
        self.assertIsNone(self.queue.pending(50)[0]["title"])

    def test_brand_defaults_to_hermes_and_follows_the_config(self) -> None:
        self._register()
        self.plugin._on_pre_llm(session_id="s", turn_id="t", user_message="check the build")
        self.assertEqual(self.queue.pending(50)[0]["brand"], "hermes")
        config = json.loads(Path(os.environ["AGENT_MONITOR_CONFIG"]).read_text())
        config["brand"] = "codex"
        Path(os.environ["AGENT_MONITOR_CONFIG"]).write_text(json.dumps(config))
        self.plugin._on_pre_llm(session_id="s", turn_id="t2", user_message="check the build")
        brands = {item["brand"] for item in self.queue.pending(50)}
        self.assertEqual(brands, {"hermes", "codex"})
        config["brand"] = "Not A Slug!"
        Path(os.environ["AGENT_MONITOR_CONFIG"]).write_text(json.dumps(config))
        self.plugin._on_pre_llm(session_id="s", turn_id="t3", user_message="check the build")
        fresh = max(self.queue.pending(50), key=lambda item: item["occurred_at"])
        self.assertEqual(fresh["brand"], "hermes")

    def test_ambiguous_end_is_not_reported_as_success(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="t", user_message="x")
        hooks["on_session_end"](session_id="s", turn_id="t", completed=False, failed=False, interrupted=False)
        final = self.queue.pending(50)[0]
        self.assertEqual(final["event_type"], "incomplete")
        self.assertEqual(final["status"], "interrupted")
        self.assertEqual(final["summary"], "Did not finish")

    def test_failure_and_interruption_are_distinguished(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="a")
        hooks["on_session_end"](session_id="s", turn_id="a", failed=True)
        hooks["pre_llm_call"](session_id="s", turn_id="b")
        hooks["on_session_end"](session_id="s", turn_id="b", interrupted=True)
        by_type = {item["event_type"]: item for item in self.queue.pending(50)}
        self.assertEqual(by_type["failed"]["status"], "failed")
        self.assertEqual(by_type["interrupted"]["status"], "interrupted")

    def test_subagent_records_parent_link(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="parent", turn_id="turn")
        parent_id = self.plugin._current_task("parent", "turn")
        hooks["subagent_start"](parent_session_id="parent", parent_turn_id="turn", child_session_id="child")
        hooks["pre_llm_call"](session_id="child", turn_id="sub-turn")
        child = [item for item in self.queue.pending(50) if item["task_id"] != parent_id]
        self.assertTrue(child)
        self.assertEqual(child[0]["parent_task_id"], parent_id)

    def test_invalid_tool_name_is_reduced_to_placeholder(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="t")
        hooks["pre_tool_call"](session_id="s", turn_id="t", tool_name="../../etc/passwd \n")
        tool_events = [item for item in self.queue.pending(50) if item["event_type"] == "tool_started"]
        self.assertEqual(tool_events[0]["tool_name"], "tool")

    def test_observer_fails_open_when_storage_is_unavailable(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="t")
        os.environ["AGENT_MONITOR_DATA_DIR"] = "/dev/null/not-a-directory"
        self.addCleanup(os.environ.pop, "AGENT_MONITOR_DATA_DIR", None)
        hooks["pre_tool_call"](session_id="s", turn_id="t", tool_name="terminal")
        self.assertIsNone(self.plugin._emit(
            session_id="s", turn_id="t", event_type="tool_finished", status="running"
        ))

    def test_probe_never_sends_another_devices_events(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="t")
        # Simulate an event left behind by a previous registration of this Mac.
        from agent_monitor import queue as shared_queue
        old = os.environ["AGENT_MONITOR_DATA_DIR"]
        shared_queue.enqueue(task_id="t1", parent_task_id=None, device_id="99999999-9999-4999-8999-999999999999",
                             event_type="started", status="running", summary="Turn started")
        own = shared_queue.pending(50, device_id="11111111-1111-4111-8111-111111111111")
        self.assertTrue(own)
        self.assertTrue(all(item["device_id"] == "11111111-1111-4111-8111-111111111111" for item in own))
        self.assertEqual(len(shared_queue.pending(50)), len(own) + 1)
        self.assertEqual(shared_queue.drop_other_devices("11111111-1111-4111-8111-111111111111"), 1)
        self.assertEqual(os.environ["AGENT_MONITOR_DATA_DIR"], old)

    def test_plugin_picks_up_a_new_registration(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="a")
        first = {item["device_id"] for item in self.queue.pending(50)}
        self.assertEqual(first, {"11111111-1111-4111-8111-111111111111"})
        time.sleep(0.01)
        self.config.write_text(json.dumps({"device_id": "33333333-3333-4333-8333-333333333333"}))
        os.utime(self.config, None)
        hooks["pre_llm_call"](session_id="s", turn_id="b")
        devices = {item["device_id"] for item in self.queue.pending(50)}
        self.assertIn("33333333-3333-4333-8333-333333333333", devices)

    def test_clear_history_removes_everything(self) -> None:
        hooks = self._register()
        hooks["pre_llm_call"](session_id="s", turn_id="t")
        self.assertGreater(self.queue.clear_history(), 0)
        self.assertEqual(self.queue.pending(50), [])


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        from agent_monitor import cli

        self.cli = cli

    def test_bridge_url_must_be_https_except_localhost(self) -> None:
        self.assertEqual(self.cli._base_url("https://example.vercel.app/"), "https://example.vercel.app")
        self.assertEqual(self.cli._base_url("http://localhost:8000"), "http://localhost:8000")
        for rejected in (
            "http://127.0.0.1.attacker.test",
            "http://example.com",
            "https://example.com/path",
            "https://user@example.com",
            "https://example.com?x=1",
        ):
            with self.assertRaises(SystemExit):
                self.cli._base_url(rejected)

    def test_install_plugin_copies_manifest_and_refuses_foreign_directory(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="agent-monitor-install-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        os.environ["HERMES_HOME"] = str(root / "hermes")
        self.addCleanup(os.environ.pop, "HERMES_HOME", None)
        destination = root / "hermes" / "plugins" / "agent_monitor"
        self.cli.cmd_install_plugin(types.SimpleNamespace())
        self.assertEqual(
            sorted(path.name for path in destination.iterdir()),
            [".managed.json", "__init__.py", "plugin.yaml", "queue.py"],
        )
        shutil.rmtree(destination)
        destination.mkdir(parents=True)
        (destination / "someone_else.py").write_text("")
        with self.assertRaises(SystemExit):
            self.cli.cmd_install_plugin(types.SimpleNamespace())
        self.assertTrue((destination / "someone_else.py").exists())

    def test_keychain_set_verifies_what_really_landed(self) -> None:
        # `security` asks for the password twice on a pipe; a single line stores an empty value
        # while still exiting 0, so the helper must read the secret back before trusting it.
        store: dict[str, str] = {}
        real_run = self.cli.subprocess.run

        def fake_run(command, **kwargs):
            words = list(command)
            if "add-generic-password" in words:
                fed = (kwargs.get("input") or "").split("\n")
                account = words[words.index("-a") + 1]
                # Mimic the real binary: it only accepts two matching lines.
                store[account] = fed[0] if len(fed) > 1 and fed[0] == fed[1] else ""
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")
            if "find-generic-password" in words:
                account = words[words.index("-a") + 1]
                return types.SimpleNamespace(returncode=0 if account in store else 44,
                                             stdout=store.get(account, "") + "\n", stderr="")
            if "delete-generic-password" in words:
                store.pop(words[words.index("-a") + 1], None)
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        self.addCleanup(setattr, self.cli.subprocess, "run", real_run)
        self.cli.subprocess.run = fake_run

        self.cli._keychain_set("device-1", "secret-token")
        self.assertEqual(store["device-1"], "secret-token")

        def broken_run(command, **kwargs):
            result = fake_run(command, **kwargs)
            if "add-generic-password" in list(command):
                store["device-2"] = ""          # the real-world silent-empty failure
            return result

        self.cli.subprocess.run = broken_run
        with self.assertRaises(RuntimeError):
            self.cli._keychain_set("device-2", "secret-token")
        self.assertNotIn("device-2", store)

    def test_uninstall_clears_plugin_data_launchagent_and_cloud_credential(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="agent-monitor-uninstall-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        home = root / "home"
        app_data = home / "Library" / "Application Support" / "Agent Monitor"
        app_data.mkdir(parents=True)
        device_id = "22222222-2222-4222-8222-222222222222"
        (app_data / "config.json").write_text(json.dumps({"device_id": device_id, "base_url": "https://example.vercel.app"}))
        (app_data / "queue.sqlite3").write_text("")
        plugin_dir = root / "hermes" / "plugins" / "agent_monitor"
        launch = home / "Library" / "LaunchAgents" / "org.nousresearch.agent-monitor.plist"
        launch.parent.mkdir(parents=True)
        launch.write_text("placeholder")

        os.environ["HOME"] = str(home)
        os.environ["HERMES_HOME"] = str(root / "hermes")
        self.addCleanup(os.environ.pop, "HERMES_HOME", None)
        self.addCleanup(os.environ.pop, "HOME", None)

        os.environ["HERMES_HOME"] = str(root / "hermes")
        self.cli.cmd_install_plugin(types.SimpleNamespace())
        (plugin_dir / "unrelated-notes.txt").write_text("keep me")

        calls: list[tuple[str, str]] = []
        self.cli._request = lambda base, path, **kwargs: calls.append((base, path)) or {}
        self.cli._keychain_get = lambda account: "device-token"
        real_run = self.cli.subprocess.run
        real_which = self.cli.shutil.which
        # `cli` holds the modules themselves, so these patches are global: restore them.
        self.addCleanup(setattr, self.cli.subprocess, "run", real_run)
        self.addCleanup(setattr, self.cli.shutil, "which", real_which)
        self.cli.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(returncode=0, stdout="", stderr="")
        self.cli.shutil.which = lambda name: None
        self.addCleanup(setattr, self.cli, "_request", self.cli._request)
        self.cli.cmd_uninstall(types.SimpleNamespace(yes=True))

        self.assertEqual(calls, [("https://example.vercel.app", "/v1/device")])
        self.assertFalse(app_data.exists())
        self.assertTrue(plugin_dir.is_dir())
        self.assertEqual([path.name for path in plugin_dir.iterdir()], ["unrelated-notes.txt"])
        self.assertFalse((plugin_dir / "plugin.yaml").exists())
        self.assertFalse(launch.exists())


class InstallerScriptTests(unittest.TestCase):
    """The one-command installer is published with a release, so it must match that release."""

    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[1]
        self.script = self.root / "install.sh"

    def test_pinned_version_matches_the_package_version(self) -> None:
        pinned = re.search(r'^VERSION="([^"]+)"', self.script.read_text(encoding="utf-8"), re.MULTILINE)
        packaged = re.search(r'^version = "([^"]+)"', (self.root / "pyproject.toml").read_text(encoding="utf-8"), re.MULTILINE)
        self.assertIsNotNone(pinned, "install.sh must pin VERSION")
        self.assertIsNotNone(packaged, "pyproject.toml must declare a version")
        assert pinned and packaged
        self.assertEqual(
            pinned.group(1), packaged.group(1),
            "bump VERSION in install.sh whenever the package version changes",
        )

    def test_script_is_posix_sh_and_refuses_unknown_flags(self) -> None:
        syntax = subprocess.run(["/bin/sh", "-n", str(self.script)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        helped = subprocess.run(["/bin/sh", str(self.script), "--help"], capture_output=True, text=True)
        self.assertEqual(helped.returncode, 0, helped.stderr)
        self.assertIn("--url", helped.stdout)
        self.assertIn("--wheel", helped.stdout)
        refused = subprocess.run(["/bin/sh", str(self.script), "--not-a-flag"], capture_output=True, text=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("unknown option", refused.stderr)


if __name__ == "__main__":
    unittest.main()