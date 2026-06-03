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
#   2. Enforce iron law #6: fully static (no ELF INTERP) and binary <= 200 KB.
#   3. Smoke-run the daemon (config sanity path).
#   4. Cross-compile the OTHER musl arch and re-check static + size (build-only;
#      it is not executed, to avoid qemu-user emulation skewing results).
#   5. Run the unit test suite (`zig build test`).
#
# What it does NOT do yet:
#   6. The multi-point + relay tunnel test (hub-and-spoke star across network
#      namespaces: Hub relays spoke-A -> spoke-B). The data path (tun/reactor/
#      uds) is still stubbed (Tasks 4/6/7), so this step is SKIPPED — never
#      faked. An anti-forgetting guard (see e2e_netns) FAILS the run if the
#      stubs are removed but this test is still skipped, so the harness can
#      never silently rot into decoration.
#
# Usage (from repo root, on the host):
#   docker build -t btunnel-dev -f .devcontainer/Dockerfile .
#   docker run --rm --privileged --device=/dev/net/tun -v "$PWD":/workspace \
#       btunnel-dev test/integration/run.sh
set -euo pipefail

readonly SIZE_BUDGET=204800   # 200 KiB, iron law #6
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
if ! out=$(cd "$smoke_dir" && ./btunnel 2>&1); then
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

# --- 6: end-to-end netns tunnel test (gated) -------------------------------
# Target topology once the data path lands: a 3+ node hub-and-spoke star in
# separate network namespaces — one Hub (relay) and >=2 Spokes — exercising
# BOTH capabilities the PRD calls for:
#   * multi-point: every spoke reaches the Hub over its own encrypted UDP
#     tunnel and joins the virtual 10.0.0.0/24 subnet;
#   * relay: a packet from spoke-A destined for spoke-B's subnet is forwarded
#     (relayed) by the Hub per a `policy ... --action forward --target <B>`
#     rule — spokes never talk directly.
# Assertions: end-to-end delivery A->Hub->B, ciphertext carries no plaintext /
# magic on the wire, replayed datagrams are dropped by the sliding window, and
# an RCU `ptctl policy add` hot-update does not stall in-flight traffic.
data_path_stubbed() {
  # Stub sentinels per module; while ANY remains, the e2e path can't run.
  grep -q "the real TUNSETIFF ioctl lands in Task 4" src/tun.zig && return 0  # Task 4
  grep -q "skeleton pending" src/reactor.zig && return 0                      # Task 6
  grep -q "TODO(Task 7)" src/uds.zig && return 0                              # Task 7
  return 1
}

e2e_netns() {
  if data_path_stubbed; then
    skip "multi-point + relay e2e: data path still stubbed (Tasks 4/6/7) — reactor moves no packets yet"
    return 0
  fi
  # Anti-forgetting guard: stubs are gone but no real e2e is wired here.
  die "data path is no longer stubbed but the hub-and-spoke e2e test is unimplemented.
     -> Implement the multi-point + relay test in e2e_netns(): create a Hub and
        >=2 Spoke network namespaces, run btunnel in each, and assert
        spoke-A -> Hub(relay) -> spoke-B delivery, on-wire encryption (no
        plaintext/magic), anti-replay drops, and RCU policy hot-update under load."
}
e2e_netns

# --- summary ---------------------------------------------------------------
printf '\n'
log "integration summary: ${PASS} passed, ${SKIP} skipped"
