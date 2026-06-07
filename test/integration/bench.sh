#!/usr/bin/env bash
#
# Subnetra data-plane throughput / PPS benchmark (issue #97).
#
# The single-host, REPRODUCIBLE companion to the live-overlay field tool
# (deploy/bench-overlay.sh, issue #102). It stands up the same 3-node hub-and-spoke
# star the integration harness uses — entirely in local network namespaces — builds
# the daemon `-Doptimize=ReleaseFast` (measurement only; the SHIPPED binary always
# stays ReleaseSmall, iron law #6), saturates the overlay with the in-tree
# `udp-blast` generator, and reads the achieved packet-rate / throughput from each
# daemon's OWN counters (`subnetra status`). It records a baseline so a data-plane
# perf regression becomes a tracked number, the same way the <=512KB size budget is.
#
# Two load patterns (issue #97 step 1):
#   1. spoke -> hub        (the hub terminates; one decrypt per packet)
#   2. spoke -> hub -> spoke (RELAY; the hub pays recvfrom+sendto AND open+seal per
#                            packet — it saturates a core first, so this is the
#                            number issue #100's recvmmsg/sendmmsg batching targets)
#
# It measures, per pattern: the hub's achieved pps, the inner goodput at the snr0
# MTU (Gbps), and the hub daemon's single-core CPU%. The generator's self-reported
# OFFERED load is printed too, as the upper bound the daemon was pushed against.
#
# READ-ONLY w.r.t. the repo and the host: it only creates throwaway namespaces it
# also deletes, builds into a tempdir, and never mutates host networking outside
# those namespaces. `udp-blast` is a TEST tool, never linked into the daemon
# (iron law #1). Missing prerequisites SKIP (never fake a number).
#
# Usage (from the repo root; needs root for netns + /dev/net/tun):
#   sudo test/integration/bench.sh
#   SUBNETRA_BENCH_SECS=10 sudo --preserve-env test/integration/bench.sh
#
# Env knobs:
#   SUBNETRA_BENCH_SECS   blast seconds per pattern        (default 5)
#   SUBNETRA_BENCH_SIZE   udp payload bytes (inner=+28)    (default 1372 -> 1400 MTU)
#   SUBNETRA_BENCH_PIN    1 = taskset-pin the hub to its own core when nproc>=2 (default 1)
#   SUBNETRA_BENCH_BASELINE  baseline file to diff against (default test/integration/bench-baseline.env)
set -euo pipefail

SECS="${SUBNETRA_BENCH_SECS:-5}"
PAYLOAD="${SUBNETRA_BENCH_SIZE:-1372}"
PIN="${SUBNETRA_BENCH_PIN:-1}"
INNER=$(( PAYLOAD + 28 ))   # +20 IPv4 +8 UDP

