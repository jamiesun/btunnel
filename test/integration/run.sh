#!/usr/bin/env bash
#
# BTunnel local integration / preflight harness.
#
# Runs INSIDE the Linux dev container (see .devcontainer/). It is the automated
# guardian of BTunnel's hard release constraints and the staging ground for the
# end-to-end tunnel test.
#
# What it does TODAY (all of this is real and must pass):
#   1. Build the static musl binary on the container's NATIVE arch.
#   2. Enforce iron law #6: fully static (no ELF INTERP) and binary <= 512 KB.
#   3. Smoke-run the daemon config sanity path (`btunnel --check`).
#   4. Cross-compile the OTHER musl arch and re-check static + size (build-only;
#      it is not executed, to avoid qemu-user emulation skewing results).
#   5. Run the unit test suite (`zig build test`).
#   6. The multi-point + relay tunnel test: a 3-node hub-and-spoke star across
#      network namespaces (one Hub relay + two Spokes). It asserts end-to-end
#      delivery spoke-A -> Hub(relay) -> spoke-B, on-wire encryption (no
#      plaintext marker on the underlay), and a non-stalling RCU policy
#      hot-update under load. Requires --privileged + /dev/net/tun + tcpdump.
#
# Usage (from repo root, on the host):
#   docker build -t btunnel-dev -f .devcontainer/Dockerfile .
#   docker run --rm --privileged --device=/dev/net/tun -v "$PWD":/workspace \
#       btunnel-dev test/integration/run.sh
set -euo pipefail

readonly SIZE_BUDGET=524288   # 512 KiB, iron law #6
PASS=0
SKIP=0

log()  { printf '\033[1;34m[ii]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
skip() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; SKIP=$((SKIP + 1)); }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspace)"

# --- arch matrix -----------------------------------------------------------
# NATIVE target runs; FOREIGN target is cross-build-only.
case "$(uname -m)" in
  x86_64|amd64)  NATIVE_TARGET=x86_64-linux-musl;  FOREIGN_TARGET=aarch64-linux-musl ;;
  aarch64|arm64) NATIVE_TARGET=aarch64-linux-musl; FOREIGN_TARGET=x86_64-linux-musl  ;;
  *) die "unsupported host arch: $(uname -m)" ;;
esac
log "native target: $NATIVE_TARGET   foreign target: $FOREIGN_TARGET"
log "zig: $(zig version)"

# --- helpers ---------------------------------------------------------------
assert_static() {
  # No PT_INTERP program header == statically linked, on any architecture.
  # (ldd is unreliable for foreign-arch binaries, so we read the ELF directly.)
  local bin="$1"
  if readelf -l "$bin" 2>/dev/null | grep -q INTERP; then
    die "$bin is dynamically linked (found PT_INTERP) — violates iron law #6"
  fi
}

assert_size() {
  local bin="$1" size
  size=$(stat -c %s "$bin")
  if [ "$size" -gt "$SIZE_BUDGET" ]; then
    die "$bin is ${size} bytes (> ${SIZE_BUDGET} budget) — violates iron law #6"
  fi
  printf '%s' "$size"
}

build_target() {
  local target="$1"
  rm -rf zig-out
  zig build -Dtarget="$target" >/dev/null
  [ -x zig-out/bin/btunnel ] || die "build for $target produced no btunnel binary"
}

# --- 1+2+3: native build, constraints, smoke run ---------------------------
log "building native ($NATIVE_TARGET) ReleaseSmall ..."
build_target "$NATIVE_TARGET"
assert_static zig-out/bin/btunnel
nsize=$(assert_size zig-out/bin/btunnel)
ok "native binary is static and ${nsize} bytes (<= ${SIZE_BUDGET})"

log "smoke-running the daemon ..."
# v1 mandates a non-zero PSK (iron law #5): the all-zero default is
# non-runnable, so the smoke run provisions a throwaway PSK via config.json.
smoke_dir=$(mktemp -d)
cp zig-out/bin/btunnel "$smoke_dir/btunnel"
printf '{ "psk": "%s" }' \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  > "$smoke_dir/config.json"
if ! out=$(cd "$smoke_dir" && ./btunnel --check 2>&1); then
  rm -rf "$smoke_dir"
  die "daemon exited non-zero:\n$out"
fi
rm -rf "$smoke_dir"
grep -q "btunnel v" <<<"$out" || die "unexpected daemon output:\n$out"
ok "daemon smoke run: $(head -n1 <<<"$out")"

# --- 4: foreign cross-build (build-only) -----------------------------------
log "cross-building foreign ($FOREIGN_TARGET) ReleaseSmall ..."
build_target "$FOREIGN_TARGET"
assert_static zig-out/bin/btunnel
fsize=$(assert_size zig-out/bin/btunnel)
ok "foreign binary is static and ${fsize} bytes (<= ${SIZE_BUDGET})"

