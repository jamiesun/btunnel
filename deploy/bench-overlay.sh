#!/bin/sh
# bench-overlay — live-overlay benchmark runbook driver (issue #102).
#
# WHAT: measure the REAL subnetra overlay between two nodes — RTT/jitter and
# throughput/pps — with host `ping` + `iperf3`, then attribute any loss using the
# daemon's own counters (`subnetra status`). Unlike issue #97's single-host netns
# CI baseline, this exercises the ACTUAL mesh: real NAT/WAN, hub relay, cross-OS
# spokes. The number is informative, not a reproducible CI gate.
#
# READ-ONLY: it only runs ping/iperf3 and READS `subnetra status`. It never
# changes host networking, never mutates the daemon, and is NOT part of the
# shipped binary. `iperf3` is a HOST tool — never linked into subnetrad (iron law #1).
#
# Two roles — run the server on the TARGET, the client on the PEER:
#   On the target/hub:   deploy/bench-overlay.sh serve 10.66.0.1
#                        (convenience for: iperf3 -s -B 10.66.0.1)
#   On the peer/spoke:   deploy/bench-overlay.sh 10.66.0.1
#                        (ping + the iperf3 client matrix against the target)
#
# Options (client mode; sensible defaults):
#   -t SECONDS  per-iperf3 duration            (default 20)
#   -P N        parallel streams for the bulk run (default 4)
#   -n COUNT    ping count                     (default 20)
#   -u          also run UDP throughput + small-packet (64B) pps tests
#   -d IP       also benchmark a DIRECT underlay/public IP, to derive the
#               tunnel-overhead % (overlay vs direct, single-stream TCP)
#   -h          show this help
#
# Exit 0 if every stage ran and the peer was reachable; non-zero if a required
# tool is missing or the peer is unreachable. POSIX sh, BusyBox-friendly, no bashisms.
#
# NOTE on the shipped binary: subnetrad always ships -O ReleaseSmall (iron law #6).
# Building -Doptimize=fast is for the crypto/forward microbenchmarks, not for this
# end-to-end test, which measures the deployed daemon as-is.
set -u

DUR=20
PAR=4
PINGS=20
DO_UDP=0
DIRECT=""

usage() {
    cat <<'EOF'
bench-overlay — live subnetra overlay benchmark (issue #102)

Roles:
  serve <overlay-ip>     iperf3 server bound to the overlay IP   (run on the TARGET)
  <overlay-ip> [opts]    ping + iperf3 client matrix vs target   (run on the PEER)

Options (client mode):
  -t SECONDS   per-iperf3 duration             (default 20)
  -P N         parallel streams for bulk run   (default 4)
  -n COUNT     ping count                       (default 20)
  -u           also run UDP throughput + 64B small-packet pps
  -d IP        also benchmark a DIRECT IP -> tunnel-overhead %
  -h           this help

Examples:
  deploy/bench-overlay.sh serve 10.66.0.1        # on the hub/target
  deploy/bench-overlay.sh 10.66.0.1 -u -t 30     # on a spoke/peer

READ-ONLY: only runs ping/iperf3 and reads `subnetra status`. iperf3 is a host
tool, never linked into the daemon. Field measurement, not a CI gate (see #97).
EOF
    exit "${1:-0}"
}

# ---- iperf3 server convenience: bind to the overlay IP so only tunnel traffic
# reaches it (a bare `iperf3 -s` would also accept underlay clients). ----
if [ "${1:-}" = "serve" ]; then
    ip="${2:-}"
    [ -n "$ip" ] || { echo "bench-overlay: 'serve' needs the overlay IP, e.g. serve 10.66.0.1" >&2; exit 2; }
    command -v iperf3 >/dev/null 2>&1 || { echo "bench-overlay: iperf3 not found (install it on this node)" >&2; exit 3; }
    echo "bench-overlay: iperf3 server on overlay $ip (Ctrl-C to stop)"
    exec iperf3 -s -B "$ip"
fi

# ---- parse client-mode flags ----
PEER=""
while [ $# -gt 0 ]; do
    case "$1" in
        -t) DUR="${2:?-t needs a value}"; shift 2 ;;
        -P) PAR="${2:?-P needs a value}"; shift 2 ;;
        -n) PINGS="${2:?-n needs a value}"; shift 2 ;;
        -u) DO_UDP=1; shift ;;
        -d) DIRECT="${2:?-d needs an IP}"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) echo "bench-overlay: unknown option '$1'" >&2; usage 2 ;;
        *) if [ -z "$PEER" ]; then PEER="$1"; else echo "bench-overlay: unexpected arg '$1'" >&2; usage 2; fi; shift ;;
    esac
