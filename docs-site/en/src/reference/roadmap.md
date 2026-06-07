# Roadmap

Subnetra deliberately ships a small, finished **v1** and reserves a narrow set of
**v2** interface points. This page describes what is delivered, what is reserved,
and — just as importantly — what will **never** be built.

## v1 — delivered

The shipping data plane is `raw_direct`: a stateless, allocation-free,
handshake-free tunnel with:

- ChaCha20-Poly1305 full encryption with per-link keys + per-restart session epoch,
- 64-bit monotonic nonce + sliding-window anti-replay,
- a CIDR longest-prefix policy engine with lock-free RCU hot updates,
- a single-threaded reactor (Linux `epoll` / macOS `poll(2)`),
- a normative [wire protocol](wire-protocol.md) pinned by known-answer vectors.

See the [development status table](https://github.com/jamiesun/subnetra#-development-status)
for module-by-module progress.

## v2 — reserved interface points only

The PRD reserves two **in-house** egress modes for lossy/long-haul leased lines.
They are **design-only** today — the branches return `error.NotImplemented` and no
code is authorized until the maintainer signs off on the design RFC
([`docs/v2-reliability-rfc.md`](https://github.com/jamiesun/subnetra/blob/main/docs/v2-reliability-rfc.md)):

| Mode | Idea | Inner MTU |
|---|---|---|
| `kcp_arq` | Arena-based selective-repeat ARQ to absorb small, sporadic leased-line loss (no `ikcp.c` — in-house) | 1428 |
| `fec_xor` | Forward error correction (naïve 4:1 XOR is known to be inadequate; the real design must do better) | 1428 |

The reservation points that already exist in the tree:

| Reservation | Where it lives |
|---|---|
| `EgressMode { raw_direct, kcp_arq, fec_xor }` | `src/reactor.zig` (v2 ⇒ `error.NotImplemented`) |
| `mtuFor(mode)` → 1452 / 1428 / 1428 | `src/reactor.zig` |
| `flags` header byte (MUST be `0` in v1, except `KEEPALIVE`) | `src/reactor.zig`, `docs/PROTOCOL.md` |
| `negotiation_version` (per-config) | `src/config.zig` |

Crucially, a v2 mode is selected by **static per-link config**, never by an on-wire
handshake. The `negotiation_version` / `flags` fields exist for *static* mode
selection only.

## Explicit non-goals

These are not "not yet" — they are **never**, because they would break the
[design principles](../concepts/design-principles.md):

- **No on-wire handshake / challenge-response / capability exchange.** The
  per-packet epoch *is* session establishment.
- **No in-daemon health-probe or auto-switching path manager.** The data plane is
  single-path; failover is an **external** decision (see
  [Production Deployment → HA](../operations/deployment.md#8-high-availability)).
- **No in-tunnel scheduler / adaptive rate controller.** Traffic shaping is done at
  the OS layer with `tc`.
- **No third-party dependencies.** Not even for v2 reliability — the ARQ must be
  in-house.
- **No in-daemon DNS resolver.** Endpoints are numeric; a dynamic hub is solved
  operationally (DDNS watcher) on the spoke.

Changing any non-goal is an **RFC that amends the iron laws**, not a feature PR —
and is intentionally not on the backlog.

## The keepalive exception (already in v1)

The only addition under `wire_version = 1` is the one-way, never-acknowledged
spoke→hub NAT keepalive (`flags` bit 0). It is backward-compatible and is **not** a
handshake — see the [Security Model](../concepts/security-model.md#nat-keepalive-one-way-never-acknowledged).
