# Security Model

Subnetra's transport security is **mandatory in v1** and cannot be deferred. This
page describes the threat model and every mechanism that enforces it. The
byte-exact rules live in the normative [Wire Protocol](../reference/wire-protocol.md);
this page is the conceptual companion.

## Threat model

Subnetra assumes a hostile underlay: an attacker can observe, drop, modify,
inject, and replay UDP datagrams, and can actively probe the listening port. The
design goals are:

- **Confidentiality & integrity** of every inner packet.
- **Stealth** — an active prober cannot distinguish a Subnetra endpoint from a
  host that simply drops traffic.
- **No replay** of captured ciphertext into the protected network.
- **Compartmentalization** — compromising one spoke's key must not forge any
  other link.

## Per-link pre-shared keys

Each `peers[]` entry carries its **own** 32-byte PSK (64 hex chars). There is no
mesh-wide shared secret; an old config that still carries a top-level `psk` is
rejected (`InvalidPsk`), and reusing one PSK across peers is rejected
(`DuplicatePsk`).

From each PSK, a **directional link key** is derived per ordered pair:

```text
link_key(psk, from_id, to_id) =
    BLAKE2b-256(key = psk, msg = "subnetra-v1-link" || u32_be(from_id) || u32_be(to_id))
```

So a node's transmit key to a peer equals that peer's receive key for traffic from
the node, and the two directions use distinct keys.

> **Why per-link keys are mandatory:** under a shared PSK, two independent
> per-peer monotonic counters could emit the same `(key, nonce)` pair for
> different plaintexts, which catastrophically breaks ChaCha20-Poly1305. Giving
> every directional link its own key makes each link's nonce space disjoint.

## Session epoch — stateless, handshake-free sessions

Subnetra establishes no session on the wire. Instead, each daemon lifetime samples
a **boot epoch** once at startup (wall-clock nanoseconds, `u64`) and derives a
fresh **per-session key**:

```text
session_key(link_key, epoch) =
    BLAKE2b-256(key = link_key, msg = "subnetra-v1-session" || u64_be(epoch))
```

The epoch travels in every datagram (8 bytes). The receiver derives the matching
key **statelessly** from the epoch it sees and applies a **forward-only** rule:

- A larger (later) epoch, once authenticated, supersedes the old session and
  **resets the anti-replay window**.
- A smaller (older) epoch is dropped (it would be a cross-epoch replay of a
  retired session).

Because every restart yields a new key, sequence numbers can safely restart from 1
without ever reproducing a historical `(key, nonce)` pair — no disk persistence
required.

**Fail-closed clock:** the epoch must be ≥ `2024-01-01T00:00:00Z` in nanoseconds
and non-zero. A node whose clock cannot satisfy this refuses to start, rather than
emit a low/colliding epoch.

> **Accepted residual limitation:** if a node's wall clock runs *backward* across a
> restart (no RTC, not yet NTP-synced), its new epoch may be smaller than the one a
> peer remembers, and the peer will reject the new session until its clock advances
> past the old value. This is mitigated operationally (NTP/RTC), never by an
> in-protocol epoch exchange — there is no handshake by design.

## Nonce & anti-replay

The 96-bit AEAD nonce is derived from a 64-bit **monotonic counter** that each
endpoint increments per datagram — it is **never fixed or reused**. The receiver
maintains a **sliding-window** (bitmap) anti-replay check per session: a sequence
number outside the window, or one already seen, is dropped; an in-window
out-of-order number is accepted. Without this, historical ciphertext could be
replayed into the protected LAN.

## Stealth: silent drop, no magic bytes

Subnetra is **stateless obfuscation**: the ciphertext contains **no fixed magic
number**, and on any authentication or validation failure the packet is **dropped
silently** — never answered with a TCP Reset, an ICMP error, or anything
observable. To an active prober sending garbage (or replayed ciphertext) at the
UDP port, the endpoint is indistinguishable from a black hole, and its CPU shows no
unusual spike.

This defeats **active** probing. The 20-byte framing header is, however, cleartext
and outside the AEAD, so a **passive** on-path observer can still fingerprint the
protocol by its constant `version`, repeated `epoch`, and low monotonic `seq`. The
optional, deployment-wide **`obfuscate`** setting
([Wire Protocol → Header obfuscation](../reference/wire-protocol.md#header-obfuscation-optional))
XOR-masks the header with a per-packet pad so the whole datagram looks random to such
an observer — zero byte overhead, off by default, mesh-wide identical. It hides the
protocol fingerprint only, **not** packet length or timing.

## Inner-source binding (anti-spoofing)

Each peer declares an `allowed_src` CIDR. After decryption, the receiver checks the
**inner IPv4 source address** against that peer's `allowed_src`; a packet whose
inner source falls outside the allowed range is dropped (counted as `spoof`). This
prevents an authenticated peer from injecting traffic that impersonates another
node's address space.

## No-reflect relay guard

When the hub relays between spokes, it never sends a packet **back to the peer it
came from**. Combined with longest-prefix policy routing, this prevents reflection
loops.

## NAT keepalive (one-way, never acknowledged)

A `role=spoke` enables a built-in NAT keepalive by default (`keepalive_secs = 20`):
it sends one tiny **authenticated** datagram to its hub each interval so the spoke's
NAT pinhole stays open and the hub keeps a fresh route back. It is a one-way,
**never-acknowledged** datagram gated purely by static config — it is **not** a
handshake and does not weaken the stateless model. Set `keepalive_secs` to tune it,
or `0` to disable (hub/manual default to `0`).

## What secrets are never exposed

`subnetra status` (and `--json`) deliberately **never** serialize PSKs or any
derived key. Counters, endpoints, and health are observable; secrets are not.

## Cryptographic primitives

| Primitive | Choice | Parameters |
|---|---|---|
| AEAD | ChaCha20-Poly1305 (IETF, 96-bit nonce) | key 32 B, nonce 12 B, tag 16 B |
| KDF / keyed hash | BLAKE2b-256 in **native keyed mode** (not HMAC) | key = parent key, 32 B digest |

See the [Wire Protocol](../reference/wire-protocol.md) for the exact key schedule,
nonce construction, header serialization, and the full receiver decision sequence —
all pinned by known-answer test vectors.
