#!/bin/sh
# Agent Monitor probe installer for macOS.
#
#   curl -fsSL https://github.com/wangchangwei/agent-notification/releases/latest/download/install.sh \
#     | sh -s -- --url https://your-project.vercel.app
#
# Installs the released probe into its own virtual environment, links
# `agent-monitor` into ~/.local/bin, verifies the wheel against SHA256SUMS and,
# when --url is given, registers this Mac with your bridge. Re-running upgrades
# in place and keeps the existing registration.

set -eu

# Sandboxes and CI sometimes run without HOME; the probe still needs one for
# Application Support and ~/.local/bin.
if [ -z "${HOME:-}" ]; then
  HOME="$(eval echo "~$(id -un)" 2>/dev/null || true)"
  case "$HOME" in ''|'~'*) HOME="/Users/$(id -un)" ;; esac
  export HOME
fi

REPO="wangchangwei/agent-notification"
VERSION="0.1.1"
APP_SUPPORT="$HOME/Library/Application Support/Agent Monitor"
DEFAULT_VENV="$APP_SUPPORT/.venv"
BIN_DIR="$HOME/.local/bin"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'agent-monitor install: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install the Agent Monitor macOS probe (one command).

Usage: install.sh [options]

  --url URL          Bridge URL. When given, this Mac is registered during the
                     install (the bootstrap token is prompted for, not echoed).
  --owner-id ID      Owner ID printed by setup on another Mac, for a second Mac.
  --brand NAME       Agent brand shown on the phone: hermes (default), codex, pi.
  --plugin           Also install and enable the read-only Hermes observer plugin.
  --service          Also write the opt-in login service (not loaded).
  --version VERSION  Release to install (default: the release this script ships with).
  --wheel PATH       Install a local wheel instead of downloading one.
  --venv PATH        Virtual environment location (default: ~/Library/Application
                     Support/Agent Monitor/.venv).
  --force            Reinstall even if the same version is present.
  -h, --help         Show this help.

Confirmed flags can also be set through the environment:
AGENT_MONITOR_VERSION, AGENT_MONITOR_VENV, AGENT_MONITOR_PYTHON.
EOF
}

URL=""
OWNER_ID=""
BRAND=""
DO_PLUGIN=0
DO_SERVICE=0
FORCE=0
WHEEL=""
PYTHON="${AGENT_MONITOR_PYTHON:-}"
VENV="${AGENT_MONITOR_VENV:-$DEFAULT_VENV}"

need_value() { [ $# -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url) need_value "$@"; URL="$2"; shift 2 ;;
    --url=*) URL="${1#*=}"; shift ;;
    --owner-id) need_value "$@"; OWNER_ID="$2"; shift 2 ;;
    --owner-id=*) OWNER_ID="${1#*=}"; shift ;;
    --brand) need_value "$@"; BRAND="$2"; shift 2 ;;
    --brand=*) BRAND="${1#*=}"; shift ;;
    --version) need_value "$@"; VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --wheel) need_value "$@"; WHEEL="$2"; shift 2 ;;
    --wheel=*) WHEEL="${1#*=}"; shift ;;
    --venv) need_value "$@"; VENV="$2"; shift 2 ;;
    --venv=*) VENV="${1#*=}"; shift ;;
    --plugin) DO_PLUGIN=1; shift ;;
    --service) DO_SERVICE=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    ''|--) shift ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "the probe needs macOS (Keychain and LaunchAgent support)"

# --- interpreter ------------------------------------------------------------

python_ok() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