# --- 5: unit tests ---------------------------------------------------------
log "running unit tests (zig build test) ..."
zig build test >/dev/null || die "zig build test failed"
ok "unit tests green"

# --- 6: end-to-end netns tunnel test ---------------------------------------
# A 3-node hub-and-spoke star in separate network namespaces — one Hub (relay)
# and two Spokes — exercising BOTH capabilities the PRD calls for:
#   * multi-point: every spoke reaches the Hub over its own encrypted UDP
#     tunnel and joins the virtual 10.0.0.0/24 overlay;
#   * relay: a packet from spoke-A destined for spoke-B is forwarded (relayed)
#     by the Hub per `policy ... --action forward --target <B>` rules — spokes
#     never talk directly and share no key.
#
# Topology (underlay /24s are point-to-point veth pairs):
#   bt_a  10.100.1.2 <--veth--> 10.100.1.1  bt_hub  10.100.2.1 <--veth--> 10.100.2.2  bt_b
#   overlay btun0:  a = 10.0.0.2/24   hub = (relay, no overlay IP)   b = 10.0.0.3/24
#
# Mesh ids: hub=1, a=2, b=3. Routing/key trace:
#   a->b: a seals derive(psk,2,1) -> hub; hub rx derive(psk,2,1), relays
#         derive(psk,1,3) -> b; b rx derive(psk,1,3) -> LOCAL. Reply mirrors.
#
# Policy match is destination-only in v1 (PolicyEntry.src is parsed but unused),
# so every rule uses --src 0.0.0.0/0; the Hub's per-spoke /32 allowed_src in the
# config is what actually exercises inner-source binding.
#
# Assertions:
#   1. Delivery: bt_a ping 10.0.0.3 (spoke-B) succeeds via the Hub relay.
#   2. Encryption: a plaintext marker in the ICMP payload is ABSENT from the
#      underlay UDP capture but PRESENT on spoke-B's decrypted btun0 (positive
#      control), proving the tunnel is the only thing carrying it.
#   3. Hot-update: an RCU `ptctl policy add` injected mid-stream does not stall
#      a backgrounded ping (anti-replay drops are covered by unit tests).

PSK="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
E2E_NS=(bt_hub bt_a bt_b)
declare -a E2E_PIDS=()
E2E_TMP=""

e2e_cleanup() {
  set +e
  for p in "${E2E_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" >/dev/null 2>&1
  done
  # Let the daemons/tcpdump actually exit before deleting their namespaces,
  # otherwise `ip netns del` can fail and leak the namespace.
  for p in "${E2E_PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  for ns in "${E2E_NS[@]}"; do
    ip netns del "$ns" >/dev/null 2>&1
  done
  [ -n "$E2E_TMP" ] && rm -rf "$E2E_TMP"
}

