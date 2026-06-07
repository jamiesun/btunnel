# Development

Subnetra is written in **pure Zig** with **zero third-party dependencies** —
only the standard library and raw syscalls via `std.posix`. This page covers
building, testing, and the local integration harness.

## Prerequisites

- **Zig 0.16.0** or later.
- For the privileged integration harness: a Linux host (or the provided dev
  container) with `/dev/net/tun` and `--privileged`.

## Build & test

```bash
# Native build (ReleaseSmall by default; -Doptimize=Debug for dev)
zig build

# Static cross-compile to each shipped target
zig build -Dtarget=x86_64-linux-musl     # amd64
zig build -Dtarget=aarch64-linux-musl    # arm64
zig build -Dtarget=arm-linux-musleabihf  # armv7 (hard float)
zig build -Dtarget=arm-linux-musleabi    # armv5 (soft float)

# Unit tests (must stay green before any commit)
zig build test

# Run the daemon
zig build run
```

Artifacts land in `zig-out/bin/`: `subnetrad` and `subnetra`.

### Useful build steps

| Step | What it does |
|---|---|
| `zig build test` | Run the unit tests |
| `zig build vectors` | Print the wire-protocol conformance vectors (JSON) to stdout |
| `zig build tools-test` | Run unit tests for the `tools/` utilities |
| `zig build tool:keygen` | Build/run the per-link PSK generator |
| `zig build tool:config-lint` | Build/run the offline config validator |
| `zig build tool:wire-decode` | Build/run the offline datagram inspector |

## Project layout

| Path | Purpose |
|---|---|
| `build.zig`, `build.zig.zon` | Dual-binary build (daemon + control tool), static musl cross-compile; version single-sourced in `.version` |
| `src/config.zig` | Config parse + sanity checks |
| `src/policy.zig` | CIDR longest-prefix match + lock-free RCU `ActiveTree` |
| `src/crypto.zig` | ChaCha20-Poly1305, monotonic nonce, anti-replay |
| `src/reactor.zig` | Wire header, egress dispatch, readiness reactor |
| `src/peer.zig` | Per-peer endpoint + crypto registry |
| `src/os/` | Comptime OS backend: `linux.zig` (epoll + `/dev/net/tun`), `darwin.zig` (`poll(2)` + `utun`), `mod.zig` (selector) |
| `src/uds.zig` | Control socket + command tokenizer |
| `src/stats.zig` | Data-plane counters |
| `src/netplan.zig` | `--print-network-plan` emitter |
| `src/main.zig`, `src/subnetra.zig` | Daemon / control-tool entry points |
| `tools/` | Out-of-tree helpers (never shipped in the daemon) |
| `docs/` | Design docs, the normative protocol, deployment, and RFCs |

## Test-driven workflow

Pure logic ships with tests. The PRD's acceptance tests include JSON/sanity
checks, CIDR overlap/matching, RCU hot-swap safety, crypto invariance (ciphertext
grows by exactly the 16-byte tag), and nonce-monotonic / anti-replay behavior. The
wire protocol is pinned by **known-answer vectors** generated from the live code
(`zig build vectors`) with a drift sentinel in `zig build test`.

## Local integration testing (dev container)

The privileged hub-and-spoke harness is Linux-only, so a reproducible Linux
container is provided under
[`.devcontainer/`](https://github.com/jamiesun/subnetra/tree/main/.devcontainer).
It is a development/test aid only — the shipped artifact stays a single static musl
binary.

```bash
# Build the Linux toolchain image (Debian-slim + pinned Zig 0.16.0)
docker build -t subnetra-dev -f .devcontainer/Dockerfile .

# Run the integration / preflight harness
docker run --rm --privileged --device=/dev/net/tun \
    -v "$PWD":/workspace subnetra-dev test/integration/run.sh
```

[`test/integration/run.sh`](https://github.com/jamiesun/subnetra/blob/main/test/integration/run.sh)
builds the binary, enforces the static-link and ≤ 512 KB constraints, smoke-runs
the daemon, cross-builds the other musl arch, runs the unit tests, then runs a
**3-node hub-and-spoke end-to-end test** across network namespaces: real delivery
spoke-A → Hub(relay) → spoke-B, on-wire encryption (no plaintext leak onto the
underlay), a non-stalling RCU policy hot-update under load, honest drop counters,
resilience under underlay loss (netem) with full recovery, and endpoint roaming /
NAT remap.

For a throughput/PPS baseline, the sibling
[`test/integration/bench.sh`](https://github.com/jamiesun/subnetra/blob/main/test/integration/bench.sh)
stands up the same star, builds `-Doptimize=ReleaseFast` (measurement only), and
reads achieved pps / Gbps / hub-CPU% from each daemon's own counters.

## Contributing principles

Subnetra is governed by a strict operating contract
([`AGENT.md`](https://github.com/jamiesun/subnetra/blob/main/AGENT.md)). In short:
make surgical, goal-aligned changes; keep `zig build test` green; preserve the
zero-dependency, single-threaded, allocation-free (data-plane), handshake-free
invariants; and verify the binary still links statically and stays under the size
budget before declaring a task done. See the
[Design Principles](../concepts/design-principles.md).
