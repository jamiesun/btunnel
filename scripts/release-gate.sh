#!/usr/bin/env bash
#
# Release gate (issue #26): run the FULL privileged integration harness in
# release-gate mode, where a SKIP is a hard failure. A release candidate is only
# certified if the live netns relay e2e actually ran (not skipped) and every
# constraint (static link, <=512KB, unit tests, encryption, RCU hot-update)
# passed. Prints a machine-readable evidence block at the end.
#
# Requirements (the harness will FAIL, not skip, if any are missing):
#   - root / CAP_NET_ADMIN          (sudo)
#   - /dev/net/tun                  (sudo modprobe tun)
#   - ip, tcpdump, ping             (iproute2, tcpdump, iputils)
#   - zig 0.16.0 on PATH
#
# Usage (from anywhere in the repo):
#   sudo scripts/release-gate.sh
#   # or non-interactively in CI, preserving PATH + the gate flag:
#   sudo --preserve-env=PATH,BTUNNEL_RELEASE_GATE \
#       env "PATH=$PATH" BTUNNEL_RELEASE_GATE=1 scripts/release-gate.sh
#
# Exit status: 0 == release-certifiable; non-zero == do NOT release.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspace)"

# Best-effort: ensure the TUN device exists before the harness runs. If this
# fails (no privilege), the harness's own preflight turns it into a hard error.
if [ ! -c /dev/net/tun ]; then
  modprobe tun 2>/dev/null || sudo modprobe tun 2>/dev/null || true
fi

export BTUNNEL_RELEASE_GATE=1
exec bash test/integration/run.sh
