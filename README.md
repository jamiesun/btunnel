# BTunnel

**A pure-Zig, zero-dependency Layer-3 UDP tunnel that ships as a single static binary under 512KB.**

**English** · [简体中文](README.zh-CN.md)

> A virtual Layer-3 adaptive networking tool written in **pure Zig** (pinned to the
> 2026 latest standard library `std.posix`).
> Targets general Linux environments (including lightweight containers such as
> BusyBox / RouterOS Container): zero dependencies, zero dynamic allocation,
> strong stealth.

BTunnel builds a virtual subnet on top of a physical leased line, using a
**hub-and-spoke topology** and forwarding raw IP packets through a private UDP
tunnel. It does **not depend on any third-party network framework**:
the TUN device, encryption, anti-replay, and policy engine are all in-house,
producing a single, fully statically linked binary.

## ✨ Features

- **Zero-dependency single binary**: fully static linking against musl-libc; `ldd`
  reports `not a dynamic executable`; size ≤ 512KB.
- **Layered zero dynamic allocation**: the data plane (reactor / crypto) is strictly
  allocation-free, with buffers locked into resident memory at startup.
- **Single-threaded event-driven reactor**: based on Linux epoll edge-triggered
  (`EPOLLET`), lock-free, with no concurrency contention.
- **Stateless obfuscation**: ChaCha20-Poly1305 full encryption; ciphertext has no
  fixed magic number; authentication failures are silently dropped — physically
  invisible to probing.
- **Transport security**: PSK pre-shared key + per-link directional keys +
  per-restart session epoch (fresh key each daemon lifetime) + 64-bit monotonic
  nonce (never reused) + per-session sliding-window anti-replay.
- **Lock-free RCU hot updates**: the policy tree is replaced wholesale via an atomic
  pointer swap; hot updates are zero-copy and jitter-free.
- **Multi-subnet policy engine**: CIDR longest-prefix matching, with Site-to-Site
  routing support.

## 📦 Project layout

```
build.zig            Dual-binary build (btunnel daemon + ptctl control tool), static musl cross-compile
build.zig.zon        Package manifest
config.example.json  Example config (copy to config.json to use)
src/
  root.zig     Core library, aggregates all modules
  config.zig   Config parsing + sanity check (MTU range / subnet overlap)
  policy.zig   CIDR parsing + longest-prefix match + lock-free RCU ActiveTree
  crypto.zig   ChaCha20-Poly1305 + monotonic nonce + sliding-window anti-replay
  reactor.zig  Packed private wire header + egress dispatch + epoll reactor
  tun.zig      TUN device system driver
  uds.zig      Control-plane Unix domain socket + command tokenizer
  main.zig     btunnel daemon entry point
  ptctl.zig    ptctl control tool entry point
docs/
  btunnel-develop.md  System requirements & architecture design (PRD & Architecture)
```

## 🛠 Build

Requires **Zig 0.16.0** or later.

```bash
# Native build (defaults to ReleaseSmall; pass -Doptimize=Debug for dev builds)
zig build

# Static cross-compile
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-linux-musl

# Run tests
zig build test

# Run the daemon
zig build run
```

Artifacts are placed in `zig-out/bin/`: `btunnel` (daemon) and `ptctl` (control tool).

## 🧪 Local integration testing (dev container)

The syscall-heavy data path (TUN device, epoll reactor, AF_UNIX control socket)
can only run on Linux, so a reproducible Linux container is provided under
[`.devcontainer/`](.devcontainer/). It is a **development/test aid only** — the
shipped artifact is still a single static musl binary with zero third-party
dependencies.

Open the folder in any dev-container-aware editor, or run the preflight harness
headless:

```bash
# Build the Linux toolchain image (Debian-slim + pinned Zig 0.16.0)
docker build -t btunnel-dev -f .devcontainer/Dockerfile .

# Run the integration / preflight harness inside it
docker run --rm --privileged --device=/dev/net/tun \
    -v "$PWD":/workspace btunnel-dev test/integration/run.sh
```