find_python() {
  if [ -n "$PYTHON" ]; then
    command -v "$PYTHON" >/dev/null 2>&1 || die "AGENT_MONITOR_PYTHON=$PYTHON is not on PATH"
    python_ok "$PYTHON" || die "$PYTHON is older than 3.11"
    printf '%s' "$PYTHON"
    return 0
  fi
  # Pick the newest interpreter on the machine: old 3.11 patch releases ship an
  # OpenSSL that pip cannot use against pypi.org, so a plain `python3` is not enough.
  best=""
  best_version=""
  for candidate in python3.16 python3.15 python3.14 python3.13 python3.12 python3.11 \
                   /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    python_ok "$candidate" || continue
    version="$("$candidate" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)" || continue
    if [ -z "$best" ]; then
      best="$candidate"
      best_version="$version"
      continue
    fi
    newer="$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)"
    if [ "$newer" = "$version" ] && [ "$version" != "$best_version" ]; then
      best="$candidate"
      best_version="$version"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# --- download ---------------------------------------------------------------

TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/agent-monitor-install.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

verify_wheel() {
  wheel_path="$1"
  wheel_name="$2"
  base_url="$3"
  if ! curl -fLsS --proto '=https' --max-time 60 --retry 2 \
        -o "$WORK/SHA256SUMS" "$base_url/SHA256SUMS" </dev/null 2>/dev/null; then
    warn "SHA256SUMS is not available for v$VERSION; skipping the checksum check"
    return 0
  fi
  expected="$(awk -v name="$wheel_name" '$2 == name || $2 == "*" name { print $1; exit }' "$WORK/SHA256SUMS")"
  [ -n "$expected" ] || { warn "SHA256SUMS does not list $wheel_name; skipping the checksum check"; return 0; }
  actual="$(shasum -a 256 "$wheel_path" | awk '{ print $1 }')"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $wheel_name (expected $expected, got $actual)"
  say "Checksum verified."
}

# --- install ----------------------------------------------------------------

say "Installing Agent Monitor probe v$VERSION."

if [ -x "$VENV/bin/python" ]; then
  if ! python_ok "$VENV/bin/python"; then
    if [ -f "$VENV/pyvenv.cfg" ]; then
      say "The existing environment at $VENV uses Python older than 3.11; recreating it."
      rm -rf "$VENV"
    else
      die "$VENV exists but is not a virtual environment; move it aside or pick another --venv"
    fi
  fi
fi

if [ ! -x "$VENV/bin/python" ]; then
  PYTHON="$(find_python)" || die "no Python 3.11 or newer found. Install one with: brew install python@3.12"
  say "Using $("$PYTHON" -c 'import sys; print("Python %d.%d" % sys.version_info[:2])')."
  say "Creating a virtual environment at $VENV"
  mkdir -p "$(dirname "$VENV")"
  "$PYTHON" -m venv "$VENV" </dev/null || die "could not create a virtual environment at $VENV"
fi

VENV_PYTHON="$VENV/bin/python"

if [ -n "$WHEEL" ]; then
  [ -f "$WHEEL" ] || die "wheel not found: $WHEEL"
  case "$WHEEL" in
    /*) WHEEL_PATH="$WHEEL" ;;
    *) WHEEL_PATH="$(cd "$(dirname "$WHEEL")" && pwd)/$(basename "$WHEEL")" ;;
  esac
  say "Using the local wheel $WHEEL_PATH"
else
  WHEEL_NAME="agent_notification-${VERSION}-py3-none-any.whl"
  ASSET_BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
  WHEEL_PATH="$WORK/$WHEEL_NAME"
  say "Downloading $WHEEL_NAME"
  curl -fLsS --proto '=https' --max-time 300 --retry 2 \
    -o "$WHEEL_PATH" "$ASSET_BASE/$WHEEL_NAME" </dev/null \
    || die "could not download $ASSET_BASE/$WHEEL_NAME; check that v$VERSION exists and the network is reachable"
  verify_wheel "$WHEEL_PATH" "$WHEEL_NAME" "$ASSET_BASE"
fi

INSTALLED="$("$VENV_PYTHON" -m pip show agent-notification 2>/dev/null | awk -F': ' '/^Version:/{ print $2; exit }' || true)"
if [ "$INSTALLED" = "$VERSION" ] && [ "$FORCE" -eq 0 ]; then
  say "The probe is already installed at $INSTALLED; nothing to upgrade. Use --force to reinstall."
else
  if [ "$FORCE" -eq 1 ] && [ -n "$INSTALLED" ]; then
    # pip treats the same version as satisfied, so remove it first; dependencies stay.
    "$VENV_PYTHON" -m pip uninstall -y -q agent-notification </dev/null >/dev/null 2>&1 || true
  fi
  say "Installing into $VENV (this may take a minute)."
  if ! "$VENV_PYTHON" -m pip install --quiet --upgrade --disable-pip-version-check \
         "${WHEEL_PATH}[qrcode]" </dev/null; then
    warn "the optional QR package could not be installed; continuing without it"
    "$VENV_PYTHON" -m pip install --quiet --upgrade --disable-pip-version-check \
      "$WHEEL_PATH" </dev/null || die "pip install failed; run '$VENV_PYTHON -m pip install \"$WHEEL_PATH\"' to see why"
  fi
fi

CLI="$VENV/bin/agent-monitor"
[ -x "$CLI" ] || die "installation finished but $CLI is missing"

mkdir -p "$BIN_DIR"
ln -sf "$CLI" "$BIN_DIR/agent-monitor"
say "Linked $BIN_DIR/agent-monitor"
case ":${PATH}:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add it with: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
if ! command -v agent-monitor >/dev/null 2>&1; then
  PATH="$BIN_DIR:$PATH"
fi

# --- optional steps ---------------------------------------------------------

if [ "$DO_PLUGIN" -eq 1 ]; then
  "$CLI" install-plugin || die "the observer plugin could not be installed"
  if command -v hermes >/dev/null 2>&1; then
    hermes plugins enable agent_monitor </dev/null || warn "enable the plugin with: hermes plugins enable agent_monitor"
  else
    warn "hermes is not on PATH; when it is, run: hermes plugins enable agent_monitor"
  fi
fi

CONFIG="$APP_SUPPORT/config.json"
if [ -n "${AGENT_MONITOR_CONFIG:-}" ]; then
  CONFIG="$AGENT_MONITOR_CONFIG"
fi

CONFIGURED=0
if [ -n "$URL" ]; then
  if [ -f "$CONFIG" ] && [ "$FORCE" -eq 0 ]; then
    say "This Mac is already registered; leaving $CONFIG alone."
    say "To register it again, run: agent-monitor setup --url $URL"
    CONFIGURED=1
  elif [ -r /dev/tty ]; then
    say ""
    say "Registering this Mac with $URL"
    if [ -n "$OWNER_ID" ] && [ -n "$BRAND" ]; then
      "$CLI" setup --url "$URL" --owner-id "$OWNER_ID" --brand "$BRAND" </dev/tty
    elif [ -n "$OWNER_ID" ]; then
      "$CLI" setup --url "$URL" --owner-id "$OWNER_ID" </dev/tty
    elif [ -n "$BRAND" ]; then
      "$CLI" setup --url "$URL" --brand "$BRAND" </dev/tty
    else
      "$CLI" setup --url "$URL" </dev/tty
    fi
    CONFIGURED=1
  else
    warn "no terminal available for the bootstrap token; run afterwards:"
    warn "  agent-monitor setup --url $URL"
  fi
fi

if [ "$DO_SERVICE" -eq 1 ]; then
  "$CLI" install-service || warn "the login service could not be installed"
fi

# --- next steps -------------------------------------------------------------

say ""
say "Installed the Agent Monitor probe v$VERSION in $VENV"
say "Command: $BIN_DIR/agent-monitor"
say ""
if [ "$CONFIGURED" -eq 0 ]; then
  say "Next steps:"
  say "  1. Register this Mac:   agent-monitor setup --url https://your-project.vercel.app"
  say "  2. Observer plugin:     agent-monitor install-plugin && hermes plugins enable agent_monitor"
  say "  3. Pair the iPhone:     agent-monitor pair"
  say "  4. Start the probe:     agent-monitor run"
  say "     or install the opt-in login service: agent-monitor install-service"
else
  say "Next steps:"
  say "  1. Pair the iPhone:     agent-monitor pair"
  say "  2. Start the probe:     agent-monitor run"
  say "     or install the opt-in login service: agent-monitor install-service"
fi
say ""
say "Restart the Hermes desktop app once after enabling the plugin so turn events are wired up."