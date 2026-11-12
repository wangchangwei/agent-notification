from __future__ import annotations

import getpass
import http.client
import http.server
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from . import queue
from .paths import config_path, data_dir

KEYCHAIN_SERVICE = "org.nousresearch.agent-monitor.device"
MANAGED_MARKER = ".managed.json"


def _read_config() -> dict[str, Any]:
    try:
        return json.loads(config_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit("Agent Monitor is not configured. Run: agent-monitor setup")


def _write_config(config: dict[str, Any]) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(config, indent=2), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    os.chmod(path, 0o600)


def _keychain_set(account: str, token: str) -> None:
    # `security` echoes this prompt twice when stdin is not a terminal (password + retype);
    # feeding it a single line stores an empty secret while still exiting 0, so read it back.
    # It also prefers /dev/tty over the piped secret whenever a controlling terminal exists,
    # which hangs setup when it is run from Terminal.app — `start_new_session` removes
    # that terminal so the piped value is what gets stored.
    result = subprocess.run(
        ["/usr/bin/security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
        input=f"{token}\n{token}\n",
        capture_output=True,
        text=True,
        check=False,
        start_new_session=True,
    )
    stored = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode or stored.returncode or stored.stdout.strip() != token:
        subprocess.run(
            ["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account],
            capture_output=True,
            text=True,
            check=False,
        )
        raise RuntimeError("Could not save the device credential in macOS Keychain")


def _keychain_get(account: str) -> str:
    result = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode or not result.stdout.strip():
        raise SystemExit("Device credential is missing from macOS Keychain; run agent-monitor setup again")
    return result.stdout.strip()


def _keychain_delete(account: str) -> None:
    subprocess.run(
        ["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account],
        capture_output=True,
        text=True,
        check=False,
    )


def _request(base_url: str, path: str, *, method: str = "GET", body: dict[str, Any] | None = None,
             token: str | None = None, bootstrap: str | None = None, timeout: int = 8) -> Any:
    headers = {"Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if bootstrap:
        headers["X-Monitor-Bootstrap"] = bootstrap
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(base_url.rstrip("/") + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = response.read(1_000_000)
        return json.loads(result.decode("utf-8")) if result else {}
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise RuntimeError("The service rejected the credential") from None
        if exc.code in (413, 422):
            raise RuntimeError("The service rejected this request") from None
        raise RuntimeError(f"Bridge request failed (HTTP {exc.code})") from None
    except (urllib.error.URLError, TimeoutError, http.client.HTTPException) as exc:
        raise RuntimeError("Bridge is unreachable; queued events remain on this Mac") from exc


def _base_url(value: str) -> str:
    value = value.strip().rstrip("/")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        _ = parsed.port
    except ValueError:
        hostname = None
        parsed = None
    local_http = parsed is not None and parsed.scheme == "http" and hostname in {"localhost", "127.0.0.1", "::1"}
    remote_https = parsed is not None and parsed.scheme == "https" and bool(hostname)
    if (not (local_http or remote_https) or parsed is None or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.path not in {"", "/"}):
        raise SystemExit("Use a base HTTPS bridge URL. Plain HTTP is allowed only for localhost development.")
    return value


BRANDS = {"hermes": "Hermes", "codex": "Codex", "pi": "Pi", "claude": "Claude Code", "gemini": "Gemini"}


def _brand(value: Any) -> str:
    brand = str(value or "hermes").strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,15}", brand):
        raise SystemExit("Use a short lowercase brand such as hermes, codex or pi.")
    return brand


def cmd_setup(args: Any) -> None:
    base_url = _base_url(args.url or input("Vercel bridge URL: "))
    bootstrap = getpass.getpass("Bootstrap token: ")
    owner_id = args.owner_id or None
    brand = _brand(getattr(args, "brand", None))
    result = _request(base_url, "/v1/setup", method="POST", body={"owner_id": owner_id, "device_name": "Mac"}, bootstrap=bootstrap)
    config = {"base_url": base_url, "owner_id": result["owner_id"], "device_id": result["device_id"], "heartbeat_seconds": 30, "brand": brand}
    try:
        _keychain_set(config["device_id"], result["device_token"])
        _write_config(config)
    except Exception:
        print("The bridge registered this Mac, but local credential storage failed; revoke the device from the phone app.", file=sys.stderr)
        raise
    dropped = queue.drop_other_devices(config["device_id"])
    if dropped:
        print(f"Discarded {dropped} queued event(s) from a previous device registration.")
    print(f"Configured device {config['device_id']} for owner {config['owner_id']}.")
    print(f"Brand shown on the phone: {BRANDS.get(brand, brand.title())}. Change it later with `agent-monitor brand <name>`.")
    print("Run `agent-monitor pair` to show a one-time pairing QR for the iPhone.")


def cmd_brand(args: Any) -> None:
    config = _read_config()
    config["brand"] = _brand(args.name)
    _write_config(config)
    print(f"Brand set to {BRANDS.get(config['brand'], config['brand'].title())}.")


def cmd_pair(_: Any) -> None:
    config = _read_config()
    token = _keychain_get(config["device_id"])
    result = _request(config["base_url"], "/v1/pair-codes", method="POST", body={}, token=token)
    print("Scan this code in Agent Monitor on the iPhone (valid for 5 minutes):")
    try:
        import qrcode
        qr = qrcode.QRCode(border=1)
        qr.add_data(result["deep_link"])
        qr.print_ascii(invert=True)
    except ImportError:
        print(result["deep_link"])
        print("Install the optional QR package (`pip install 'agent-notification[qrcode]'`) for a terminal QR.")
    print(f"Pairing code: {result['code']}")


def _hermes_home() -> Path:
    override = os.getenv("HERMES_HOME")
    if override:
        return Path(override).expanduser()
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home())
    except Exception:
        return Path.home() / ".hermes"


def cmd_install_plugin(_: Any) -> None:
    source = Path(__file__).parent / "plugin"
    destination = _hermes_home() / "plugins" / "agent_monitor"
    if destination.exists() and not (destination / "plugin.yaml").exists():
        raise SystemExit(f"Refusing to overwrite non-Agent-Monitor directory: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    marker = destination / MANAGED_MARKER
    marker.write_text(json.dumps({"manager": "agent-monitor", "files": sorted(
        child.name for child in source.iterdir() if child.is_file()
    )}), encoding="utf-8")
    print(f"Installed the observer plugin at {destination}")
    print("Enable it for this Hermes profile with: hermes plugins enable agent_monitor")


def _drain_once(config: dict[str, Any], token: str) -> None:
    events = queue.pending(50, device_id=str(config.get("device_id") or ""))
    if events:
        result = _request(config["base_url"], "/v1/events", method="POST", body={"events": events}, token=token)
        if result.get("accepted") != len(events):
            raise RuntimeError("Bridge did not acknowledge the full event batch")
        queue.mark_delivered([str(item["event_id"]) for item in events])


def cmd_run(_: Any) -> None:
    config = _read_config()
    token = _keychain_get(config["device_id"])
    print("Agent Monitor probe running. Press Ctrl-C to stop.", flush=True)
    next_sync = 0.0
    next_heartbeat = 0.0
    sync_backoff = 2.0
    heartbeat_backoff = 2.0
    while True:
        now = time.monotonic()
        if now >= next_sync:
            try:
                _drain_once(config, token)
                sync_backoff = 2.0
                next_sync = time.monotonic() + 2.0
            except Exception as exc:
                print(f"Sync paused: {exc}", file=sys.stderr, flush=True)
                next_sync = time.monotonic() + sync_backoff
                sync_backoff = min(sync_backoff * 2.0, 120.0)
        now = time.monotonic()
        if now >= next_heartbeat:
            try:
                _request(config["base_url"], "/v1/heartbeat", method="POST", body={}, token=token)
                heartbeat_backoff = 2.0
                next_heartbeat = time.monotonic() + 30.0
            except Exception as exc:
                print(f"Heartbeat paused: {exc}", file=sys.stderr, flush=True)
                next_heartbeat = time.monotonic() + heartbeat_backoff
                heartbeat_backoff = min(heartbeat_backoff * 2.0, 120.0)
        time.sleep(1.0)


def cmd_status(_: Any) -> None:
    config = _read_config()
    print(f"Bridge: {config['base_url']}")
    print(f"Device: {config['device_id']}")
    print(f"Pending local events: {queue.queued_count()}")
    print(f"Local queue: {queue.database_path()}")


def cmd_clear_local_history(_: Any) -> None:
    count = queue.clear_history()
    print(f"Cleared {count} local queue event(s).")


def cmd_install_service(_: Any) -> None:
    config = _read_config()
    data_dir().mkdir(parents=True, exist_ok=True)
    log_path = data_dir() / "probe.log"
    label = "org.nousresearch.agent-monitor"
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "Label": label,
        "ProgramArguments": [sys.executable, "-m", "agent_monitor", "run"],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "StandardOutPath": str(log_path),
        "StandardErrorPath": str(log_path),
        "WorkingDirectory": str(Path(__file__).resolve().parents[1]),
        "EnvironmentVariables": {"AGENT_MONITOR_CONFIG": str(config_path())},
    }
    plist_path.write_bytes(plistlib.dumps(payload))
    os.chmod(plist_path, 0o600)
    print(f"Installed opt-in login service at {plist_path}.")
    print("It is not loaded automatically. Load it with: launchctl bootstrap gui/$(id -u) " + str(plist_path))


def cmd_uninstall_service(_: Any) -> None:
    label = "org.nousresearch.agent-monitor"
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
    subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"], capture_output=True, check=False)
    if plist_path.exists():
        plist_path.unlink()
    print("Removed Agent Monitor LaunchAgent. The queued local history and Keychain credential remain.")


def cmd_uninstall(args: Any) -> None:
    if not args.yes and input("Remove Agent Monitor, local history, Keychain credential, and its active-profile plugin? [y/N] ").strip().lower() not in {"y", "yes"}:
        print("Cancelled.")
        return

    try:
        config = _read_config()
    except SystemExit:
        config = {}
    device_id = str(config.get("device_id") or "")
    token = None
    if device_id:
        try:
            token = _keychain_get(device_id)
        except SystemExit:
            pass
    remote_revoked = False
    if token and config.get("base_url"):
        try:
            _request(config["base_url"], "/v1/device", method="DELETE", token=token)
            remote_revoked = True
        except Exception:
            pass

    label = "org.nousresearch.agent-monitor"
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
    subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"], capture_output=True, check=False)
    if plist_path.exists():
        plist_path.unlink()

    hermes_home = _hermes_home()
    plugin_path = hermes_home / "plugins" / "agent_monitor"
    if plugin_path.is_dir() and not plugin_path.is_symlink():
        marker = plugin_path / MANAGED_MARKER
        owned = False
        try:
            owned = json.loads(marker.read_text(encoding="utf-8")).get("manager") == "agent-monitor"
        except (OSError, ValueError):
            owned = False
        shipped = Path(__file__).parent / "plugin"
        shipped_manifest = shipped / "plugin.yaml"
        installed_manifest = plugin_path / "plugin.yaml"
        # Older installs predate the marker; accept them only when their manifest is byte-identical.
        legacy = (
            installed_manifest.is_file() and shipped_manifest.is_file()
            and installed_manifest.read_bytes() == shipped_manifest.read_bytes()
        )
        if owned or legacy:
            hermes = shutil.which("hermes")
            if hermes:
                subprocess.run([hermes, "plugins", "disable", "agent_monitor"], capture_output=True, check=False)
            # Remove only what this package installed, so unrelated files in a shared directory survive.
            removable = {MANAGED_MARKER, "__pycache__"}
            if shipped.is_dir():
                removable |= {child.name for child in shipped.iterdir() if child.is_file()}
            for child in plugin_path.iterdir():
                if child.name not in removable:
                    continue
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
            if any(plugin_path.iterdir()):
                print(f"Left unrecognized files in {plugin_path}; review them manually.")
            else:
                plugin_path.rmdir()

    keychain_removed = False
    if device_id:
        result = subprocess.run(
            ["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", device_id],
            capture_output=True, text=True, check=False,
        )
        keychain_removed = result.returncode == 0

    package_result = subprocess.run(
        [sys.executable, "-m", "pip", "uninstall", "-y", "agent-notification"],
        capture_output=True, text=True, check=False,
    )
    app_data = Path.home() / "Library" / "Application Support" / "Agent Monitor"
    custom_data = data_dir()
    if custom_data == app_data:
        if app_data.is_symlink():
            app_data.unlink()
        elif app_data.exists():
            shutil.rmtree(app_data)
    elif custom_data.exists():
        print(f"Custom data directory left in place: {custom_data}")
    custom_config = config_path()
    if custom_config.parent != app_data and custom_config.exists():
        print(f"Custom config file left in place: {custom_config}")

    print("Removed Agent Monitor's active Hermes plugin and local app data.")
    if package_result.returncode == 0:
        print("Removed the agent-notification Python package.")
    else:
        print("Python package removal did not complete; run `python -m pip uninstall agent-notification` in its install environment.")
    if not keychain_removed and device_id:
        print("The Keychain entry could not be confirmed removed; delete the Agent Monitor device credential in Keychain Access.")
    if remote_revoked:
        print("The Mac's cloud credential and its cloud history were revoked.")
    elif device_id:
        print("Cloud revocation was not confirmed. Revoke this Mac in the iPhone app when it is online.")
    print("The source checkout is left in place; remove that directory separately if no longer needed.")


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(prog="agent-monitor", description="Private Hermes task monitor")
    subparsers = parser.add_subparsers(dest="command", required=True)
    setup = subparsers.add_parser("setup", help="Register this Mac with the bridge")
    setup.add_argument("--url")
    setup.add_argument("--owner-id", help="Use the owner ID printed by setup on another Mac")
    setup.add_argument("--brand", help="Agent brand shown on the phone: hermes, codex, pi, or any short slug")
    setup.set_defaults(func=cmd_setup)
    for name, help_text, function in (
        ("pair", "Create a short-lived iPhone pairing QR", cmd_pair),
        ("install-plugin", "Install the read-only Hermes plugin into the active profile", cmd_install_plugin),
        ("run", "Run the local durable-queue sync probe", cmd_run),
        ("status", "Show local probe and queue status", cmd_status),
        ("clear-local-history", "Permanently clear this Mac's local event history and queued events", cmd_clear_local_history),
        ("install-service", "Install, but do not launch, the optional login service", cmd_install_service),
        ("uninstall-service", "Stop and remove the login service", cmd_uninstall_service),
    ):
        subparsers.add_parser(name, help=help_text).set_defaults(func=function)
    brand_parser = subparsers.add_parser("brand", help="Set the agent brand shown on the phone")
    brand_parser.add_argument("name", help="hermes, codex, pi, or any short lowercase slug")
    brand_parser.set_defaults(func=cmd_brand)
    uninstall = subparsers.add_parser("uninstall", help="Remove the probe, plugin, Keychain item, and local history")
    uninstall.add_argument("--yes", "-y", action="store_true", help="Skip the confirmation prompt")
    uninstall.set_defaults(func=cmd_uninstall)
    args = parser.parse_args()
    args.func(args)
