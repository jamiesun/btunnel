# BTunnel Wire Protocol Specification — v1

> **Status: normative.** This document is the interoperability contract for the
> BTunnel data plane. Any implementation — regardless of operating system or
> programming language — that reproduces the behaviour below is a conformant
> BTunnel endpoint and can join a mesh alongside the reference implementation.
>
> The reference implementation (pure Zig) lives in `src/` and is the executable
> source of truth. The machine-checkable companion to this document is the
> known-answer-test (KAT) vector set in
> [`tests/protocol-vectors.json`](../tests/protocol-vectors.json) — a **sender**
> suite (`vectors`) that pins key derivation and emitted datagram bytes, and a
> **receiver** suite (`receiver_cases`) that pins the accept/drop decision,
> recovered plaintext, and post-step session epoch for a sequence of crafted
> datagrams. Both are pinned to the code by `src/protocol_conformance.zig` (runs
> under `zig build test`) and regenerated with `zig build vectors`.
>
> **Authority:** for the KDF, header serialization, AEAD, and emitted sender
> datagram bytes, the KAT `vectors` are authoritative — if this prose disagrees
> with them, the vectors win. Receiver accept/drop behaviour is normative in §5
> and is mechanically exercised by `receiver_cases`; the inner-source filter,
> source-endpoint filter, and no-reflect relay guard (§5 steps 1, 7, 8) are
> normative prose that the reference implementation enforces in its reactor loop
> but that the cross-implementation KAT does not yet encode.

The key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used as in
RFC 2119.

---

## 1. Scope and model

BTunnel forwards raw IPv4 packets between mesh nodes over an encrypted UDP
underlay in a **single-hub hub-and-spoke** topology. Each node has a numeric
mesh **id** (`u32`, non-zero). Every directional link `(from_id → to_id)` has
its own keys, so a node's transmit key to a peer equals that peer's receive key
for traffic from the node.

This specification covers the **on-wire datagram**: how a plaintext inner IP
packet becomes a UDP payload, and the rules a receiver applies to accept or
silently drop one. It does **not** mandate *how* an endpoint sources or delivers
inner packets (a kernel TUN device, a userspace IP stack, or an application
buffer are all permitted) nor the host's eventing model (epoll, kqueue, threads,
async — all permitted).

**`wire_version` for this document is `1`.** It is carried in byte 0 of every
datagram (see §3).

---

## 2. Cryptographic primitives

| Primitive | Choice | Parameters |
|-----------|--------|------------|
| AEAD | **ChaCha20-Poly1305 (IETF, 96-bit nonce)** | key 32 B, nonce 12 B, tag 16 B |
| KDF / keyed hash | **BLAKE2b with 256-bit (32 B) digest, keyed mode** | key = the parent key; **native BLAKE2 keyed mode, NOT HMAC** |

Implementers **MUST** use BLAKE2b's built-in keyed hashing (the key occupies the
first input block per the BLAKE2 spec), **not** HMAC-BLAKE2b. The digest length
parameter is 32 and the key length parameter equals the key's byte length (32).

### 2.1 Key schedule

All multi-byte integers fed into the KDF are **big-endian**. The label strings
are ASCII with **no NUL terminator**.

```
link_key(psk, from_id, to_id) =
    BLAKE2b-256( key = psk,
                 msg = "btunnel-v1-link"            // 15 bytes
                     || u32_be(from_id)             //  4 bytes
                     || u32_be(to_id) )             //  4 bytes   → 32-byte key

session_key(link_key, epoch) =
    BLAKE2b-256( key = link_key,
                 msg = "btunnel-v1-session"         // 18 bytes
                     || u64_be(epoch) )             //  8 bytes   → 32-byte key
```

- The **sender** of a datagram uses `link_key(psk, local_id, peer_id)`.
- The **receiver** derives the matching key with `link_key(psk, peer_id,
  local_id)` (the same ordered pair the sender used). The two agree.
- `psk` is a **per-link 32-byte pre-shared key**. A node **MUST NOT** reuse one
  PSK across different peers.

> **Why per-link keys are mandatory:** under a shared PSK, two independent
> per-peer monotonic counters could emit the same `(key, nonce)` pair for
> different plaintexts, which catastrophically breaks ChaCha20-Poly1305. Giving
> every directional link its own key makes each link's nonce space disjoint.

### 2.2 Nonce

The 96-bit AEAD nonce is derived from the 64-bit sequence number:

```
nonce(seq) = u64_le(seq) || 0x00 0x00 0x00 0x00      // 8 bytes LE + 4 zero bytes
```

