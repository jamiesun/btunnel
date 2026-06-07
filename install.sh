#!/bin/sh
# Subnetra interactive installer.
#
#   curl -fsSL https://raw.githubusercontent.com/jamiesun/subnetra/main/install.sh | sh
#   ./install.sh [--yes] [--dir DIR] [--version vX.Y.Z]
#
# It detects your OS/arch, downloads the matching release tarball, verifies it
# against the release SHA256SUMS.txt, and installs the `subnetra` and `subnetrad`
# binaries after asking you to confirm.
#
# It deliberately does NOT touch your network, firewall, or system services.
# Subnetra only ever *prints* a host plan; you apply it yourself. See the docs.

set -eu

REPO="jamiesun/subnetra"
INSTALL_DIR="${SUBNETRA_INSTALL_DIR:-/usr/local/bin}"
VERSION="${SUBNETRA_VERSION:-}"
ASSUME_YES="${ASSUME_YES:-0}"
WANT_SERVICE="${SUBNETRA_SERVICE:-}"
UNIT_DIR_OVERRIDE="${SUBNETRA_UNIT_DIR:-}"

# ---------- output helpers ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$(printf '\033[1m'); R=$(printf '\033[0m'); C=$(printf '\033[36m')
  Y=$(printf '\033[33m'); G=$(printf '\033[32m'); E=$(printf '\033[31m')
else
  B=''; R=''; C=''; Y=''; G=''; E=''
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C" "$R" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$R" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$E" "$R" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Subnetra installer

Usage: install.sh [options]

Options:
  -y, --yes            Accept defaults and do not prompt (non-interactive).
      --dir DIR        Install directory (default: $INSTALL_DIR).
      --version VER    Release tag to install, e.g. v0.6.0 (default: latest).
      --service        Also install the (disabled) systemd/launchd service unit.
      --no-service     Do not install a service unit (skip the prompt).
  -h, --help           Show this help and exit.

Environment overrides: SUBNETRA_INSTALL_DIR, SUBNETRA_VERSION, SUBNETRA_SERVICE=1,
                       SUBNETRA_UNIT_DIR, ASSUME_YES=1, NO_COLOR=1
EOF
}

# ---------- parse args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)       ASSUME_YES=1 ;;
    --dir)          shift; [ $# -gt 0 ] || err "--dir needs a value"; INSTALL_DIR="$1" ;;
    --dir=*)        INSTALL_DIR="${1#--dir=}" ;;
    --version)      shift; [ $# -gt 0 ] || err "--version needs a value"; VERSION="$1" ;;
    --version=*)    VERSION="${1#--version=}" ;;
    --service)      WANT_SERVICE=1 ;;
    --no-service)   WANT_SERVICE=0 ;;
    -h|--help)      usage; exit 0 ;;
    *)              err "unknown option: $1 (try --help)" ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || err "required tool not found: $1"; }
need curl; need tar; need uname; need mktemp

# ---------- detect platform ----------
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=macos ;;
  *)      err "unsupported operating system: $(uname -s) (Linux and macOS only)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)       ARCH=amd64 ;;
  aarch64|arm64)      ARCH=arm64 ;;
  armv7l|armv7)       ARCH=armv7 ;;
  armv6l|armv5*|arm)  ARCH=armv5 ;;
  *)                  err "unsupported architecture: $(uname -m)" ;;
esac
if [ "$OS" = macos ] && [ "$ARCH" != amd64 ] && [ "$ARCH" != arm64 ]; then
  err "no macOS build for $ARCH (macOS is amd64/arm64 only)"
fi

# ---------- resolve latest version (via the releases/latest redirect; no jq) ----------
if [ -z "$VERSION" ]; then
  info "Resolving the latest release..."
  eff=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
    || err "could not reach GitHub to resolve the latest release"
  VERSION="${eff##*/tag/}"
  case "$VERSION" in
    v[0-9]*) : ;;
    *) err "could not parse a version tag from: $eff" ;;
  esac
fi

ASSET="subnetra-${VERSION}-${OS}-${ARCH}.tar.gz"
DL="https://github.com/$REPO/releases/download/${VERSION}"

# ---------- prompt helpers (read the controlling TTY so this works under curl|sh) ----------
# A readable /dev/tty node does not guarantee a usable terminal: when there is no
# controlling TTY, the node still passes `[ -r ]` but fails to open. Probe it for real.
if { : < /dev/tty; } 2>/dev/null; then HAVE_TTY=1; else HAVE_TTY=0; fi

