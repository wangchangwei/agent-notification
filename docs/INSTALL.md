# Agent Monitor macOS probe v0.1.0

Requirements: macOS, Python 3.11 or newer, Hermes Agent, and your own Agent Monitor HTTPS bridge. This release ships the Python probe, not a standalone macOS application.

## Install

Cloning the repository is optional. In a terminal:

```sh
python3 --version
python3 -m venv "$HOME/Library/Application Support/Agent Monitor/.venv"
"$HOME/Library/Application Support/Agent Monitor/.venv/bin/python" -m pip install 'agent-notification[qrcode] @ https://github.com/wangchangwei/agent-notification/releases/download/v0.1.0/agent_notification-0.1.0-py3-none-any.whl'
```

If you already downloaded the wheel, install the local file with that environment's pip instead:

```sh
"$HOME/Library/Application Support/Agent Monitor/.venv/bin/python" -m pip install './agent_notification-0.1.0-py3-none-any.whl[qrcode]'
```

## Configure and start

Replace the example bridge URL. `setup` prompts for the bootstrap token without echoing it, and stores the device credential in the macOS Keychain.

```sh
. "$HOME/Library/Application Support/Agent Monitor/.venv/bin/activate"
agent-monitor setup --url https://your-project.vercel.app
agent-monitor install-plugin
hermes plugins enable agent_monitor
agent-monitor pair
agent-monitor run
```

Scan the short-lived pairing QR in the iPhone app. After enabling the plugin, restart the Hermes desktop app — or run `hermes gateway restart` — so turn-start and turn-end events are wired up. `run` syncs in the foreground; stop it with Ctrl-C.

For a second Mac under the same owner, pass the owner ID printed by the first setup:

```sh
agent-monitor setup --url https://your-project.vercel.app --owner-id YOUR_OWNER_ID
```

## Optional commands

```sh
agent-monitor status
agent-monitor brand hermes
agent-monitor install-service
```

`install-service` only writes the optional login service; to start it, run the `launchctl bootstrap` command it prints.

The probe collects state through the read-only Hermes plugin. Setting a brand name does not add event adapters for Codex, Pi or other agents. Titles are limited to a scrubbed first line of at most 24 characters and can be disabled with `send_titles: false` in the local configuration.

## Uninstall

```sh
agent-monitor uninstall
```

After confirmation this removes the probe package, the plugin, the default local data, the Keychain item and the login service, and revokes the cloud device when the bridge is reachable. A custom data directory is reported separately for you to remove.

## Verify the download

Download `SHA256SUMS` from this release and, in the same directory, run:

```sh
shasum -a 256 -c SHA256SUMS
```

The wheel, the source archive and this file must all be present for the check to pass. Full project documentation: https://github.com/wangchangwei/agent-notification