done

[ -n "$PEER" ] || { echo "bench-overlay: missing target overlay IP." >&2; echo "Try: deploy/bench-overlay.sh 10.66.0.1   (or 'serve <ip>' on the target)" >&2; exit 2; }
command -v iperf3 >/dev/null 2>&1 || { echo "bench-overlay: iperf3 not found — install it on BOTH nodes." >&2; exit 3; }
command -v ping >/dev/null 2>&1   || { echo "bench-overlay: ping not found." >&2; exit 3; }

# ---- best-effort daemon-counter snapshot (Linux only). On macOS `subnetra
# status` is Unsupported by design (UDS client is Linux-only) — we skip and hint. ----
SNAP_BEFORE="$(mktemp 2>/dev/null || echo /tmp/bench-snap-before.$$)"
SNAP_AFTER="$(mktemp  2>/dev/null || echo /tmp/bench-snap-after.$$)"
HAVE_STATUS=0
snap_status() {  # $1 = output file
    command -v subnetra >/dev/null 2>&1 || return 1
    out="$(subnetra status 2>&1)" || return 1
    case "$out" in
        *Unsupported*|*"daemon not running"*|*"control request failed"*) return 1 ;;
    esac
    printf '%s\n' "$out" >"$1"
    return 0
}

# ---- extract the single-stream receiver throughput in Mbits/sec from iperf3 -f m ----
iperf_recv_mbps() {  # reads iperf3 text on stdin
    awk '/receiver/ { for (i = 1; i <= NF; i++) if ($i == "Mbits/sec") { print $(i-1); exit } }'
}

run_iperf() {  # $1 = label, rest = iperf3 args; prints the sender/receiver summary
    label="$1"; shift
    echo "--- $label ---"
    out="$(iperf3 -f m "$@" 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then
        printf '%s\n' "$out" | grep -iE 'error|unable|refused|denied' | head -2
        echo "  FAILED (rc=$rc) — is 'bench-overlay.sh serve $PEER' running on the target, and the overlay route up?"
        return 1
    fi
    sums="$(printf '%s\n' "$out" | grep -E '\[SUM\].*(sender|receiver)')"
    if [ -n "$sums" ]; then
        printf '%s\n' "$sums" | sed 's/^/  /'
    else
        printf '%s\n' "$out" | grep -E '(sender|receiver)' | tail -2 | sed 's/^/  /'
    fi
    return 0
}

echo "============================================================"
echo " subnetra live-overlay benchmark  ->  $PEER"
echo "   duration=${DUR}s  parallel=${PAR}  pings=${PINGS}  udp=${DO_UDP}${DIRECT:+  direct=$DIRECT}"
echo "============================================================"

if snap_status "$SNAP_BEFORE"; then HAVE_STATUS=1; fi

# ---- 1) RTT / jitter / loss.  No sub-second -i: intervals < 1s need root on
# macOS, and the default 1s interval keeps this runnable unprivileged everywhere. ----
echo "=== 1) RTT  (ping -c $PINGS $PEER) ==="
PR="$(ping -c "$PINGS" "$PEER" 2>&1 || true)"
LOSS="$(printf '%s' "$PR" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' | head -1)"
RTT="$(printf '%s' "$PR" | sed -nE 's#.*= ([0-9./]+) ms#\1#p' | head -1)"
if [ -n "$RTT" ]; then
    echo "  rtt min/avg/max(/mdev) = ${RTT} ms,  loss = ${LOSS:-?}%"