prompt() {
  _ans=''
  if [ "$HAVE_TTY" = 1 ]; then
    printf '%s' "$1" > /dev/tty
    IFS= read -r _ans < /dev/tty || _ans=''
  fi
  printf '%s' "$_ans"
}
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$HAVE_TTY" = 1 ] || err "no interactive terminal; re-run with --yes to accept the defaults"
  case "$(prompt "$1 [y/N] ")" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- show plan, let the user adjust the dir, confirm ----------
say ""
say "${B}Subnetra installer${R}"
say "  platform     ${B}${OS}/${ARCH}${R}"
say "  version      ${B}${VERSION}${R}"
say "  asset        ${ASSET}"
say "  install dir  ${B}${INSTALL_DIR}${R}  (installs: subnetra, subnetrad)"
say ""

if [ "$ASSUME_YES" != 1 ] && [ "$HAVE_TTY" = 1 ]; then
  _d=$(prompt "Install directory [${INSTALL_DIR}]: ")
  if [ -n "$_d" ]; then INSTALL_DIR="$_d"; fi
fi

confirm "Download Subnetra ${VERSION} and install to ${INSTALL_DIR}?" \
  || { info "Aborted — nothing was changed."; exit 0; }

# ---------- download ----------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

info "Downloading ${ASSET} ..."
if [ -t 2 ]; then
  curl -fL --progress-bar "$DL/$ASSET" -o "$TMP/$ASSET" || err "download failed: $DL/$ASSET"
else
  curl -fsSL "$DL/$ASSET" -o "$TMP/$ASSET" || err "download failed: $DL/$ASSET"
fi
info "Downloading SHA256SUMS.txt ..."
curl -fsSL "$DL/SHA256SUMS.txt" -o "$TMP/SHA256SUMS.txt" || err "could not download checksums"

# ---------- verify checksum ----------
sum_line=$(awk -v f="$ASSET" '$2==f {print; exit}' "$TMP/SHA256SUMS.txt")
[ -n "$sum_line" ] || err "no checksum entry for ${ASSET} in SHA256SUMS.txt"
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$TMP" && printf '%s\n' "$sum_line" | sha256sum -c - >/dev/null 2>&1 ) \
    || err "CHECKSUM MISMATCH for ${ASSET} — refusing to install"
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$TMP" && printf '%s\n' "$sum_line" | shasum -a 256 -c - >/dev/null 2>&1 ) \
    || err "CHECKSUM MISMATCH for ${ASSET} — refusing to install"
else
  warn "no sha256sum/shasum tool found — skipping checksum verification"
fi
info "Checksum verified."

# ---------- extract ----------
tar -xzf "$TMP/$ASSET" -C "$TMP" || err "failed to extract ${ASSET}"
SRC="$TMP/subnetra-${VERSION}-${OS}-${ARCH}"
[ -f "$SRC/subnetrad" ] && [ -f "$SRC/subnetra" ] || err "unexpected archive layout (binaries missing)"
if [ "$OS" = macos ]; then
  xattr -d com.apple.quarantine "$SRC/subnetrad" "$SRC/subnetra" 2>/dev/null || true
fi

# ---------- install (sudo only when the target dir is not writable) ----------
SUDO=''
if [ -d "$INSTALL_DIR" ]; then
  [ -w "$INSTALL_DIR" ] || SUDO=sudo
else
  mkdir -p "$INSTALL_DIR" 2>/dev/null || SUDO=sudo
fi
if [ -n "$SUDO" ]; then
  command -v sudo >/dev/null 2>&1 || err "${INSTALL_DIR} is not writable and sudo is unavailable"
  warn "${INSTALL_DIR} is not writable; sudo is required to install there."
  confirm "Use sudo to install into ${INSTALL_DIR}?" || err "Aborted (no permission to write ${INSTALL_DIR})."
fi
$SUDO mkdir -p "$INSTALL_DIR" || err "could not create ${INSTALL_DIR}"
$SUDO install -m 0755 "$SRC/subnetrad" "$INSTALL_DIR/subnetrad" || err "failed to install subnetrad"
$SUDO install -m 0755 "$SRC/subnetra"  "$INSTALL_DIR/subnetra"  || err "failed to install subnetra"

# ---------- verify + next steps ----------
ver_out=$("$INSTALL_DIR/subnetrad" --version 2>&1 || true)
say ""
info "Installed ${B}${ver_out:-Subnetra}${R} into ${INSTALL_DIR}"
say "  subnetrad -> $INSTALL_DIR/subnetrad"
say "  subnetra  -> $INSTALL_DIR/subnetra"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *) warn "${INSTALL_DIR} is not on your PATH — add it, e.g.  export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
esac

# ---------- optional: install the service unit (disabled; never started) ----------
# subnetra never mutates host networking, and the unit needs a per-node config plus
# operator-filled ExecStartPost network hooks before it is safe to enable. So we only
# ever place the hardened unit *template* (disabled) and print how to finish + enable.
svc_kind=''
case "$OS" in
  linux) [ -d /run/systemd/system ] && svc_kind=systemd ;;
  macos) svc_kind=launchd ;;
