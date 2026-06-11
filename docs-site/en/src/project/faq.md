# FAQ

### What is Subnetra, in one sentence?

A pure-Zig, zero-dependency Layer-3 UDP tunnel that ships as a single static
binary under 512 KB and connects sites and devices in a hub-and-spoke overlay with
full per-link encryption.

### Is it a VPN? How is it different from WireGuard?

It is a Layer-3 encrypted overlay, so it solves a similar problem to WireGuard.
The differences are deliberate trade-offs:

- **No handshake.** Subnetra is stateless and handshake-free; the per-packet epoch
  plus a static config replaces session negotiation. There is no Noise handshake,
  no rekey timer, no roaming handshake.
- **Single static binary, no kernel module, no third-party libraries** — it runs
  entirely in userspace on a TUN device and cross-compiles to musl targets down to
  armv5.
- **Hub-and-spoke by design**, with an in-binary CIDR policy engine for
  site-to-site routing and hub relay, hot-updated without a restart.

It is not trying to be a drop-in WireGuard replacement; it targets fixed,
operator-managed deployments where a tiny auditable binary and static topology are
the priority.

### How is it different from n2n?

Both build an encrypted overlay, but the designs are near-opposites:

- **Star, not P2P.** n2n's signature is supernode-assisted NAT hole-punching so edges
  talk directly. Subnetra is strict hub-and-spoke and **deliberately has no P2P /
  hole-punching** — every spoke-to-spoke packet relays through the hub, for one
  predictable path (a [non-goal](../reference/roadmap.md#explicit-non-goals)).
- **Layer 3, not Layer 2.** n2n is an Ethernet (TAP) overlay with broadcast, ARP and
  any protocol. Subnetra routes IPv4 by CIDR only — no broadcast domain.
- **Handshake-free, one fixed cipher.** n2n has a registration protocol and
  per-community selectable ciphers. Subnetra has no registration round-trip and one
  mandatory AEAD (ChaCha20-Poly1305) with a unique key per link.
- **Static, not discovered.** n2n finds peers dynamically via supernodes. Subnetra
  uses static numeric endpoints with no in-daemon discovery or DNS.

Pick n2n for plug-and-play P2P and L2 LAN semantics; pick Subnetra for a tiny,
auditable binary with a deterministic single-path topology.

### Why no handshake? Isn't that insecure?

No. Every packet is encrypted and authenticated with ChaCha20-Poly1305 under a
per-link key. Replay is stopped by a 64-bit monotonic nonce and a sliding-window
filter, and a per-restart **session epoch** is mixed into key derivation so old
captures can't be replayed across a restart. "Handshake-free" means there is no
*negotiation* round-trip — not that packets are unauthenticated. See the
[Security Model](../concepts/security-model.md).

### Does it hide that it's a tunnel? Is it "stealth"?

Partly. Obfuscation is **stateless and best-effort**: a malformed or
unauthenticated datagram is silently dropped with **no error reply**, so the
listener does not advertise itself to blind scanners. Subnetra does **not** claim
to defeat a sophisticated DPI adversary, and it is honest about that — see
[Design Principles → Stateless obfuscation](../concepts/design-principles.md).

By default the 20-byte header is cleartext, so a *passive* observer can still
fingerprint the protocol; the optional mesh-wide `obfuscate` setting masks the header
so the datagram looks random (it hides the fingerprint, not packet length or timing).
See [Wire Protocol → Header obfuscation](../reference/wire-protocol.md#header-obfuscation-optional).

### What platforms are supported?

- **Linux** is the production target: `x86_64`, `aarch64`, `armv7` (hard float),
  and `armv5` (soft float), all static musl. The hub typically runs on Linux.
- **macOS** is a supported **spoke / developer** platform via the native `utun`
  device (minimal-dynamic, linking only libSystem). It is not a production hub
  target.

### How big / fast is it?

The Linux release binary is a single static musl executable **under 512 KB**. The
data plane is single-threaded, lock-free, and strictly **allocation-free** on the
hot path, so memory use is bounded and predictable. For a throughput baseline on
your own hardware, run
[`test/integration/bench.sh`](https://github.com/jamiesun/subnetra/blob/main/test/integration/bench.sh).

### What MTU should I use?

The fixed wire overhead is **64 bytes** (20-byte header + 16-byte tag + 28-byte
outer IPv4/UDP). The safe tunnel MTU is therefore `path_mtu − 64` — e.g. 1452 on a
1500-byte underlay. Set `local_tun_mtu` accordingly, and use
`subnetrad --print-network-plan --path-mtu <n>` to compute and preview the host
plan. See the [Network Plan](../configuration/network-plan.md).

### Does Subnetra configure the host network for me?

No — by design it **only prints** the plan; it never mutates host routing or
firewall state. `subnetrad --print-network-plan` emits the exact `ip`/`route`
commands so you (or your config-management tool) apply them deliberately and
auditable. The daemon does create and manage its own TUN device.

### How do PSKs work? Can two links share a key?

Each **link** (each peer pair, per direction) uses its own 64-hex pre-shared key.
Keys must be **unique per link** — never reuse a PSK across peers. Generate them
with `zig build tool:keygen`. Directional keys are derived from the PSK, so the A→B
and B→A directions use different keys.

### How do I route a real LAN behind a spoke (site-to-site)?

Set the LAN prefix in `remote_routes`/`local_routes` and add policy rules that
forward the destination prefix to the right mesh id. The hub relays between spokes.
See [Configuration → Roles](../configuration/roles.md) and the
[`policy add`](../reference/cli.md#policy-add-arguments) examples.

### How do I run it on RouterOS / MikroTik?

Via the RouterOS **container** feature (a static-binary container on the device).
See [Operations → RouterOS](../operations/routeros.md).

### The hub has a dynamic IP — now what?

Endpoints are numeric on purpose (no in-daemon DNS). Solve it operationally: run a
small DDNS watcher on the spoke that rewrites the hub `endpoint` and reloads. The
spoke's NAT keepalive keeps the path open. See
[Security Model → NAT keepalive](../concepts/security-model.md).

### Is there a built-in failover / multi-path?

No. The data plane is intentionally single-path; failover is an **external**
decision (VRRP / health-checked DNS / orchestration). This keeps the daemon small
and predictable. See [Deployment → High Availability](../operations/deployment.md#8-high-availability)
and the [Roadmap](../reference/roadmap.md#explicit-non-goals).

### When is v2 (`kcp_arq` / `fec_xor`) coming?

Those are **reserved interface points**, design-only, returning
`error.NotImplemented` until the maintainer approves the design RFC. v1 ships
`raw_direct` only. See the [Roadmap](../reference/roadmap.md).

### Why Zig, and why zero dependencies?

To get a tiny, statically-linked, auditable binary with predictable memory and no
supply chain — the whole data plane is the standard library plus raw syscalls. The
[Design Principles](../concepts/design-principles.md) ("eight iron laws") explain the
reasoning in full.

### Where is the authoritative spec?

The normative on-wire contract is
[`docs/PROTOCOL.md`](https://github.com/jamiesun/subnetra/blob/main/docs/PROTOCOL.md);
the product requirements are
[`docs/subnetra-develop.md`](https://github.com/jamiesun/subnetra/blob/main/docs/subnetra-develop.md).
This site summarizes and operationalizes them; where they disagree with this site,
**they win**.
