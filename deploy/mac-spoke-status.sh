#!/usr/bin/env bash
# subnetra macOS spoke — status / health check.
#
# WHY THIS EXISTS: on macOS `sudo subnetra status` returns
#   "control request failed (Unsupported)"
# BY DESIGN — the Unix-domain-socket control *client* is compiled for Linux only
# (src/uds.zig: non-Linux returns error.Unsupported). The daemon itself runs fine;
# you just cannot query it through the CLI on macOS. This script gives the macOS
# equivalent: it inspects the process, the kernel-assigned utunN interface, the
# [ready] banner, and live overlay reachability — none of which need the control
# socket. For per-peer counters (relay/drops/last_seen) query the HUB (Linux):
#   ssh <hub> 'sudo subnetra status'
#
# Usage:
#   bash deploy/mac-spoke-status.sh           # no root required
#   HUB_IP=10.66.0.1 bash deploy/mac-spoke-status.sh
#
# Env overrides (all optional — sensible defaults are auto-detected):
#   TUN     subnetra interface (default: from log [ready] banner, else autodetect)
#   HUB_IP  hub overlay IP to ping (default: .1 of the spoke's overlay /24)
#   LOG     daemon log path (default: tries /tmp/subnetra-mac.log then /var/log/subnetrad.log)
#
# Exit code: 0 if the spoke is healthy (daemon up + interface up + overlay ping OK),
# non-zero otherwise — so it is usable in monitoring / CI.
set -uo pipefail

CFG="/etc/subnetra/config.json"
PIDF="/tmp/subnetra-mac.pid"
KAPIDF="/tmp/subnetra-mac-keepalive.pid"
LOG_DEFAULTS=("/tmp/subnetra-mac.log" "/var/log/subnetrad.log")

c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
pass(){ printf "  ${c_ok}✓${c_off} %s\n" "$*"; }
fail(){ printf "  ${c_bad}✗${c_off} %s\n" "$*"; HEALTHY=0; }
note(){ printf "  ${c_dim}· %s${c_off}\n" "$*"; }
HEALTHY=1

# --- resolve log ---
LOG="${LOG:-}"
if [ -z "$LOG" ]; then
  for f in "${LOG_DEFAULTS[@]}"; do [ -f "$f" ] && { LOG="$f"; break; }; done
fi

# --- 1) daemon process ---
echo "=== 1) daemon ==="
DPID="$(pgrep -f 'subnetrad --config' | head -1 || true)"
if [ -n "$DPID" ]; then
  ET="$(ps -p "$DPID" -o etime= 2>/dev/null | tr -d ' ')"
  pass "subnetrad running (pid $DPID, uptime ${ET:-?})"
else
  fail "subnetrad NOT running"
fi

# --- 2) keepalive (holds the NAT pinhole open so the hub can relay inbound) ---
echo "=== 2) NAT keepalive ==="
KPID="$(cat "$KAPIDF" 2>/dev/null || true)"
if [ -n "$KPID" ] && ps -p "$KPID" >/dev/null 2>&1; then
  ET="$(ps -p "$KPID" -o etime= 2>/dev/null | tr -d ' ')"
  pass "keepalive running (pid $KPID, uptime ${ET:-?}) — pinging hub every ~15s"
else
  fail "keepalive NOT running (idle NAT pinhole may close → hub can't reach this spoke)"
fi

# --- 3) tun interface (utunN is kernel-assigned; detect, don't hardcode) ---
echo "=== 3) interface ==="
if [ -z "${TUN:-}" ] && [ -n "$LOG" ]; then
  TUN="$(sed -nE 's/.* tun=([^ ]+) .*/\1/p' "$LOG" 2>/dev/null | tail -1)"
fi
if [ -z "${TUN:-}" ]; then
  # fallback: subnetra sets `inet X --> X` (src == dst peer) — distinctive vs other VPNs
  TUN="$(ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{i=$1;sub(":","",i)} /inet /&&$2==$4{print i;exit}')"
fi
SELF=""
if [ -n "${TUN:-}" ] && ifconfig "$TUN" >/dev/null 2>&1; then
  SELF="$(ifconfig "$TUN" 2>/dev/null | awk '/inet /{print $2; exit}')"
  STATE="$(ifconfig "$TUN" 2>/dev/null | sed -n '1p')"
  if printf '%s' "$STATE" | grep -q 'UP'; then
    pass "$TUN UP — overlay addr ${SELF:-?}"
    note "$(printf '%s' "$STATE" | sed 's/^[[:space:]]*//')"
  else
    fail "$TUN exists but is DOWN"
  fi
else
  fail "no subnetra utun interface found"
fi

# --- 4) [ready] banner ---
echo "=== 4) daemon banner ==="
if [ -n "$LOG" ] && [ -f "$LOG" ]; then
  B="$(grep -E '\[ready\]|\[config ok\]|error|ERROR' "$LOG" 2>/dev/null | tail -1)"
  [ -n "$B" ] && note "$B" || note "(no banner line in $LOG)"
  note "log: $LOG"
else
  note "(no daemon log found; set LOG=/path if non-default)"
fi

# --- 5) overlay reachability (the definitive health signal on macOS) ---
echo "=== 5) overlay reachability ==="
if [ -z "${HUB_IP:-}" ]; then
  if [ -n "$SELF" ]; then
    HUB_IP="$(printf '%s' "$SELF" | awk -F. '{print $1"."$2"."$3".1"}')"
  else
    HUB_IP="10.66.0.1"
  fi
fi
PR="$(ping -c 4 -i 0.5 -t 3 "$HUB_IP" 2>&1)"
LOSS="$(printf '%s' "$PR" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' | head -1)"
RTT="$(printf '%s' "$PR" | sed -nE 's#.*= ([0-9./]+) ms#\1#p' | head -1)"
if [ "${LOSS:-100}" != "100" ] && [ "${LOSS:-100}" != "100.0" ]; then
  pass "ping hub $HUB_IP — ${LOSS:-?}% loss, rtt(min/avg/max) ${RTT:-?} ms"
else
  fail "ping hub $HUB_IP — 100% loss (overlay DOWN)"
fi

# --- summary ---
echo "=== summary ==="
if [ "$HEALTHY" = "1" ]; then
  printf "  ${c_ok}SPOKE HEALTHY${c_off}\n"
else
  printf "  ${c_bad}SPOKE UNHEALTHY${c_off} — see ✗ above\n"
fi
note "Per-peer counters (relay/drops/last_seen) are Linux-only; query the hub:"
note "  ssh <hub> 'sudo subnetra status'"
[ "$HEALTHY" = "1" ]