esac

want_svc="$WANT_SERVICE"
if [ -z "$want_svc" ]; then
  if [ -z "$svc_kind" ] || [ "$ASSUME_YES" = 1 ]; then
    want_svc=0
  elif confirm "Install the ${svc_kind} service unit now (it stays disabled until you enable it)?"; then
    want_svc=1
  else
    want_svc=0
  fi
fi

svc_installed=''; svc_unit_path=''
if [ "$want_svc" = 1 ] && [ -z "$svc_kind" ]; then
  warn "no supported service manager found here — skipping the unit (see the deployment guide)."
elif [ "$want_svc" = 1 ]; then
  case "$svc_kind" in
    systemd) unit_name=subnetrad.service;            unit_dir="${UNIT_DIR_OVERRIDE:-/etc/systemd/system}" ;;
    launchd) unit_name=net.subnetra.subnetrad.plist; unit_dir="${UNIT_DIR_OVERRIDE:-/Library/LaunchDaemons}" ;;
  esac
  tmp_unit="$TMP/$unit_name"
  if [ -f "$SRC/$unit_name" ]; then
    cp "$SRC/$unit_name" "$tmp_unit"
  else
    curl -fsSL "https://raw.githubusercontent.com/$REPO/$VERSION/deploy/$unit_name" -o "$tmp_unit" \
      || warn "could not fetch the ${svc_kind} unit template for ${VERSION}"
  fi
  if [ -f "$tmp_unit" ]; then
    if [ "$INSTALL_DIR" != /usr/local/bin ]; then
      sed "s#/usr/local/bin/subnetrad#${INSTALL_DIR}/subnetrad#g" "$tmp_unit" > "${tmp_unit}.x" \
        && mv "${tmp_unit}.x" "$tmp_unit"
    fi
    SVC_SUDO=''
    if [ "$(id -u)" != 0 ] && [ ! -w "$unit_dir" ] && [ ! -w "$(dirname "$unit_dir")" ]; then
      command -v sudo >/dev/null 2>&1 && SVC_SUDO=sudo
    fi
    if [ -e "$unit_dir/$unit_name" ] && ! confirm "${unit_dir}/${unit_name} already exists — overwrite it?"; then
      info "Kept the existing ${unit_dir}/${unit_name}."
    else
      # shellcheck disable=SC2086
      $SVC_SUDO mkdir -p "$unit_dir" 2>/dev/null || true
      # shellcheck disable=SC2086
      if $SVC_SUDO install -m 0644 "$tmp_unit" "$unit_dir/$unit_name" 2>/dev/null; then
        svc_installed=1; svc_unit_path="$unit_dir/$unit_name"
        # shellcheck disable=SC2086
        [ "$svc_kind" = systemd ] && { $SVC_SUDO systemctl daemon-reload 2>/dev/null || true; }
        info "Installed ${svc_unit_path} ${B}(disabled — not started)${R}."
      else
        warn "could not write ${unit_dir}/${unit_name} (need root?) — install it manually."
      fi
    fi
  fi
fi

say ""
say "${G}Done.${R} Subnetra is installed but ${B}not yet configured${R} — by design it never"
say "touches your network or starts itself. Next:"
say ""
say "  1. Create a config.json   (start from config.example.json or the Quick Start)"
say "  2. Preview the host plan   subnetrad --print-network-plan --config config.json"
say "  3. Apply it, then run      subnetrad --config config.json"

if [ "$svc_installed" = 1 ]; then
  say ""
  say "Service unit at ${B}${svc_unit_path}${R} ${B}(disabled)${R}. Once steps 1-3 are done:"
  case "$svc_kind" in
    systemd)
      say "  - keep the config at /etc/subnetra/config.json (root-owned, 0600)"
      say "  - fill the unit's ExecStartPost hooks with your --print-network-plan output"
      say "  - sudo systemctl enable --now subnetrad"
      ;;
    launchd)
      say "  - keep the config at /etc/subnetra/config.json (root-owned, 0600)"
      say "  - sudo launchctl bootstrap system ${svc_unit_path}"
      say "  - sudo launchctl enable system/net.subnetra.subnetrad"
      ;;
  esac
elif [ -n "$svc_kind" ]; then
  say ""
  say "Want it managed as a ${svc_kind} service? Re-run with ${B}--service${R} (it installs the"
  say "unit disabled and never starts it), or follow the deployment guide."
fi

say ""
say "  Quick Start   https://jamiesun.github.io/subnetra/en/getting-started/quickstart.html"
say "  All docs      https://jamiesun.github.io/subnetra/"
