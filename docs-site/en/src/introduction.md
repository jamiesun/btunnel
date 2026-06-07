# Introduction

**Subnetra** is a pure-[Zig](https://ziglang.org/), zero-dependency **Layer-3 UDP
tunnel** that ships as a single, fully static binary under **512 KB**.

It builds a virtual subnet on top of a physical leased line using a
**hub-and-spoke topology**, forwarding raw IP packets through a private,
fully-encrypted UDP tunnel. It does **not depend on any third-party network
framework** — the TUN device, encryption, anti-replay, and policy engine are all
in-house.

Subnetra targets **general Linux environments**, including extremely constrained
containers (BusyBox / RouterOS Container), and runs natively on **macOS as a
spoke** (`utun` + `poll(2)`): zero dependencies, zero dynamic allocation in the
data plane, and strong stealth.

> This documentation site is bilingual. Use the **中文 / EN** toggle in the top
> bar to switch languages, or read the [简体中文文档](https://jamiesun.github.io/subnetra/zh/).

## Why Subnetra?

| If you need… | Subnetra gives you… |
|---|---|
| To run a tunnel inside a RouterOS / BusyBox container | One static musl binary, ≤ 512 KB, no shared libraries |
| Predictable latency on a leased line | A single-threaded, allocation-free data plane with zero GC/jitter |
| Stealth against active probing | ChaCha20-Poly1305 full encryption, no magic bytes, silent drop on failure |
| Site-to-site routing between branches | A CIDR longest-prefix policy engine, hot-swapped via RCU with no restart |
| Reproducible, auditable behavior | A normative [wire protocol spec](reference/wire-protocol.md) with known-answer test vectors |

## Features at a glance

- **Zero-dependency single binary** — fully static linking against musl-libc;
  `ldd` reports `not a dynamic executable`; size ≤ 512 KB.
- **Layered zero dynamic allocation** — the data plane (reactor / crypto) is
  strictly allocation-free, with buffers locked into resident memory at startup.
- **Single-threaded event-driven reactor** — Linux `epoll` edge-triggered
  (`EPOLLET`) or macOS `poll(2)`, selected at comptime; lock-free, with no
  concurrency contention.
- **Stateless obfuscation** — ChaCha20-Poly1305 full encryption; ciphertext has
  no fixed magic number; authentication failures are silently dropped — physically
  invisible to probing.
- **Transport security** — private per-peer pre-shared keys (one secret per hub
  link, never mesh-wide) + per-link directional keys + per-restart session epoch +
  64-bit monotonic nonce (never reused) + per-session sliding-window anti-replay.
- **Lock-free RCU hot updates** — the policy tree is replaced wholesale via an
  atomic pointer swap; hot updates are zero-copy and jitter-free.
- **Multi-subnet policy engine** — CIDR longest-prefix matching, with
  Site-to-Site routing support.

## The data path in five steps

1. **TUN ingress** — read raw IPv4 packets from the virtual L3 device.
2. **Encrypt & seal** — ChaCha20-Poly1305 over a 20-byte private header; silent
   drop on failure.
3. **Star relay** — the hub relays by policy to each spoke, and never back to the
   source.
4. **Policy routing** — longest-prefix CIDR match, hot-swapped via RCU without a
   restart.
5. **Spoke egress** — verify epoch, nonce, anti-replay and inner source, then
   deliver.

## How to read these docs

- New here? Start with **[Installation](getting-started/installation.md)** and the
  **[Quick Start](getting-started/quickstart.md)**.
- Want to understand the design? Read **[Architecture](concepts/architecture.md)**
  and the **[Security Model](concepts/security-model.md)**.
- Setting up a config? See the **[Configuration Reference](configuration/reference.md)**
  and **[Roles](configuration/roles.md)**.
- Going to production? Follow **[Production Deployment](operations/deployment.md)**.
- Building another implementation? The **[Wire Protocol](reference/wire-protocol.md)**
  is the normative contract.

## Project status

The framework, the pure-algorithm layer, and the syscall data path (TUN, the
readiness reactor, AF_UNIX control plane, daemon main loop) are implemented and
exercised end-to-end in the dev container, with a native macOS `utun`/`poll(2)`
spoke behind the comptime `src/os/` backend. v1 (`raw_direct` + PSK + anti-replay
+ RCU policy) is the deliverable; v2 reliability modes (`kcp_arq`, `fec_xor`) are
reserved interface points only — see the **[Roadmap](reference/roadmap.md)**.

## License

[MIT](https://github.com/jamiesun/subnetra/blob/main/LICENSE) © 2026 jettwang.
