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
#   6. The two-node TUN + network-namespace tunnel test. The data path
#      (tun/reactor/uds) is still stubbed (Tasks 4/6/7), so this step is SKIPPED
#      — never faked. An anti-forgetting guard (see e2e_netns) FAILS the run if
#      the stubs are removed but this test is still skipped, so the harness can
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
out=$(zig-out/bin/btunnel 2>&1) || die "daemon exited non-zero:\n$out"
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
data_path_stubbed() {
  # Stable sentinels that vanish once Tasks 4/6 implement the data path.
  grep -q "the real TUNSETIFF ioctl lands in Task 4" src/tun.zig &&
    grep -q "skeleton pending" src/reactor.zig
}

e2e_netns() {
  if data_path_stubbed; then
    skip "e2e tunnel test: data path still stubbed (Tasks 4/6/7) — nothing to exercise yet"
    return 0
  fi
  # Anti-forgetting guard: stubs are gone but no real e2e is wired here.
  die "data path is no longer stubbed but the netns e2e test is unimplemented.
     -> Implement the two-node TUN + 'ip netns' tunnel test in e2e_netns()
        (create two namespaces, run btunnel in each, push IP packets through
        the TUN devices, assert delivery + encryption + anti-replay)."
}
e2e_netns

# --- summary ---------------------------------------------------------------
printf '\n'
log "integration summary: ${PASS} passed, ${SKIP} skipped"