The AEAD is invoked with **empty associated data (AAD)**. The 16-byte Poly1305
tag is appended **after** the ciphertext.

### 2.3 Session epoch (stateless session establishment)

Each daemon lifetime samples a **boot epoch** once at startup:
`epoch = wall-clock time in nanoseconds` (`u64`).

- The epoch **MUST** be `>= 1_704_067_200_000_000_000` (2024-01-01T00:00:00Z in
  ns) and **MUST NOT** be `0`. An endpoint whose clock cannot satisfy this
  **MUST** fail closed (refuse to start) rather than emit a low/zero epoch.
- The epoch is carried in every datagram (§3), so a receiver derives the
  matching `session_key` **statelessly, with no handshake**.
- A fresh epoch on every restart re-keys the session, which is what lets the
  transmit sequence number safely restart at `1` after a reboot without ever
  reproducing a previous lifetime's `(key, nonce)` pair.

---

## 3. Datagram format

A BTunnel UDP payload is:

```
+------------------+---------------------------+----------------+
|  header (20 B)   |  ciphertext (len(inner))  |  tag (16 B)    |
+------------------+---------------------------+----------------+
```

### 3.1 Header (20 bytes, fixed)

| Offset | Size | Field      | Encoding   | v1 value / meaning                                   |
|-------:|-----:|------------|------------|------------------------------------------------------|
| 0      | 1    | `version`  | u8         | **MUST be `1`**                                      |
| 1      | 1    | `flags`    | u8         | **MUST be `0`** in v1 (reserved)                    |
| 2      | 2    | `reserved` | u16 **LE** | **MUST be `0`** in v1 (reserved for v2 negotiation) |
| 4      | 8    | `epoch`    | u64 **LE** | sender boot epoch (§2.3); never `0`                 |
| 12     | 8    | `seq`      | u64 **LE** | per-session monotonic sequence number / nonce basis |

> **Endianness trap (read carefully):** the header fields `epoch` and `seq` are
> **little-endian**, but the *same* `epoch` value fed into the session KDF
> (§2.1) and the `from_id`/`to_id` fed into the link KDF are **big-endian**. The
> KAT vectors exist precisely to catch implementations that get this wrong.

### 3.2 Body

`ciphertext || tag = ChaCha20-Poly1305-Seal(key = session_key, nonce =
nonce(seq), aad = "", plaintext = inner_ip_packet)`.

The inner plaintext is a complete IPv4 packet. The ciphertext has the **same
length** as the plaintext; the tag adds a fixed 16 bytes.

---

## 4. Sender behaviour (egress)

To send inner IPv4 packet `P` to peer `D`:

1. `key = session_key(link_key(psk, local_id, D.id), local_epoch)`.
2. `seq = ` next value of this link's monotonic counter (starts at `1`, strictly
   increasing, **MUST NOT** repeat within a session/epoch).
3. Emit header (§3.1) with `version=1, flags=0, reserved=0, epoch=local_epoch,
   seq`.
4. Append `ChaCha20-Poly1305-Seal(key, nonce(seq), "", P)`.
5. Send the datagram to `D`'s UDP endpoint.

A sender **MUST** treat the `(session_key, nonce)` uniqueness invariant as
absolute. On any event that could reset the counter (e.g. process restart) it
**MUST** also obtain a fresh `epoch` (and therefore a fresh `session_key`).

---

## 5. Receiver behaviour (ingress)

On a received UDP datagram from source endpoint `S`:

1. **Source-endpoint filter.** Look up `S` (source IP + UDP port) in the peer
   table. If unknown, **drop silently** (§7). This binds `S` to a known link key.
2. **Header validation** — drop silently if **any** of:
   - `len(datagram) < 20`;
   - `version != 1`;
   - `flags != 0`;
   - `reserved != 0`;
   - `epoch == 0`.
3. **Epoch ordering (forward-only).** Let `cur` be the highest epoch already
   accepted on this link (`0` if none).
   - If `epoch < cur`: **drop silently** (retired session / cross-epoch replay)
     before spending any crypto.
   - If `epoch == cur`: use the cached `session_key`.
   - If `epoch > cur`: derive a **candidate** `session_key(link_key, epoch)` but
     do **not** commit it yet.
4. **Authenticate & decrypt** with the selected key and `nonce(seq)`. On
   authentication failure or truncation, **drop silently**. (No state has been
   mutated yet — a forged higher `epoch` cannot poison the session.)
5. **Commit a newer epoch.** Only now, if `epoch > cur`, adopt it: set
   `cur = epoch`, cache its key, and **reset** the anti-replay window.
