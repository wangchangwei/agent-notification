# Agent Monitor macOS probe v0.1.2

Requirements: macOS, Python 3.11 or newer, Hermes Agent, and your own Agent Monitor HTTPS bridge. This release ships the Python probe, not a standalone macOS application.

## Install with one command

On the iPhone, open **Agent Monitor → Computers → Add a computer**. The app issues a six-digit code, single use and valid for ten minutes, and shows the exact command. Paste that command into Terminal on the Mac you want to add:

```sh
curl -fsSL https://github.com/wangchangwei/agent-notification/releases/latest/download/install.sh \
  | sh -s -- --url https://your-project.vercel.app --code 123456
```

Nothing is typed by hand and no bootstrap token travels between machines: the code already belongs to your account, so the new Mac joins the same owner as the phone.

The script checks for Python 3.11 or newer, creates the virtual environment at `$HOME/Library/Application Support/Agent Monitor/.venv`, installs `agent-notification` into it, verifies the wheel against `SHA256SUMS`, links `agent-monitor` into `~/.local/bin`, and registers this Mac. The device credential is stored in the macOS Keychain.

Flags:

| Flag | Effect |
| --- | --- |
| `--url URL` | Bridge URL; with `--code` the Mac registers during the install |
| `--code CODE` | Six-digit code from the phone; replaces the bootstrap token |
| `--owner-id ID` | Owner ID printed by the first setup, for a Mac that has no phone code |
| `--brand NAME` | Agent brand shown on the phone: `hermes` (default), `codex`, `pi` |
| `--plugin` | Also install and enable the read-only Hermes observer plugin |
| `--service` | Also write the opt-in login service (not loaded) |
| `--version V` | Install a different release |
| `--wheel PATH` | Install a downloaded wheel instead of fetching one |
| `--venv PATH` | Use a different virtual environment |
| `--force` | Reinstall even when the same version is present |

Re-running the command upgrades in place. It never overwrites an existing registration: remove `$HOME/Library/Application Support/Agent Monitor/config.json`, or run `agent-monitor setup` again, to register the Mac anew.

## The first Mac, before any phone is paired

There is no phone to issue a code yet, so the first Mac uses the bridge's bootstrap token. `setup` prompts for it without echoing it:

```sh
curl -fsSL https://github.com/wangchangwei/agent-notification/releases/latest/download/install.sh \
  | sh -s -- --url https://your-project.vercel.app
```

Pair the phone once from that Mac, and use **Add a computer** for every later Mac.

## Finish the setup

```sh
agent-monitor install-plugin
hermes plugins enable agent_monitor
agent-monitor pair
agent-monitor run
```

Skip the first two lines if you installed with `--plugin`. If `~/.local/bin` is not on your `PATH`, call `"$HOME/Library/Application Support/Agent Monitor/.venv/bin/agent-monitor"` instead.

Scan the short-lived pairing QR in the iPhone app. After enabling the plugin, restart the Hermes desktop app — or run `hermes gateway restart` — so turn-start and turn-end events are wired up. `run` syncs in the foreground; stop it with Ctrl-C.

## Install from the wheel instead

Cloning the repository is optional. If you prefer to control each step, or the machine has no network access to the release script:

```sh
python3 --version
python3 -m venv "$HOME/Library/Application Support/Agent Monitor/.venv"
"$HOME/Library/Application Support/Agent Monitor/.venv/bin/python" -m pip install 'agent_notification-0.1.2-py3-none-any.whl'
. "$HOME/Library/Application Support/Agent Monitor/.venv/bin/activate"
agent-monitor setup --url https://your-project.vercel.app --code 123456
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

Download `SHA256SUMS` from this release and, in the same directory as the other assets, run:

```sh
shasum -a 256 -c SHA256SUMS
```

The wheel, the source archive, `INSTALL.md` and `install.sh` must all be present for the check to pass; the installer performs the wheel check itself. Full project documentation: https://github.com/wangchangwei/agent-notification