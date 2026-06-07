# Wire Protocol

This page is a readable summary of the **Subnetra v1 wire protocol**. The
authoritative, normative specification — with RFC 2119 keywords and known-answer
test (KAT) vectors — is
[`docs/PROTOCOL.md`](https://github.com/jamiesun/subnetra/blob/main/docs/PROTOCOL.md).
If this prose ever disagrees with the spec or its vectors, the spec/vectors win.

> **Why a normative spec?** Any implementation, in any language, that reproduces
> the behavior below is a conformant Subnetra endpoint and can join a mesh
> alongside the reference (pure-Zig) implementation. The behavior is pinned by KAT
> vectors in
> [`tests/protocol-vectors.json`](https://github.com/jamiesun/subnetra/blob/main/tests/protocol-vectors.json),
> checked against the live code under `zig build test` and regenerated with
> `zig build vectors`.

## Model

Subnetra forwards raw IPv4 packets over an encrypted UDP underlay in a
single-hub hub-and-spoke topology. Each node has a numeric mesh **id**
(`0 < id ≤ 65535`) that doubles as the on-wire `key_id` selector. Every
directional link `(from_id → to_id)` has its own keys. `wire_version` is `1`.

## Cryptographic primitives

| Primitive | Choice | Parameters |
|---|---|---|
| AEAD | ChaCha20-Poly1305 (IETF, 96-bit nonce) | key 32 B, nonce 12 B, tag 16 B |
| KDF / keyed hash | BLAKE2b-256, **native keyed mode (not HMAC)** | key = parent key, 32 B digest |

### Key schedule

All integers fed into the KDF are **big-endian**; labels are ASCII with no NUL.

```text
link_key(psk, from_id, to_id) =
    BLAKE2b-256(key = psk, msg = "subnetra-v1-link" || u32_be(from_id) || u32_be(to_id))

session_key(link_key, epoch) =
    BLAKE2b-256(key = link_key, msg = "subnetra-v1-session" || u64_be(epoch))
```

The sender uses `link_key(psk, local_id, peer_id)`; the receiver derives the
matching key with `link_key(psk, peer_id, local_id)`. `psk` is a per-link 32-byte
secret and **MUST NOT** be reused across peers.

### Nonce

```text
nonce(seq) = u64_le(seq) || 0x00 0x00 0x00 0x00      // 8 bytes LE + 4 zero bytes
```

The AEAD uses **empty AAD**; the 16-byte tag follows the ciphertext.

### Session epoch

Each daemon lifetime samples a boot epoch once (wall-clock ns, `u64`), which
**MUST** be `≥ 2024-01-01T00:00:00Z` in ns and non-zero. A node that cannot satisfy
this **fails closed** (refuses to start). The epoch travels in every datagram, and
the receiver derives the matching session key from it statelessly — there is **no
handshake**.

## Datagram format

```text
+------------------+---------------------------+----------------+
|  header (20 B)   |  ciphertext (len(inner))  |  tag (16 B)    |
+------------------+---------------------------+----------------+
```

### Header (20 bytes, fixed)

| Offset | Size | Field | Encoding | Meaning |
|---:|---:|---|---|---|
| 0 | 1 | `version` | u8 | MUST be `1` |
| 1 | 1 | `flags` | u8 | bit 0 = `KEEPALIVE`; bits 1–7 reserved, MUST be `0` |
| 2 | 2 | `key_id` | u16 **LE** | sender's mesh id — the receiver's peer selector |
| 4 | 8 | `epoch` | u64 **LE** | sender boot epoch; never `0` |
| 12 | 8 | `seq` | u64 **LE** | per-session monotonic sequence number / nonce basis |

> **`key_id` is an unauthenticated selector** — it is **not** covered by the AEAD
> (AAD is empty). A forged `key_id` just selects the wrong key, authentication
> fails, and the datagram is dropped. It lets a roaming/NATed sender be recognized
> by identity rather than by source endpoint.

> **Endianness trap:** header `epoch` and `seq` are **little-endian**, but the same
> `epoch` fed into the session KDF and the `from_id`/`to_id` fed into the link KDF
> are **big-endian**. The KAT vectors exist to catch exactly this mistake.

### Keepalive (`flags` bit 0)

A datagram with `KEEPALIVE = 0x01` set is a one-way spoke→hub NAT keepalive sealed
over an **empty** inner plaintext, so its total length is `20 + 16 = 36` bytes. It
rides the same `seq` + epoch + anti-replay machinery, is **never acknowledged**,
and is **not** a handshake. A receiver predating this bit simply drops keepalives
(strict `flags == 0` check) with no effect on data delivery.

## Sender (egress)

To send inner IPv4 packet `P` to peer `D`:

1. `key = session_key(link_key(psk, local_id, D.id), local_epoch)`.
2. `seq = ` next value of this link's monotonic counter (starts at `1`, strictly
   increasing, never repeating within a session/epoch).
3. Emit the header with `version=1, flags=0, key_id=local_id, epoch=local_epoch, seq`.
4. Append `ChaCha20-Poly1305-Seal(key, nonce(seq), "", P)`.
5. Send to `D`'s UDP endpoint.

On any event that could reset the counter (e.g. a restart), the sender **MUST**
also obtain a fresh epoch (and therefore a fresh session key).

## Receiver (ingress)

On a datagram from source endpoint `S`, in this **normative order**:

1. **Identity selection** by `key_id` (not by endpoint). No matching peer ⇒ drop.
2. **Header validation** — drop if `len < 20`, `version != 1`, a reserved `flags`
   bit is set, or `epoch == 0`.
3. **Epoch ordering (forward-only).** `epoch < cur` ⇒ drop before any crypto;
   `epoch == cur` ⇒ use the cached key; `epoch > cur` ⇒ derive a *candidate* key but
   do not commit yet.
4. **Authenticate & decrypt** with the link key and `nonce(seq)`. Failure ⇒ drop.
   (No state mutated yet — a forged higher epoch or wrong `key_id` cannot poison the
   session.)
5. **Commit a newer epoch** only now (set `cur = epoch`, cache key, **reset** the
   anti-replay window).
6. **Anti-replay** — apply the 64-entry sliding window to `seq`; replay/too-old ⇒
   drop. *(Keepalive short-circuits here: it records the endpoint + last-seen, then
   stops — no inner packet.)*
7. **Inner source check** — the decrypted source address MUST fall within `P`'s
   `allowed_src`; otherwise drop (anti-spoofing).
8. **Endpoint learning** — only after steps 4–7, optionally record `S` as `P`'s
   current endpoint (roaming/NAT). Runtime state only; never written to config.
9. **Route** — deliver locally or (hub only) relay to another peer; a hub **MUST
   NOT** reflect back to the source peer.

The order of steps 3–5 (authenticate **before** mutating receive state) and step 8
(learn the endpoint **only after** 4–7) is security-critical.

## Anti-replay window

Each receive session keeps a 64-bit sliding window (`highest` + a 64-bit bitmap,
bit *i* = "`highest − i` was seen"): `seq > highest` shifts the window forward and
accepts; an in-window unseen `seq` is accepted and marked; a replay or
older-than-window `seq` is dropped.

## Accepted residual risks (by design, no handshake)

- **Pre-observation epoch replay.** An on-path attacker who captures an
  authenticated datagram for epoch `E` and replays it *before* the receiver has
  observed `E` can transiently relocate the peer's learned endpoint. It self-heals
  on the peer's next genuine packet, and an off-path attacker cannot forge it.
- **Backward clock across restart.** A node whose wall clock regresses emits a lower
  epoch that peers reject until their clocks advance past the old value. Mitigated
  operationally (NTP/RTC), never by an in-protocol exchange.

Both follow directly from the [stateless, handshake-free design](../concepts/design-principles.md#8-stateless-handshake-free-transport).