log()  { printf '\033[1;34m[ii]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspace)"
BASELINE="${SUBNETRA_BENCH_BASELINE:-test/integration/bench-baseline.env}"

# Per-link private PSKs (issue #13): the hub<->a and hub<->b links must not share a key.
PSK_A="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
PSK_B="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
NS=(bt_bench_hub bt_bench_a bt_bench_b)
declare -a PIDS=()
TMP=""

cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for ns in "${NS[@]}"; do ip netns del "$ns" >/dev/null 2>&1 || true; done
  [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
}

# --- preflight: never fake a benchmark; SKIP loudly if a prerequisite is absent ---
if [ "$(id -u)" -ne 0 ]; then
  skip "data-plane benchmark: not root (need CAP_NET_ADMIN for netns + tun)"
  exit 0
fi
for tool in ip awk; do
  command -v "$tool" >/dev/null 2>&1 || { skip "data-plane benchmark: '$tool' not available"; exit 0; }
done
if [ ! -c /dev/net/tun ]; then
  skip "data-plane benchmark: /dev/net/tun missing (run with --device=/dev/net/tun)"
  exit 0
fi

log "zig: $(zig version 2>/dev/null || echo '??')   secs/pattern=${SECS}  payload=${PAYLOAD}B  inner=${INNER}B"

# --- build ReleaseFast (measurement only) ---------------------------------------
# iron law #6 unchanged: this is an out-of-tree measurement build into a tempdir;
# the default `zig build` artifact and the size gate are untouched.
log "building subnetrad + subnetra + udp-blast (-Doptimize=ReleaseFast) ..."
zig build -Doptimize=ReleaseFast >/dev/null || die "ReleaseFast build of the daemon failed"
zig build tool:udp-blast -Doptimize=ReleaseFast >/dev/null || die "ReleaseFast build of udp-blast failed"
SUBNETRAD="$PWD/zig-out/bin/subnetrad"
SUBNETRA="$PWD/zig-out/bin/subnetra"
BLAST="$PWD/zig-out/tools/udp-blast"
for b in "$SUBNETRAD" "$SUBNETRA" "$BLAST"; do [ -x "$b" ] || die "missing build artifact: $b"; done

trap cleanup EXIT

# --- optional core pinning so the hub's single-thread ceiling is not muddied -----
NPROC=$(nproc 2>/dev/null || echo 1)
PIN_HUB=(); PIN_REST=()
if [ "$PIN" = "1" ] && [ "$NPROC" -ge 2 ] && command -v taskset >/dev/null 2>&1; then
  PIN_HUB=(taskset -c 0)
  PIN_REST=(taskset -c "1-$((NPROC - 1))")
  log "core pinning: hub -> cpu0, spokes+generator -> cpu1-$((NPROC - 1)) (nproc=${NPROC})"
else
  log "core pinning: off (nproc=${NPROC}); the hub shares cores with the load — numbers are a floor"
fi

# --- namespaces + point-to-point veth underlay (mirrors the integration harness) -
for ns in "${NS[@]}"; do ip netns del "$ns" >/dev/null 2>&1 || true; done
TMP=$(mktemp -d)
mkdir -p "$TMP/hub" "$TMP/a" "$TMP/b"
for d in hub a b; do cp "$SUBNETRAD" "$TMP/$d/subnetrad"; done

for ns in "${NS[@]}"; do ip netns add "$ns"; done
ip link add veth_bha type veth peer name veth_bah
ip link set veth_bha netns bt_bench_hub
ip link set veth_bah netns bt_bench_a
ip link add veth_bhb type veth peer name veth_bbh
ip link set veth_bhb netns bt_bench_hub
ip link set veth_bbh netns bt_bench_b

ip netns exec bt_bench_hub ip addr add 10.100.1.1/24 dev veth_bha
ip netns exec bt_bench_hub ip addr add 10.100.2.1/24 dev veth_bhb
ip netns exec bt_bench_a   ip addr add 10.100.1.2/24 dev veth_bah
ip netns exec bt_bench_b   ip addr add 10.100.2.2/24 dev veth_bbh
ip netns exec bt_bench_hub ip link set veth_bha up
ip netns exec bt_bench_hub ip link set veth_bhb up
ip netns exec bt_bench_a   ip link set veth_bah up
ip netns exec bt_bench_b   ip link set veth_bbh up
for ns in "${NS[@]}"; do ip netns exec "$ns" ip link set lo up; done

write_config() { # write_config <dir> <local_id> <peers-json>
  cat > "$1/config.json" <<EOF
{ "local_id": $2, "peers": $3 }
EOF
}
# Hub knows both spokes; each spoke knows only the hub (per-link PSK, issue #13).
write_config "$TMP/hub" 1 \
  "[ {\"id\":2,\"endpoint\":\"10.100.1.2:51820\",\"allowed_src\":\"10.0.0.2/32\",\"psk\":\"$PSK_A\"},
     {\"id\":3,\"endpoint\":\"10.100.2.2:51820\",\"allowed_src\":\"10.0.0.3/32\",\"psk\":\"$PSK_B\"} ]"
write_config "$TMP/a" 2 \
  "[ {\"id\":1,\"endpoint\":\"10.100.1.1:51820\",\"allowed_src\":\"10.0.0.0/24\",\"psk\":\"$PSK_A\"} ]"
write_config "$TMP/b" 3 \
  "[ {\"id\":1,\"endpoint\":\"10.100.2.1:51820\",\"allowed_src\":\"10.0.0.0/24\",\"psk\":\"$PSK_B\"} ]"

HUB_SOCK="$TMP/hub.sock"; A_SOCK="$TMP/a.sock"; B_SOCK="$TMP/b.sock"
start_daemon() { # start_daemon <ns> <dir> <sock> [pin-prefix...]
  local ns="$1" dir="$2" sock="$3"; shift 3
  # The daemon reads config.json from its CWD, so cd into the node dir first
  # (mirrors run.sh). Any pin prefix ("$@", e.g. `taskset -c 0`) wraps the exec
  # chain so the daemon inherits the CPU affinity; ip netns exec / taskset / bash
  # all exec in place, so $! is the subnetrad PID.
  ip netns exec "$ns" "$@" bash -c "cd '$dir' && exec env SUBNETRA_SOCK='$sock' ./subnetrad" >"$dir/daemon.log" 2>&1 &
  PIDS+=("$!")
}
start_daemon bt_bench_hub "$TMP/hub" "$HUB_SOCK" "${PIN_HUB[@]}";  HUB_PID="${PIDS[-1]}"
start_daemon bt_bench_a   "$TMP/a"   "$A_SOCK"   "${PIN_REST[@]}"
start_daemon bt_bench_b   "$TMP/b"   "$B_SOCK"   "${PIN_REST[@]}"

wait_until() { local d=$(( $1 * 10 )); shift; local i=0; while [ "$i" -lt "$d" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
wait_until 5 ip netns exec bt_bench_hub ip link show snr0 || die "hub snr0 never appeared:\n$(cat "$TMP/hub/daemon.log")"
wait_until 5 ip netns exec bt_bench_a   ip link show snr0 || die "spoke-a snr0 never appeared:\n$(cat "$TMP/a/daemon.log")"
wait_until 5 ip netns exec bt_bench_b   ip link show snr0 || die "spoke-b snr0 never appeared:\n$(cat "$TMP/b/daemon.log")"

# MTU 1400: inner 1400 + 20 hdr + 16 tag + 28 outer < 1500 veth.
ip netns exec bt_bench_hub ip link set snr0 mtu 1400 up
ip netns exec bt_bench_a   ip link set snr0 mtu 1400 up
ip netns exec bt_bench_b   ip link set snr0 mtu 1400 up
ip netns exec bt_bench_hub ip addr add 10.0.0.1/24 dev snr0   # hub terminates pattern 1
ip netns exec bt_bench_a   ip addr add 10.0.0.2/24 dev snr0
ip netns exec bt_bench_b   ip addr add 10.0.0.3/24 dev snr0

subnetra_in() { local ns="$1" sock="$2"; shift 2; ip netns exec "$ns" env SUBNETRA_SOCK="$sock" "$SUBNETRA" "$@"; }
# Hub: deliver-local to itself (10.0.0.1), relay to each spoke.
subnetra_in bt_bench_hub "$HUB_SOCK" policy add --src 0.0.0.0/0 --dst 10.0.0.1/32 --action forward --target 0
subnetra_in bt_bench_hub "$HUB_SOCK" policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2
subnetra_in bt_bench_hub "$HUB_SOCK" policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 3
# Spoke-A: everything non-local egresses over its hub link (target 1).
subnetra_in bt_bench_a   "$A_SOCK" policy add --src 0.0.0.0/0 --dst 10.0.0.1/32 --action forward --target 1
subnetra_in bt_bench_a   "$A_SOCK" policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 1
# Spoke-B accepts relayed traffic addressed to it (10.0.0.3 is local on snr0).

# Prime the path so endpoint learning + first-touch pages settle before measuring.
ip netns exec bt_bench_a "$BLAST" --dst 10.0.0.1:9 --secs 1 >/dev/null 2>&1 || true
ip netns exec bt_bench_a "$BLAST" --dst 10.0.0.3:9 --secs 1 >/dev/null 2>&1 || true
kill -0 "$HUB_PID" 2>/dev/null || die "hub daemon died during warmup:\n$(cat "$TMP/hub/daemon.log")"

# --- measurement helpers --------------------------------------------------------
status_val() { # status_val <line-match> <key>  (hub counters)
  ip netns exec bt_bench_hub env SUBNETRA_SOCK="$HUB_SOCK" "$SUBNETRA" status 2>/dev/null \
    | grep -F "$1" | grep -oE "$2=[0-9]+" | head -n1 | cut -d= -f2
}
cpu_jiffies() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null; }  # utime+stime
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

# Results (set by run_pattern).
P1_PPS=0; P1_GBPS="0.000"; P1_CPU="0.0"
P2_PPS=0; P2_GBPS="0.000"; P2_CPU="0.0"

run_pattern() { # run_pattern <name> <blast-dst> <counter-line> <counter-key>
  local name="$1" dst="$2" cline="$3" ckey="$4"
  local c0 c1 j0 j1 dpkt dj wall pps gbps cpu offer
  c0=$(status_val "$cline" "$ckey"); c0=${c0:-0}
  j0=$(cpu_jiffies "$HUB_PID"); j0=${j0:-0}
  local t0 t1
  t0=$(date +%s.%N)
  offer=$(ip netns exec bt_bench_a "$BLAST" --dst "$dst" --secs "$SECS" --size "$PAYLOAD" 2>&1 | awk '/offered:/{print}')
  t1=$(date +%s.%N)
  c1=$(status_val "$cline" "$ckey"); c1=${c1:-0}
  j1=$(cpu_jiffies "$HUB_PID"); j1=${j1:-0}
  kill -0 "$HUB_PID" 2>/dev/null || die "hub daemon died under load ($name):\n$(cat "$TMP/hub/daemon.log")"

  dpkt=$(( c1 - c0 )); dj=$(( j1 - j0 ))
  wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{ d=b-a; print (d>0?d:1) }')
  pps=$(awk -v p="$dpkt" -v w="$wall" 'BEGIN{ printf "%.0f", p / w }')
  gbps=$(awk -v p="$dpkt" -v i="$INNER" -v w="$wall" 'BEGIN{ printf "%.3f", p * i * 8 / w / 1e9 }')
  cpu=$(awk -v j="$dj" -v w="$wall" -v hz="$CLK_TCK" 'BEGIN{ printf "%.1f", (hz>0? j / hz / w * 100 : 0) }')
  ok "$name: ${pps} pps, ${gbps} Gbps inner @${INNER}B, hub cpu ${cpu}%  [${dpkt} pkts/${wall%.*}s]"
  printf '       offered (generator self-report): %s\n' "${offer:-n/a}"
  case "$name" in
    spoke-hub)       P1_PPS="$pps"; P1_GBPS="$gbps"; P1_CPU="$cpu" ;;
    spoke-hub-spoke) P2_PPS="$pps"; P2_GBPS="$gbps"; P2_CPU="$cpu" ;;
  esac
}

log "pattern 1/2: spoke -> hub  (hub terminates; udp_rx ceiling) ..."
run_pattern spoke-hub       10.0.0.1:9 "udp_rx" "packets"
log "pattern 2/2: spoke -> hub -> spoke  (RELAY; the recvmmsg/sendmmsg target, issue #100) ..."
run_pattern spoke-hub-spoke 10.0.0.3:9 "relay"  "packets"

# --- summary, evidence block, baseline diff -------------------------------------
git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
zig_ver=$(zig version 2>/dev/null || echo unknown)
arch=$(uname -m)
version=$(awk -F'"' '/\.version[[:space:]]*=/{print $2; exit}' build.zig.zon 2>/dev/null || echo unknown)

printf '\n'
log "data-plane benchmark evidence (issue #97):"
evidence=$(cat <<EOF
subnetra_version=${version}
git_commit=${git_commit}
zig_version=${zig_ver}
arch=${arch}
nproc=${NPROC}
hub_pinned=$([ "${#PIN_HUB[@]}" -gt 0 ] && echo yes || echo no)
secs_per_pattern=${SECS}
inner_bytes=${INNER}
spoke_hub_pps=${P1_PPS}
spoke_hub_gbps=${P1_GBPS}
spoke_hub_hub_cpu_pct=${P1_CPU}
relay_pps=${P2_PPS}
relay_gbps=${P2_GBPS}
relay_hub_cpu_pct=${P2_CPU}
EOF
)
printf '%s\n' "$evidence" | sed 's/^/    /'

# Informational baseline diff (NOT a gate — issue #97/#100: baseline is informational
# first; shared CI runners vary, so a regression is surfaced, never enforced here).
if [ -f "$BASELINE" ]; then
  printf '\n'; log "vs baseline ($BASELINE):"
  base_relay=$(awk -F= '/^relay_pps=/{print $2}' "$BASELINE" 2>/dev/null || echo "")
  base_sh=$(awk -F= '/^spoke_hub_pps=/{print $2}' "$BASELINE" 2>/dev/null || echo "")
  cmp_line() { # cmp_line <label> <baseline> <current>
    if [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null; then
      awk -v l="$3" -v b="$2" -v c="$4" 'BEGIN{ printf "    %-16s baseline=%s current=%s  (%+.1f%%)\n", l, b, c, (c-b)/b*100 }'
    else
      printf '    %-16s baseline=%s current=%s\n' "$3" "${2:-n/a}" "$4"
    fi
  }
  cmp_line spoke_hub "$base_sh"    spoke_hub_pps "$P1_PPS"
  cmp_line relay     "$base_relay" relay_pps     "$P2_PPS"
else
  log "no baseline file at $BASELINE — record this run as the baseline if it is representative."
fi

# Surface the evidence in the GitHub Actions job summary when present.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Subnetra data-plane benchmark (issue #97)"
    echo ""
    echo "| pattern | pps | Gbps (inner @${INNER}B) | hub CPU% |"
    echo "|---|---:|---:|---:|"
    echo "| spoke -> hub | ${P1_PPS} | ${P1_GBPS} | ${P1_CPU} |"
    echo "| spoke -> hub -> spoke (relay) | ${P2_PPS} | ${P2_GBPS} | ${P2_CPU} |"
    echo ""
    echo "ReleaseFast, ${SECS}s/pattern, nproc=${NPROC}, commit ${git_commit}. The relay row is"
    echo "the recvmmsg/sendmmsg target (issue #100). Reproducible CI baseline, not a live-overlay"
    echo "measurement (that is deploy/bench-overlay.sh, issue #102)."
    echo ""
    echo '```'
    printf '%s\n' "$evidence"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

ok "data-plane benchmark complete."