else
    echo "  no RTT — peer unreachable on the overlay (loss=${LOSS:-100}%)."
    echo "  Check the tunnel is up both ways and the overlay route exists."
fi

# ---- 2) TCP single stream (baseline bulk) ----
echo "=== 2) throughput ==="
run_iperf "TCP single stream"      -c "$PEER" -t "$DUR"
# ---- 3) TCP parallel (saturate the path / a single core on the hub relay) ----
run_iperf "TCP x${PAR} parallel"   -c "$PEER" -t "$DUR" -P "$PAR"
# ---- 4) reverse (server -> client; e.g. hub -> spoke direction) ----
run_iperf "TCP reverse (-R)"       -c "$PEER" -t "$DUR" -R

# ---- 5) UDP throughput + small-packet pps (optional; shows loss% and pps) ----
if [ "$DO_UDP" = "1" ]; then
    run_iperf "UDP unbounded (loss%/jitter)" -c "$PEER" -t "$DUR" -u -b 0
    run_iperf "UDP 64B small-packet (pps)"   -c "$PEER" -t "$DUR" -u -b 0 -l 64
fi

# ---- 6) tunnel overhead vs a direct underlay/public path (optional) ----
if [ -n "$DIRECT" ]; then
    echo "=== 6) tunnel overhead (overlay vs direct $DIRECT) ==="
    ov="$(iperf3 -f m -c "$PEER"   -t "$DUR" 2>/dev/null | iperf_recv_mbps)"
    di="$(iperf3 -f m -c "$DIRECT" -t "$DUR" 2>/dev/null | iperf_recv_mbps)"
    if [ -n "$ov" ] && [ -n "$di" ]; then
        awk -v o="$ov" -v d="$di" 'BEGIN{ printf "  overlay=%s Mbps  direct=%s Mbps  overhead=%.1f%%\n", o, d, (d>0?(1-o/d)*100:0) }'
    else
        echo "  could not measure both paths (overlay=${ov:-?} direct=${di:-?})"
    fi
fi

# ---- 7) loss attribution from the daemon's own counters ----
echo "=== 7) daemon counters ==="
if [ "$HAVE_STATUS" = "1" ] && snap_status "$SNAP_AFTER"; then
    echo "  delta in 'subnetra status' over this run (look for nonzero drop_* / *_send_err):"
    diff -u "$SNAP_BEFORE" "$SNAP_AFTER" 2>/dev/null | grep -E '^[+-] ' | grep -vE '^[+-]{3}' | grep -E 'packets|bytes|drop|send_err|relay|learned' | sed 's/^/    /' || true
    echo "  (counters are cumulative; a nonzero drop_* delta localizes loss to THIS node.)"
else
    echo "  'subnetra status' not available here (macOS = Unsupported by design, or daemon"
    echo "   not on this box). Query the HUB for per-peer relay/drops/last_seen:"
    echo "     ssh <hub> 'sudo subnetra status'"
    echo "   On a macOS spoke, run: deploy/mac-spoke-status.sh"
fi

# ---- caveats ----
echo "=== notes ==="
echo "  - Overlay MTU is 1452 (raw_direct); the inner payload must not exceed it"
echo "    (MAX_PLAINTEXT). Large-transfer stalls with small-packet success = MTU;"
echo "    print the safe MTU + MSS clamp with: subnetrad --print-network-plan."
echo "  - For a single-core hub, the relay does ingress-decrypt + egress-encrypt on"
echo "    one thread, so a hub saturates a core first — watch its CPU during the x${PAR} run."
echo "  - This is field measurement (real NAT/WAN). For a repeatable CI baseline see #97."

rm -f "$SNAP_BEFORE" "$SNAP_AFTER" 2>/dev/null || true
[ -n "$RTT" ]