[`test/integration/run.sh`](test/integration/run.sh) builds the binary on the
container's native arch, enforces the static-link and ≤ 512 KB constraints,
smoke-runs the daemon (`btunnel --check`), cross-builds the other musl arch,
runs the unit tests, and then runs the **multi-point + relay end-to-end test**:
a 3-node hub-and-spoke star across network namespaces (one Hub relay + two
Spokes). It asserts end-to-end delivery spoke-A → Hub(relay) → spoke-B, on-wire
encryption (no plaintext marker leaks onto the underlay), and a non-stalling RCU
policy hot-update under load. It needs `--privileged` + `--device=/dev/net/tun`.

## 🚀 Usage

```bash
# v1 mandates a non-zero PSK (iron law #5). Generate one and drop it into config.json:
cp config.example.json config.json
# then set "psk" to 32 random bytes as 64 hex chars, e.g.:
#   openssl rand -hex 32
# Without a valid PSK the daemon refuses to start (config sanity: InvalidPsk).

# Start the daemon (reads config.json from the working directory)
./zig-out/bin/btunnel

# Inject a policy dynamically (hot-updated over the UDS, no restart needed)
./ptctl policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
./ptctl policy show
./ptctl save
```

See [`config.example.json`](config.example.json) for a config example.

## 📊 Development status

Currently the framework, the pure-algorithm layer, and the syscall data path
(TUN, epoll reactor, AF_UNIX control plane, daemon main loop) are implemented
and exercised end-to-end in the dev container.

| Task | Module | Status |
|---|---|---|
| 1 Build config | `build.zig` | ✅ Done (static musl, ReleaseSmall, dual binaries) |
| 2 Config sanity | `config.zig` | ✅ Done (std.json parse + hex PSK + CIDR; boundary fuse) |
| 3 Policy match | `policy.zig` | ✅ Done (CIDR / longest-prefix / RCU) |
| 4 System driver | `tun.zig` | ✅ Done (TUNSETIFF ioctl, non-blocking L3 fd) |
| 5 Crypto pipeline | `crypto.zig` | ✅ Done (AEAD / per-link keys / session epoch / anti-replay) |
| 6 Core reactor | `reactor.zig`, `peer.zig` | ✅ Done (epoll ET loop; multi-peer registry with per-link keys + per-restart session epoch; seal/forward, open/anti-replay, source filter, inner-source binding, hub relay) |
| 7 Control-plane UDS | `uds.zig` | ✅ Done (tokenizer + AF_UNIX datagram listener; atomic RCU policy hot-swap, double-buffered) |
| 8 Control tool | `ptctl.zig` | ✅ Done (UDS delivery; `policy add` fire-and-forget, `policy show`/`save` read the daemon's reply; non-zero exit when the daemon is down) |
| 9 Daemon main loop + e2e | `main.zig`, `test/integration/run.sh` | ✅ Done (wires TUN + UDP + UDS + reactor; live multi-point + relay netns end-to-end test) |

> **Currently verifiable**: `zig build test` is all green (46/46 in the Linux
> dev container; 35 pass + 11 Linux-only skips on a macOS host); produces a
> < 512KB static binary. A Linux dev container
> ([`.devcontainer/`](.devcontainer/)) runs an integration/preflight harness
> ([`test/integration/run.sh`](test/integration/run.sh)) that enforces the
> static-link and size constraints across both musl targets **and runs a live
> multi-point + relay end-to-end tunnel test** (3-node hub-and-spoke star across
> network namespaces): real delivery spoke-A → Hub(relay) → spoke-B, on-wire
> encryption, and RCU policy hot-update under load.

See [`docs/btunnel-develop.md`](docs/btunnel-develop.md) for the detailed
architecture, memory model, and acceptance checklist.

## 📄 License

[MIT](LICENSE) © 2026 jettwang

---

> 🔁 A Chinese mirror of this README lives at [`README.zh-CN.md`](README.zh-CN.md).
> **The two must be kept in sync: when you edit one, update the other in the same change.**
