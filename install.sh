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
  -h, --help           Show this help and exit.

Environment overrides: SUBNETRA_INSTALL_DIR, SUBNETRA_VERSION, ASSUME_YES=1, NO_COLOR=1
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

# ---------- detect a prior install at the target so the prompt is explicit ----------
prior=''; prior_known=''
if [ -x "$INSTALL_DIR/subnetra" ]; then
  prior_known=yes
  prior=$("$INSTALL_DIR/subnetra" --version 2>&1 | sed -n 's/.*\(v[0-9][0-9.]*\).*/\1/p' | head -n1)
fi

if [ -z "$prior_known" ]; then
  _q="Download Subnetra ${VERSION} and install to ${INSTALL_DIR}?"
elif [ "$prior" = "$VERSION" ]; then
  info "Subnetra ${VERSION} is already installed in ${INSTALL_DIR}."
  _q="Reinstall (overwrite) Subnetra ${VERSION}?"
elif [ -n "$prior" ]; then
  info "Subnetra ${prior} is already installed in ${INSTALL_DIR}."
  _q="Replace Subnetra ${prior} with ${VERSION}?"
else
  info "An existing Subnetra install was found in ${INSTALL_DIR}."
  _q="Overwrite it with Subnetra ${VERSION}?"
fi

confirm "$_q" || { info "Aborted — nothing was changed."; exit 0; }

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

cat <<EOF

${G}Done.${R} Subnetra is installed but ${B}not yet configured${R} — by design it never
touches your network for you. Next:

  1. Create a config.json   (start from config.example.json or the Quick Start)
  2. Preview the host plan   subnetrad --print-network-plan --config config.json
  3. Apply it, then run      subnetrad --config config.json

  Quick Start   https://jamiesun.github.io/subnetra/en/getting-started/quickstart.html
  All docs      https://jamiesun.github.io/subnetra/
EOF
