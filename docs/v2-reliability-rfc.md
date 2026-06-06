# RFC: v2 reliability layer (`kcp_arq` + `fec_xor`) — design proposal

> **Status: DRAFT / DESIGN-ONLY — NOT APPROVED, NO CODE AUTHORIZED.**
> This document proposes *how* the reserved v2 egress modes could be built. It
> ships **no implementation** and changes **no `src/` behaviour**. Per
> [`AGENT.md`](../AGENT.md) §2 and §4, v2 code must not begin until the
> maintainer signs off on this design. The authoritative *what* remains
> [`docs/btunnel-develop.md`](btunnel-develop.md); the normative v1 wire
> contract remains [`docs/PROTOCOL.md`](PROTOCOL.md). Where this RFC and either
> of those disagree, **they win and this RFC is wrong.**

## 1. Purpose and scope

v1 ships `raw_direct`: a stateless, allocation-free, handshake-free data plane.
The PRD reserves two **v2** egress modes for lossy/long-haul leased lines, both
**in-house** (no `ikcp.c`, no third-party FEC):

- `kcp_arq` — arena-based selective-repeat ARQ to absorb the small, sporadic
  loss of a managed leased line. Inner MTU **1428**.
- `fec_xor` — forward error correction (the PRD already flags that naïve 4:1 XOR
  is inadequate; see §7). Inner MTU **1428**.

The interface points already exist in the tree and this RFC builds **only** on
them — it does not widen the v1 surface:

| Reservation | Where it lives today |
|---|---|
| `EgressMode { raw_direct, kcp_arq, fec_xor }` | `src/reactor.zig` (`kcp_arq`/`fec_xor` → `error.NotImplemented`) |
| `mtuFor(mode)` → 1452 / 1428 / 1428 | `src/reactor.zig` |
| `flags` header byte, **MUST be 0** in v1 | `src/reactor.zig` `WireHeader`, `docs/PROTOCOL.md` §9 |
| `negotiation_version` (per-config) | `src/config.zig` `Config` |

**Out of scope (and staying that way):** any on-wire handshake, challenge/
response, capability exchange, or in-band mode negotiation. See §3.

## 2. The constraints any v2 design MUST satisfy

These are not negotiable; they are the iron laws restated as acceptance gates
for v2. A design that violates any of them is rejected before review.