# wait_until <timeout_s> <cmd...> : poll cmd at 10 Hz until it succeeds.
wait_until() {
  local deadline=$(( $1 * 10 )); shift
  local i=0
  while [ "$i" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

policy_has() { # policy_has <ns> <sock> <needle>
  ip netns exec "$1" env BTUNNEL_SOCK="$2" "$PTCTL" policy show 2>/dev/null | grep -qF "$3"
}

ptctl_in() { # ptctl_in <ns> <sock> <args...>
  local ns="$1" sock="$2"; shift 2
  ip netns exec "$ns" env BTUNNEL_SOCK="$sock" "$PTCTL" "$@"
}

write_config() { # write_config <dir> <local_id> <peers-json>
  cat > "$1/config.json" <<EOF
{ "psk": "$PSK", "local_id": $2, "peers": $3 }
EOF
}

start_daemon() { # start_daemon <ns> <dir> <sock> -> records PID
  ip netns exec "$1" bash -c "cd '$2' && exec env BTUNNEL_SOCK='$3' ./btunnel" \
    >"$2/daemon.log" 2>&1 &
  E2E_PIDS+=("$!")
}

e2e_netns() {
  # Pre-flight: the privileged netns e2e needs real CAP_NET_ADMIN + tooling.
  # Missing pieces SKIP (never fake); a misconfigured run still fails loudly.
  if [ "$(id -u)" -ne 0 ]; then
    skip "multi-point + relay e2e: not running as root (need CAP_NET_ADMIN)"
    return 0
  fi
  for tool in ip tcpdump ping; do
    command -v "$tool" >/dev/null 2>&1 || { skip "multi-point + relay e2e: '$tool' not available"; return 0; }
  done
  if [ ! -c /dev/net/tun ]; then
    skip "multi-point + relay e2e: /dev/net/tun missing (run with --device=/dev/net/tun)"
    return 0
  fi

  log "multi-point + relay e2e: building native daemon + ptctl ..."
  # Step 4 left a FOREIGN-arch binary in zig-out; rebuild NATIVE before running.
  build_target "$NATIVE_TARGET"
  PTCTL="$PWD/zig-out/bin/ptctl"
  [ -x "$PTCTL" ] || die "native build produced no ptctl binary"

  trap e2e_cleanup EXIT
  # Clean any leftovers from an aborted previous run before (re)creating.
  for ns in "${E2E_NS[@]}"; do ip netns del "$ns" >/dev/null 2>&1 || true; done
  E2E_TMP=$(mktemp -d)
  mkdir -p "$E2E_TMP/hub" "$E2E_TMP/a" "$E2E_TMP/b"
  for d in hub a b; do cp zig-out/bin/btunnel "$E2E_TMP/$d/btunnel"; done

  # --- namespaces + underlay veth pairs ---
  for ns in "${E2E_NS[@]}"; do ip netns add "$ns"; done
  ip link add veth_ha type veth peer name veth_ah
  ip link set veth_ha netns bt_hub
  ip link set veth_ah netns bt_a
  ip link add veth_hb type veth peer name veth_bh
  ip link set veth_hb netns bt_hub
  ip link set veth_bh netns bt_b

  ip netns exec bt_hub ip addr add 10.100.1.1/24 dev veth_ha
  ip netns exec bt_hub ip addr add 10.100.2.1/24 dev veth_hb
  ip netns exec bt_a   ip addr add 10.100.1.2/24 dev veth_ah
  ip netns exec bt_b   ip addr add 10.100.2.2/24 dev veth_bh
  ip netns exec bt_hub ip link set veth_ha up
  ip netns exec bt_hub ip link set veth_hb up
  ip netns exec bt_a   ip link set veth_ah up
  ip netns exec bt_b   ip link set veth_bh up
  for ns in "${E2E_NS[@]}"; do ip netns exec "$ns" ip link set lo up; done

  # --- per-node config (endpoints are the directly-connected veth addresses) ---
  write_config "$E2E_TMP/hub" 1 \
    '[ {"id":2,"endpoint":"10.100.1.2:51820","allowed_src":"10.0.0.2/32"},
       {"id":3,"endpoint":"10.100.2.2:51820","allowed_src":"10.0.0.3/32"} ]'
  write_config "$E2E_TMP/a" 2 \
    '[ {"id":1,"endpoint":"10.100.1.1:51820","allowed_src":"10.0.0.0/24"} ]'
  write_config "$E2E_TMP/b" 3 \
    '[ {"id":1,"endpoint":"10.100.2.1:51820","allowed_src":"10.0.0.0/24"} ]'

  local hub_sock="$E2E_TMP/hub.sock" a_sock="$E2E_TMP/a.sock" b_sock="$E2E_TMP/b.sock"
  start_daemon bt_hub "$E2E_TMP/hub" "$hub_sock"
  start_daemon bt_a   "$E2E_TMP/a"   "$a_sock"
  start_daemon bt_b   "$E2E_TMP/b"   "$b_sock"

  # --- wait for each daemon to create btun0, then bring up the overlay ---
  wait_until 5 ip netns exec bt_hub ip link show btun0 || die "hub btun0 never appeared:\n$(cat "$E2E_TMP/hub/daemon.log")"
  wait_until 5 ip netns exec bt_a   ip link show btun0 || die "spoke-a btun0 never appeared:\n$(cat "$E2E_TMP/a/daemon.log")"
  wait_until 5 ip netns exec bt_b   ip link show btun0 || die "spoke-b btun0 never appeared:\n$(cat "$E2E_TMP/b/daemon.log")"

  # MTU 1400: inner 1452 + hdr 12 + tag 16 + outer 28 would exceed the 1500 veth.
  ip netns exec bt_hub ip link set btun0 mtu 1400 up
  ip netns exec bt_a   ip link set btun0 mtu 1400 up
  ip netns exec bt_b   ip link set btun0 mtu 1400 up
  ip netns exec bt_a   ip addr add 10.0.0.2/24 dev btun0
  ip netns exec bt_b   ip addr add 10.0.0.3/24 dev btun0

  # --- inject routing policy (destination-only match; LOCAL target = 0) ---
  # ptctl must run INSIDE the daemon's netns: the client's reply socket is an
  # abstract AF_UNIX address, and that namespace is per-netns.
  ptctl_in bt_hub "$hub_sock" policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2
  ptctl_in bt_hub "$hub_sock" policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 3
  ptctl_in bt_a   "$a_sock"   policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 1
  ptctl_in bt_a   "$a_sock"   policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0
  ptctl_in bt_b   "$b_sock"   policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 1
  ptctl_in bt_b   "$b_sock"   policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 0

  # `policy add` is fire-and-forget: poll `policy show` (a full reactor
  # round-trip) until the rules land — this also proves each UDS is bound and
  # the reactor is servicing the control plane.
  wait_until 5 policy_has bt_hub "$hub_sock" "10.0.0.3/32" || die "hub policy never applied (reactor not servicing control?)"
  wait_until 5 policy_has bt_a   "$a_sock"   "10.0.0.3/32" || die "spoke-a policy never applied"
  wait_until 5 policy_has bt_b   "$b_sock"   "10.0.0.2/32" || die "spoke-b policy never applied"

  # --- assertion 1: end-to-end delivery via the Hub relay ---
  if ip netns exec bt_a ping -c3 -W2 10.0.0.3 >/dev/null 2>&1; then
    ok "e2e delivery: spoke-A -> Hub(relay) -> spoke-B (ping 10.0.0.3)"
  else
    die "spoke-A could not reach spoke-B through the Hub relay\nhub:$(cat "$E2E_TMP/hub/daemon.log")\na:$(cat "$E2E_TMP/a/daemon.log")\nb:$(cat "$E2E_TMP/b/daemon.log")"
  fi

  # --- assertion 2: on-wire encryption (no plaintext marker on the underlay) ---
  # Marker 0x4c45414b4d524b21 == ASCII "LEAKMRK!"; it rides in the ICMP payload.
  local under_pcap="$E2E_TMP/under.pcap" over_pcap="$E2E_TMP/over.pcap"
  ip netns exec bt_a tcpdump -i veth_ah -s0 -U -w "$under_pcap" udp port 51820 >/dev/null 2>&1 &
  E2E_PIDS+=("$!"); local td_under=$!
  ip netns exec bt_b tcpdump -i btun0 -s0 -U -w "$over_pcap" icmp >/dev/null 2>&1 &
  E2E_PIDS+=("$!"); local td_over=$!
  sleep 0.5  # let both captures attach before generating traffic
  ip netns exec bt_a ping -c5 -W2 -p 4c45414b4d524b21 10.0.0.3 >/dev/null 2>&1 || true
  sleep 0.3
  kill "$td_under" "$td_over" >/dev/null 2>&1 || true
  wait "$td_under" "$td_over" 2>/dev/null || true
  # Guard against a false green: if the underlay capture is empty (tcpdump never
  # attached, wrong iface, ...), "marker absent" would be trivially true.
  local under_pkts
  under_pkts=$(tcpdump -r "$under_pcap" 2>/dev/null | grep -c . || true)
  if [ "${under_pkts:-0}" -lt 1 ]; then
    die "underlay capture is empty — cannot prove encryption (tcpdump attach failed?)"
  fi
  if grep -aq "LEAKMRK" "$under_pcap"; then
    die "plaintext marker leaked onto the underlay — traffic is NOT encrypted"
  fi
  if ! grep -aq "LEAKMRK" "$over_pcap"; then
    die "positive control failed: marker never reached spoke-B's decrypted btun0"
  fi
  ok "on-wire encryption: ${under_pkts} tunnel pkt(s) on underlay, marker absent there, present on decrypted overlay"

  # --- assertion 3: RCU policy hot-update does not stall in-flight traffic ---
  local ping_log="$E2E_TMP/hotping.log"
  ip netns exec bt_a ping -i0.2 -c20 -W1 10.0.0.3 >"$ping_log" 2>&1 &
  local hot_ping=$!
  sleep 1
  # The injection must succeed AND visibly land (proves the control plane really
  # processed a hot-update), not merely "ping kept flowing regardless".
  ptctl_in bt_hub "$hub_sock" policy add --src 0.0.0.0/0 --dst 10.50.0.0/16 --action drop
  wait_until 5 policy_has bt_hub "$hub_sock" "10.50.0.0/16" || die "mid-stream policy hot-update never applied"
  wait "$hot_ping" 2>/dev/null || true
  local recv
  recv=$(grep -oE '[0-9]+ (packets )?received' "$ping_log" | grep -oE '^[0-9]+' | head -n1 || true)
  if [ "${recv:-0}" -ge 18 ]; then
    ok "RCU hot-update: ${recv}/20 pings delivered while injecting a rule mid-stream"
  else
    die "policy hot-update stalled the data plane (${recv:-0}/20 received)\n$(cat "$ping_log")"
  fi
}
e2e_netns

# --- summary ---------------------------------------------------------------
printf '\n'
log "integration summary: ${PASS} passed, ${SKIP} skipped"
