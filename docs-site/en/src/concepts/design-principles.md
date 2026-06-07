# Design Principles

Subnetra is built around a small set of **non-negotiable constraints**. They are
not aspirational — they are binding invariants that shape every module. If a
change conflicts with one of these, the change is wrong. (Internally these are the
project's "iron laws".)

## 1. Zero third-party dependencies

No WireGuard, no `ikcp.c`, no network frameworks, no external crypto libraries.
Only Zig's standard library and raw syscalls via `std.posix`. Even the future v2
reliability layer must be in-house (an arena-based ARQ), never a vendored C
library. The payoff is a single auditable artifact with no supply chain.

## 2. Layered zero dynamic allocation

Memory is constrained **by responsibility**, not with one blanket rule:

- **Data plane (`reactor`, `crypto`): strictly allocation-free.** All packet
  buffers live in resident memory fixed at startup; the hot path never allocates.
- **Control plane / reliability: independent arenas.** Policy rebuilds and the UDS
  path may allocate in isolated arenas with their own lifetimes, but must never
  pollute the data-plane memory line.

The acceptance bar — "0 bytes of RSS jitter under load" — applies to the
`raw_direct` data plane; control-plane hot updates may briefly use reclaimable
arena memory.

## 3. Single-threaded, lock-free reactor

One thread; a lock-free, allocation-free readiness loop. **No threads, no locks,
ever.** Because there is no concurrency between the data and control planes, no
mutex is needed; policy hot-updates happen via an atomic pointer swap (RCU). The
specific readiness primitive is **selected at comptime** — Linux `epoll`
edge-triggered, macOS `poll(2)` — but the single-thread / no-lock / no-per-packet-
allocation invariant is the law.

## 4. Stateless obfuscation / stealth

ChaCha20-Poly1305 full encryption with **no magic numbers** in the ciphertext. On
authentication failure, **drop silently** — never reply with a TCP Reset, ICMP, or
anything observable. The endpoint is physically invisible to probing.

## 5. Mandatory transport security in v1

A private per-link PSK, a per-endpoint 64-bit **monotonic nonce that is never
reused**, a per-restart session epoch, and a sliding-window **anti-replay** check.
These cannot be deferred to a later version. See the
[Security Model](security-model.md).

## 6. A single minimal binary

Default `-O ReleaseSmall`, zero third-party deps on every platform.

- **Linux:** fully static against musl-libc; `ldd` → `not a dynamic executable`;
  target **≤ 512 KB**.
- **macOS:** minimal-dynamic — links **only** `libSystem` (Apple ships no static
  libc), with its own recorded size baseline. The `ldd`-static check is a
  **Linux-only** gate.

## 7. Test-driven

Pure logic ships with tests; `zig build test` must stay green before any commit.
The wire protocol is pinned by machine-checkable known-answer vectors (see
[Wire Protocol](../reference/wire-protocol.md)).

## 8. Stateless, handshake-free transport

Every datagram is self-describing and independently decodable — the per-packet
**epoch is the entire session-establishment mechanism**. Subnetra performs **no
connection-establishment round-trip, no challenge/response, and no in-band session
negotiation** — not in v1, and not in v2. Any future transport mode is chosen by
**static per-link config** (the reserved `negotiation_version` / `flags` fields),
never negotiated on the wire.

Two consequences are accepted **by design, not deferred**:

1. An on-path attacker may replay a captured datagram of a not-yet-observed epoch
   to *transiently* relocate a peer's endpoint — it self-heals on the peer's next
   genuine packet, and an off-path attacker cannot forge it.
2. A node whose wall clock runs backward across a restart is rejected by peers
   until their clocks advance — mitigated operationally by NTP/RTC, never by an
   in-protocol epoch exchange.

> The `KEEPALIVE` flag (bit 0) is a one-way, never-acknowledged spoke→hub
> NAT-pinhole datagram gated by static config. It is **not** a handshake and does
> not weaken this law; bits 1–7 stay reserved for static mode selection.

## Scope discipline: v1 vs v2

- **v1 (delivered):** `raw_direct` data plane + PSK encryption + anti-replay + RCU
  hot-update policy engine.
- **v2 (roadmap, interface only):** `kcp_arq` and `fec_xor` — in-house reliability
  modes, **selected by static per-link config, never an on-wire handshake**. v1
  only reserves the `egress` branch and the header `negotiation_version` / `flags`
  fields; v2 branches return `error.NotImplemented`.

There is no handshake on the roadmap. See the [Roadmap](../reference/roadmap.md).

## Why these constraints?

The target is a steel pipe for a leased line into the most constrained
environments imaginable (a RouterOS / BusyBox container). Determinism, a tiny
auditable footprint, and stealth matter more than features. The constraints are
what make the result deployable where heavier tools cannot go.
