# BTunnel

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
  reports `not a dynamic executable`; size ≤ 200KB.
- **Layered zero dynamic allocation**: the data plane (reactor / crypto) is strictly
  allocation-free, with buffers locked into resident memory at startup.
- **Single-threaded event-driven reactor**: based on Linux epoll edge-triggered
  (`EPOLLET`), lock-free, with no concurrency contention.
- **Stateless obfuscation**: ChaCha20-Poly1305 full encryption; ciphertext has no
  fixed magic number; authentication failures are silently dropped — physically
  invisible to probing.
- **Transport security**: PSK pre-shared key + 64-bit monotonic nonce (never
  reused) + sliding-window anti-replay.
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
# Native build (defaults to ReleaseSmall)
zig build --release=small

# Static cross-compile
zig build --release=small -Dtarget=x86_64-linux-musl
zig build --release=small -Dtarget=aarch64-linux-musl

# Run tests
zig build test

# Run the daemon
zig build run
```

Artifacts are placed in `zig-out/bin/`: `btunnel` (daemon) and `ptctl` (control tool).

## 🚀 Usage

```bash
# Start the daemon (reads config.json, falls back to the compile-time default if missing)
./zig-out/bin/btunnel

# Inject a policy dynamically (hot-updated over the UDS, no restart needed)
./ptctl policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
./ptctl policy show
./ptctl save
```

See [`config.example.json`](config.example.json) for a config example.

## 📊 Development status

Currently at the scaffold stage: the framework and pure-algorithm layer are
implemented and passing tests; the syscall-heavy parts are placeholders.

| Task | Module | Status |
|---|---|---|
| 1 Build config | `build.zig` | ✅ Done (static musl, ReleaseSmall, dual binaries) |
| 2 Config sanity | `config.zig` | 🟡 Partial (boundary checks done; JSON parsing stubbed) |
| 3 Policy match | `policy.zig` | ✅ Done (CIDR / longest-prefix / RCU) |
| 4 System driver | `tun.zig` | 🔴 Stub (TUNSETIFF ioctl pending) |
| 5 Crypto pipeline | `crypto.zig` | ✅ Done (AEAD / nonce / anti-replay) |
| 6 Core reactor | `reactor.zig` | 🟡 Partial (header + egress done; epoll loop stubbed) |
| 7 Control-plane UDS | `uds.zig` | 🟡 Partial (tokenizer done; socket listener stubbed) |
| 8 Control tool | `ptctl.zig` | 🟡 Partial (argument validation done; UDS delivery pending) |

> **Currently verifiable**: `zig build test` is all green (16/16); produces a
> < 200KB static binary.
> **End-to-end networking** still pending: TUN ioctl (Task 4), epoll send/recv loop
> (Task 6), UDS communication (Tasks 7/8).

See [`docs/btunnel-develop.md`](docs/btunnel-develop.md) for the detailed
architecture, memory model, and acceptance checklist.

## 📄 License

[MIT](LICENSE) © 2026 jettwang

---

> 🔁 A Chinese mirror of this README lives at [`README.zh-CN.md`](README.zh-CN.md).
> **The two must be kept in sync: when you edit one, update the other in the same change.**
