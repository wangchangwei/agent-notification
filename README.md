# Agent Monitor

A private, read-only iPhone companion for Hermes Agent on macOS.

## Components

- `agent_monitor/`: macOS command line probe, durable SQLite queue and a read-only Hermes observer plugin.
- `agent_monitor/bridge.py`: FastAPI API for Vercel Functions and an Upstash Redis REST adapter.
- `ios/AgentMonitor.xcodeproj`: native SwiftUI iOS app, QR pairing scanner and APNs integration, plus the `AgentMonitorWatch` watchOS app embedded in it.
- `PLAN.md`: agreed product scope and acceptance criteria.

## Local development

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e '.[dev,qrcode]'
uvicorn app:app --reload
```

`GET /healthz` works without credentials. Other API routes require `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, and a strong `MONITOR_BOOTSTRAP_TOKEN`.

## Verify locally

```sh
python3 -m unittest discover -s tests -v
```

The suite runs the API against an in-memory stand-in for the Upstash REST pipeline, plus the observer plugin, queue retention/clear, CLI URL validation, plugin install and the full uninstall path. It needs no cloud account, Apple credential or network access. iOS builds are checked with `xcodebuild -project ios/AgentMonitor.xcodeproj -scheme AgentMonitor -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build`.

Check the iOS status model independently with `swiftc ios/AgentMonitor/MonitorModels.swift ios/Tests/MonitorStateChecks.swift -o "$TMPDIR/monitor-state-checks" && "$TMPDIR/monitor-state-checks"`. This covers out-of-order events, task IDs shared by multiple Macs, incomplete turns, missing duration fields, heartbeat expiration, and server clock calibration when the phone clock is ahead or behind.

## Deploy the bridge

1. Create a Vercel Hobby project for personal use and connect this repository.
2. Create an Upstash Redis database and add its REST URL and REST token as Vercel environment variables.
3. Generate a strong random `MONITOR_BOOTSTRAP_TOKEN`; add it to Vercel and keep it in your password manager. The Mac setup command prompts for it without echoing the value.
4. Deploy the project and keep the public HTTPS URL.
5. For APNs, add `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC` (the signed iOS app bundle ID), and `APNS_PRIVATE_KEY_B64` (base64-encoded Apple `.p8` key). Development builds use the sandbox by default; set `APNS_USE_SANDBOX=false` for production-signed builds. If APNs variables are omitted, event sync still works but push notifications are disabled.

The bridge is stateless. Redis stores device authorization, short-lived pairing codes, the last heartbeat and sanitized event history. Ingestion is idempotent: a replayed batch is stored once, only the newest state of a task can raise a push, and each event ID claims at most one push so a lost response cannot re-alert. A clear that lands while a Mac is uploading is re-checked after the write, so pre-clear events cannot reappear. Vercel's Hobby plan is limited to personal, non-commercial use. Vercel or Upstash may throttle, reject or pause service at free-tier limits; this is not an unlimited free availability promise. Function, database-command, storage and transfer use must be measured against the selected accounts before relying on it. Configure provider dashboard usage alerts where available: this first version has no in-app quota meter and never upgrades a plan automatically. The app polls every five seconds only while foregrounded; polling can become the largest Redis command cost.

## Set up each Mac

```sh
python3 -m venv "$HOME/Library/Application Support/Agent Monitor/.venv"
"$HOME/Library/Application Support/Agent Monitor/.venv/bin/pip" install -e '/absolute/path/to/agent-notification[qrcode]'
"$HOME/Library/Application Support/Agent Monitor/.venv/bin/agent-monitor" setup --url https://your-project.vercel.app
```

Replace the example path with this repository's absolute path. For a second Mac, pass `--owner-id` with the owner ID printed by the first Mac's setup. Install and enable the observer plugin for the active Hermes profile, then start the probe:

```sh
agent-monitor install-plugin
hermes plugins enable agent_monitor
agent-monitor pair
agent-monitor run
```

Restart the Hermes desktop app (or `hermes gateway restart`) once after enabling: tool events flow immediately, but the turn-level events behind 执行开始/本轮执行结束 are only rewired on a gateway restart. Commands run through the `hermes` CLI pick the plugin up without a restart.

The terminal QR is short-lived and single-use. The bootstrap token is only needed by `setup`. Device tokens are stored in macOS Keychain; the plugin and probe use the local application-support queue. To start at login, run `agent-monitor install-service`, then use the exact `launchctl bootstrap` command it prints. This is opt-in.

The observer discards prompt bodies, API payloads, tool arguments/results, file paths and conversation text. It transmits opaque per-turn/task UUIDs, status transitions, elapsed tool time, a validated tool name, and one short title: the first line of the request with code, links, e-mail addresses, paths and long tokens removed, capped at 24 characters. Set `send_titles` to `false` in the probe's `config.json` to stop sending titles at all. The probe caches up to 4,000 recent events locally, keeps seven days, and retains undelivered events across network failures.

Use **清空云端历史** in the iPhone app to clear the server's 7-day event list. A clear watermark prevents older queued events from reappearing after a Mac reconnects. To also erase each Mac's local event queue, run `agent-monitor clear-local-history` on that Mac. To remove the local probe, package, app data, Keychain item, LaunchAgent and the active-profile plugin, run `agent-monitor uninstall` and confirm. It revokes the Mac's cloud credential when reachable; if offline, revoke the device from the iPhone app when it reconnects. The source checkout is left in place for you to remove separately.

## Build the iOS app

Open `ios/AgentMonitor.xcodeproj` in Xcode, choose an iOS Simulator destination, and build `AgentMonitor`. A task that moves from running or waiting to 本轮执行结束 plays one system sound and haptic while the app is open; it is silent in the background and can be switched off under 设置 → 提示音. Debug and simulator builds use the development APNs entitlement; Release uses the production entitlement. For a real iPhone, set your Apple development team and bundle identifier, enable Push Notifications for the matching App ID, and use the corresponding APNs topic/key and bridge `APNS_USE_SANDBOX` value. The app keeps its access token in Keychain; the pairing code is entered by the in-app camera scanner or text field.

## Build the watch app

`AgentMonitorWatch` is a single-target watchOS app embedded in the phone app's `Watch` folder; `ios/generate_project.py` emits both targets, so regenerate and rebuild after changing build settings.

```sh
xcodebuild -project ios/AgentMonitor.xcodeproj -target AgentMonitorWatch -sdk watchsimulator \
  -configuration Debug CONFIGURATION_BUILD_DIR="$PWD/.build/watch" CODE_SIGNING_ALLOWED=NO build
xcrun simctl install <watch-udid> .build/watch/AgentMonitorWatch.app
```

The watch mirrors the phone: what is running, what is waiting, and how each task ended, read-only. It holds its own copy of the bridge URL and device token, handed over once over WatchConnectivity whenever the phone app comes forward (`PhoneWatchLink` → `WatchLink`); it never reads the phone's Keychain, and unpairing clears the watch copy. While visible it polls every 10 seconds; there is no watch complication or watch notification yet, so background alerts still come from the phone's APNs.

## Boundaries

This repository does not create Vercel/Upstash resources, deploy to those accounts, install or enable the Hermes plugin, or register a LaunchAgent automatically. APNs requires your Apple developer team and private key. The app does not remotely control agent tasks. Vercel and Upstash limits and policies can change; verify current account-specific terms and usage before deployment.

## License

Released under the [MIT License](LICENSE).