6. **Anti-replay.** Apply the 64-entry sliding window (§6) to `seq`. If the
   sequence is a replay or older than the window, **drop silently**.
7. **Inner source check.** The decrypted IPv4 packet's **source address MUST**
   fall within the `allowed_src` prefix bound to `S`. Otherwise **drop
   silently** (defeats inner-source spoofing by an authenticated peer).
8. **Route.** Look up the inner destination. Deliver to the local node, or (hub
   only) relay to another peer. A hub **MUST NOT** reflect a packet back to its
   source peer.

The order of steps 3–5 (authenticate **before** mutating any receive state) is
**normative** and security-critical.

---

## 6. Anti-replay window

Each receive session maintains a 64-bit sliding window over accepted sequence
numbers (`highest` + a 64-bit `bitmap`, where bit *i* means `highest - i` was
seen):

- `seq > highest`: accept; shift the window forward by `seq - highest`; set
  `highest = seq`.
- `highest - seq >= 64`: **reject** (too old).
- Otherwise: **reject** if the corresponding bit is already set (replay); else
  accept and set it.

The window is **reset** whenever a strictly newer epoch is adopted (§5.5).

---

## 7. Stealth / failure handling

On **any** rejection — unknown source, malformed header, reserved bits set,
stale/zero epoch, authentication failure, replay, or inner-source violation —
the endpoint **MUST silently drop** the datagram. It **MUST NOT** emit a TCP
RST, an ICMP error, or any other observable response. The ciphertext **MUST
NOT** contain any fixed magic number. These rules make BTunnel
indistinguishable from background noise to an external prober.

---

## 8. MTU and overhead

Per-datagram overhead on top of the inner IP packet:

```
header(20) + tag(16) + outer IPv4(20) + outer UDP(8) = 64 bytes
```

For the v1 `raw_direct` egress mode the inner tunnel MTU is **1452**. On a 1500-
byte underlay path the largest safe inner MTU is `1500 - 64 = 1436`; operators
**SHOULD** size the tunnel interface MTU accordingly (see
`--print-network-plan`).

---

## 9. Versioning and forward compatibility

- This document specifies **`wire_version = 1`**. A v1 receiver **MUST** drop any
  datagram whose `version` byte is not `1` (there is no in-band negotiation in
  v1).
- The `flags` byte and the 2-byte `reserved` field are **reserved for the v2
  handshake negotiation** and **MUST be zero** in v1, on both send and receive.
- Two egress modes are reserved for v2 and are **not** part of the v1 wire
  contract: `kcp_arq` (in-house ARQ, MTU 1428) and `fec_xor` (forward error
  correction). A v1 implementation does not implement them.
- **Any change that alters the bytes a conformant endpoint emits or the
  accept/drop decision it makes is a breaking change** and **MUST** bump
  `wire_version`. Mechanically, a sender-byte change moves the `vectors` golden
  and a receiver accept/drop change moves the `receiver_cases` golden; either
  way the conformance sentinel forces a deliberate regeneration
  (`zig build vectors > tests/protocol-vectors.json`) and review.

---

## 10. Conformance vectors

[`tests/protocol-vectors.json`](../tests/protocol-vectors.json) carries two
suites.

**`vectors` (sender KAT)** maps fixed inputs to their canonical outputs:

```
input:  { psk, from_id, to_id, epoch, seq, plaintext }
output: { link_key, session_key, datagram }   // all lowercase hex
```

An implementation is **sender-conformant** iff, for every vector, it reproduces
`link_key`, `session_key`, and the full `datagram` byte-for-byte from `input`.

**`receiver_cases` (receiver KAT)** drives a sequence of datagrams through a
single receive session:

```
case:  { name, link: { psk, from_id, to_id }, init_epoch, steps: [...] }
step:  { note, datagram, expect: "accept"|"drop", plaintext, epoch_after }
```

An implementation is **receiver-conformant** iff, replaying each case's `steps`
in order against a session preloaded to `init_epoch` (0 = fresh), it reaches the
same `accept`/`drop` decision, recovers the same `plaintext` on accept, and ends
each step at the same `epoch_after`. These cases exercise header validation,
zero/stale-epoch rejection, authentication failure, replay, in-window reorder,
and forward-only epoch adoption with window reset (§5–§6).

The top-level `max_plaintext` field pins the v1 `raw_direct` inner MTU (§8); a
boundary-sized vector exercises it.

New vectors/cases **MAY** be appended; existing ones **MUST NOT** be reordered
or mutated except by an intentional, reviewed wire-format change (which also
bumps `wire_version`).