1. **No handshake, ever (iron law #8).** The transport mode of a link is fixed
   by *static per-link configuration on both ends*. There is no round-trip,
   no negotiation, no capability probe — not even an optional one.
2. **Layered zero allocation (iron law #2).** The **data plane** (`reactor`,
   `crypto`) stays strictly allocation-free: every byte it touches lives in
   resident memory fixed at startup. Reliability state (retransmit queues,
   reorder buffers, FEC matrices) may live in an **independent arena** with its
   own lifecycle, but it **must never** allocate on, borrow from, or grow the
   data-plane resident line. The `memory_soak` acceptance test (RSS-flat under
   load) must stay green with a v2 link saturated.
3. **Single-threaded, lock-free (iron law #3).** No threads, no locks. ARQ
   timers are serviced from the one epoll loop (a timerfd or the epoll timeout),
   never a worker thread.
4. **Stealth preserved (iron law #4).** No new magic numbers in ciphertext. The
   reliability framing lives **inside** the AEAD-sealed body (§5), so the
   on-wire cleartext bytes a probe can see do not grow a recognizable fingerprint
   beyond what v1 already exposes.
5. **No nonce reuse, anti-replay intact (iron law #5).** Retransmissions are
   **fresh datagrams** with a fresh crypto `seq`/nonce; the ARQ sequence number
   is a *separate* inner space (§5). The existing sliding-window anti-replay on
   the crypto `seq` is unchanged and must keep passing.
6. **v1 interop is fail-closed, never silent corruption.** A v1 peer that
   receives a v2-framed datagram **drops it** (it already drops `flags != 0` —
   `decodeIngress` in `src/reactor.zig`). A misconfigured mixed link therefore
   *stops passing traffic loudly* (drop counters climb) instead of mis-decoding.
7. **Size budget holds (iron law #6).** The static binary stays ≤ 512 KB with
   v2 compiled in. ARQ/FEC code must be small; this is a design pressure, not an
   afterthought.

## 3. Mode selection without a handshake

Mode is a property of a **link** (a `peers[]` entry), chosen identically on both
ends by configuration, and is **never** discovered from the wire.

Proposed config surface (additive, defaulting to today's behaviour):

```jsonc
{
  "peers": [
    {
      "id": 3,
      "endpoint": "203.0.113.3:51820",
      "allowed_src": "10.0.0.3/32",
      "psk": "…64 hex…",
      "transport": "raw_direct"   // NEW, optional; default "raw_direct"
      // future: "kcp_arq" | "fec_xor"
    }
  ]
}
```

- `transport` defaults to `raw_direct`, so **every existing config is byte-for-
  byte unchanged** and keeps the v1 data plane.
- Both ends of a link **MUST** set the same `transport`. There is no negotiation
  to reconcile a mismatch; a mismatch is an operator error surfaced as drops.
- `negotiation_version` stays the config-level gate it is today; bumping it is
  how a future *config schema* change is fenced, still with no on-wire effect.
- `Reactor.mode` (today a single per-reactor field) becomes **per-peer**: the
  egress path already selects the peer by policy `target`/`key_id`, so it selects
  that peer's `transport` at the same point. `egress(mode, …)` keeps its shape.

### Wire signalling: the `flags` byte

`flags` is the *receiver's local decode hint*, set deterministically from the
**sender's** statically-configured mode — not a negotiation field:

| `flags` value | Meaning | v1 receiver |
|---|---|---|
| `0x00` | `raw_direct` (v1) | accept |
| `0x01` | `kcp_arq` body framing (proposed) | **drop** (`flags != 0`) |
| `0x02` | `fec_xor` body framing (proposed) | **drop** (`flags != 0`) |

Because a v1 receiver drops any non-zero `flags`, a v2 sender talking to a v1
peer is *fail-closed*. A v2 receiver still authenticates first and selects the
peer by `key_id` exactly as in v1; `flags` only tells it which **inner** decoder
to run **after** the AEAD opens. A tampered `flags` selects the wrong inner
decoder on already-authenticated plaintext → it cannot escalate privilege, only
self-corrupt that one datagram.

> **Open question (Q1):** `flags` is cleartext, so a distinct value is a faint
> traffic fingerprint, in slight tension with iron law #4's "stealth". The
> alternative is to keep `flags = 0` and have the receiver infer the inner
> framing purely from the peer's configured `transport` (it already looks the
> peer up by `key_id` before decode). That is *more* stealthy but loses the
> fail-closed-against-v1 property. The reserved-field intent in `PROTOCOL.md` §9
> favours using `flags`; **maintainer to confirm** which property wins.

## 4. Where the layer sits (data-plane integration)

```
TUN read ─▶ policy match ─▶ egress(peer.mode, pkt)
                                 ├─ raw_direct: seal → sendto              (v1, unchanged)
                                 ├─ kcp_arq:    arq.onEgress(pkt) ──▶ [arena] enqueue,
                                 │                                  emit segment(s):
                                 │                                  seal(reliab_hdr ++ pkt) → sendto
                                 └─ fec_xor:    fec.onEgress(pkt) ──▶ emit data + parity
UDP read ─▶ select peer by key_id ─▶ decodeIngress (auth + anti-replay)   (v1, unchanged)
                                 └─ if flags!=0: inner decode in [arena]
                                       ├─ kcp_arq: arq.onIngress(plain) → ack/reorder → deliver in-order to TUN
                                       └─ fec_xor: fec.onIngress(plain) → recover/deliver to TUN
epoll timeout / timerfd ─▶ arq.tick(now): RTO scan → retransmit from [arena] queue
```

Key properties:

- The **outer** crypto path (`encodeEgress`/`decodeIngress`, nonce, anti-replay)
  is **untouched**. v2 wraps an inner reliability header around the IP packet
  *before* sealing and unwraps it *after* opening. The crypto layer never learns
  about ARQ/FEC.
- All reliability state is reached through a per-peer handle that owns an
  **arena**; the reactor's resident buffers are not involved beyond the single
  scratch buffer already used to build one datagram.
- The timer is the **existing** epoll loop: `epoll_wait` gains a finite timeout
  equal to the nearest ARQ RTO deadline (or a timerfd registered like the UDS
  fd). No new thread (iron law #3).

## 5. Inner reliability framing (kcp_arq)

The reliability header is **plaintext inside the AEAD body**, i.e. it is sealed
and authenticated with the IP packet and is invisible on the wire:

```
outer (cleartext) : [ version=1 | flags=0x01 | key_id | epoch | crypto_seq ]   ← v1 header, unchanged
AEAD-sealed body  : [ reliab_hdr | inner IP packet ]  ++  tag
                      └─ reliab_hdr (proposed, compact):
                         u8  type     (0=DATA, 1=ACK, 2=DATA+piggyback-ACK)
                         u8  rsvd     (0)
                         u32 arq_seq  (per-link send sequence; retransmits REUSE it)
                         u32 arq_una  (cumulative ACK: next expected seq)
                         u16 wnd      (receiver free window, segments)
                         [ SACK block(s): u32 begin, u32 end ]   (optional, type-tagged)
```

Why this shape:

- `arq_seq` is a **separate space** from the crypto `seq`. A retransmit reuses
  `arq_seq` but is sent in a brand-new datagram with the next `crypto_seq`, so
  **no nonce is ever reused** and outer anti-replay still drops genuine outer
  duplicates. Inner dedup/reorder is keyed on `arq_seq` after decryption.
- ACKs ride as their own small datagrams or piggyback on reverse DATA. ACK
  datagrams are still fully sealed (no cleartext control packets).
- Selective-repeat with a cumulative `una` + optional SACK keeps the retransmit
  set tight under the bursty loss a leased line actually exhibits.

### Algorithm sketch (selective-repeat ARQ)

- **Send:** assign `arq_seq`, copy the segment into the arena send queue with a
  send timestamp, transmit. Flow/congestion bounded by a fixed `wnd` (no dynamic
  growth → bounded arena).
- **Receive:** authenticate (outer, unchanged) → read `reliab_hdr` → if in
  window, insert into the arena reorder buffer; advance and deliver any now-
  contiguous run to the TUN in order; schedule/coalesce an ACK.
- **RTO:** `tick(now)` walks the send queue; segments older than `rto`
  retransmit (new `crypto_seq`). `rto` from a smoothed RTT (Jacobson/Karn),
  clamped to `[rto_min, rto_max]`; Karn's algorithm excludes retransmitted
  samples. Bounded retries → then surface a drop counter (no infinite buffering).
- **Bounded memory:** send queue ≤ `wnd` segments; reorder buffer ≤ `wnd`
  segments; both pre-sized in the arena at link setup. A full window applies
  backpressure (drop-newest + counter), never an allocation.

> **Open question (Q2):** exact `wnd`, `rto_min/max`, and SACK on/off are
> tuning, not contract. Proposal: start with a small fixed `wnd` (e.g. 256
> segments) and cumulative-ACK only; add SACK behind the same `flags=0x01`
> framing only if measurements justify it. **Maintainer to set targets.**

## 6. MTU accounting

The reserved v2 inner MTU is **1428**. Its origin is `raw_direct` 1452 − 24,
i.e. it budgets a **24-byte** inner reliability header (the size of a classic
KCP segment header) against the v1 raw inner MTU. But that 1452 is itself the
"headroom" figure: on a plain 1500 underlay the real raw-direct inner ceiling is
`1500 − 28 (outer IPv4+UDP) − 20 (v1 wire header) − 16 (AEAD tag) = 1436` (see
`PROTOCOL.md` §8). Subtracting the inner reliability header from the **real**
ceiling gives:

```
1500 − 28 (outer IP/UDP) − 20 (v1 wire header) − 16 (AEAD tag)
     − reliab_hdr (12–24 B, §5) = 1412 … 1424 on a 1500 underlay
```

So the inherited **1428 literal is optimistic** against the *current* 20-byte
wire header (the #14 session epoch and #34 key_id selector enlarged it since the
reserved value was chosen). This must be reconciled before coding: re-derive a
canonical v2 inner MTU from the real overhead, make `mtuFor()` and
`--print-network-plan` agree with it, and freeze it into the v2 conformance
vectors. A smaller, honest value is preferred over a literal that silently
fragments at the boundary.

> **Open question (Q3):** confirm the canonical v2 inner MTU given the 20-byte
> wire header plus the chosen reliability header. The RFC recommends *computing*
> it from real overhead rather than inheriting the stale 1428 literal.

## 7. `fec_xor` re-evaluation (the PRD's own warning)

`docs/btunnel-develop.md` already records that **4:1 XOR only recovers exactly
one loss per 5-packet group and is useless against bursty loss** — which is the
loss pattern that actually matters. This RFC does **not** propose shipping naïve
4:1 XOR. Options, in increasing order of capability/cost:

1. **Interleaved XOR** — spread each parity group across time so a burst hits at
   most one member per group. Cheap, small code, but adds latency proportional
   to the interleave depth.
2. **Adaptive redundancy** — vary parity ratio from measured loss. More
   effective, but needs a loss estimate fed back — and any feedback path risks
   drifting toward a "negotiation". Must stay one-way (sender-driven from its own
   observed ACK/loss), never a handshake.
3. **In-house Reed–Solomon-style coding** — real burst tolerance, but the
   largest code/size cost and the highest risk against the ≤512 KB budget.

**Recommendation:** treat `fec_xor` as **lower priority than `kcp_arq`** and
gate it on a separate follow-up RFC once ARQ is proven. For most leased-line
loss, ARQ retransmission is the right tool; FEC is a latency-vs-bandwidth trade
that should be justified by measurement before any code. Keep the `fec_xor`
reservation (do not delete it), but do not design its wire framing in this RFC
beyond reserving `flags=0x02`.

> **Open question (Q4):** is FEC wanted at all for the target leased-line
> profile, or does ARQ alone meet the goal? **Maintainer to decide** before any
> FEC design work.

## 8. Test plan (TDD, written before code)

Following the PRD's TDD discipline, v2 lands test-first. No v2 branch returns
anything but `NotImplemented` until its tests exist and fail first.

**Unit (pure logic, `zig build test`):**
- ARQ state machine in isolation (fake clock): in-order delivery; reorder within
  window; duplicate `arq_seq` dropped; cumulative ACK advances `una`; RTO fires
  and retransmits with a *new* crypto seq; bounded window applies backpressure
  with **zero allocation after setup** (assert via a failing allocator wired to
  the data-plane line).
- Karn/Jacobson RTT/RTO math (monotonic, clamped).
- Framing round-trip: `reliab_hdr` encode/decode is endian-stable (same
  discipline as `encodeEgress`).

**Conformance vectors (`tests/protocol-vectors.json`, `zig build vectors`):**
- Extend the golden with v2 framing **only once the wire bytes are frozen**, via
  the same generate-from-live-code + drift-sentinel mechanism v1 uses
  (`src/protocol_vectors.zig`, `protocol_conformance.zig`). A v2 framing change
  must move the golden, exactly like v1.

**Integration (`test/integration/run.sh`, privileged netns):**
- A `kcp_arq` link under `netem loss` delivers **in order with full recovery**
  where today's `raw_direct` resilience test only asserts "keeps flowing,
  lossy" — the new scenario asserts *no application-visible loss* under the same
  impairment.
- The existing `memory_soak` scenario re-run with a saturated `kcp_arq` link
  must stay **RSS-flat** (proves the arena never leaks into the data-plane line).
- A **mixed-mode** link (one end `raw_direct`, one end `kcp_arq`) must *fail
  closed*: no delivery, `udp:auth_or_invalid`/drop counters climb, no crash.

## 9. Rollout / non-goals

- **Phased:** `kcp_arq` first, fully proven (unit + vectors + netns), before any
  `fec_xor` work. `fec_xor` gets its own RFC (§7).
- **Default stays v1:** absent `transport`, every link is `raw_direct`. v2 is
  strictly opt-in per link.
- **Non-goals:** no handshake; no dynamic mode switching; no congestion control
  beyond a fixed window in the first cut; no deletion of the v2 reservation
  points; no third-party libraries.

## 10. Decisions required from the maintainer (before any code)

- **Q1** — `flags`-signalled framing (fail-closed vs v1) **vs.** `flags=0`
  config-inferred framing (more stealthy). §3.
- **Q2** — ARQ window / RTO bounds and whether SACK is in the first cut. §5.
- **Q3** — canonical v2 inner MTU given the current 20-byte header. §6.
- **Q4** — is `fec_xor` in scope at all for the target loss profile, or ARQ-only?
  §7.
- **Go/No-Go** — approve `kcp_arq` to proceed *test-first*, or revise scope.

Until these are answered and this RFC is approved, the v2 egress branches stay
`error.NotImplemented` and no v2 code is written.
