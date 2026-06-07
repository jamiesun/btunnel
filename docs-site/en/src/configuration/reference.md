# Configuration Reference

The daemon reads a single `config.json` from its working directory (override with
`--config <path>`). If the file is missing it falls back to a compiled-in default.
The parser is strict: unknown shapes, invalid CIDRs, or values out of range cause
a **fail-closed** startup. Validate any change with `subnetrad --check` before
deploying.

A minimal example (`config.example.json`):

```json
{
  "negotiation_version": 1,
  "local_tun_mtu": 1452,
  "listen_port": 51820,
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:51820", "allowed_src": "10.0.0.2/32", "name": "bj-office-gw", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:51820", "allowed_src": "10.0.0.3/32", "name": "colo-hub",     "psk": "…64 hex…" }
  ]
}
```

## Top-level fields

| Field | Type | Default | Description |
|---|---|---|---|
| `negotiation_version` | integer | `1` | Wire/config version, fixed to `1` in v1. Reserved for future **static** per-link transport-mode selection — never an on-wire handshake. |
| `local_tun_mtu` | integer | `1452` | Tunnel MTU. Must be in **68–1500**. The default leaves room for the 64-byte wire overhead on a 1500-byte underlay. |
| `listen_port` | integer | `51820` | Local UDP port the daemon binds for the underlay. |
| `virtual_subnet` | CIDR | `10.0.0.0/24` | The overlay subnet this mesh builds. |
| `local_tun_ip` | CIDR | _(unset)_ | This node's own TUN address (host + prefix), e.g. `10.0.0.2/24`. Used only to emit the [host network plan](network-plan.md); the daemon does **not** configure host addressing itself. |
| `local_id` | integer | `0` | This node's mesh id. Must be **non-zero**, fit a `u16` (`1–65535`), and be distinct from every peer id when `peers` is non-empty. `0` means "single-node / no mesh". |
| `peers` | array | `[]` | The configured mesh peers (fixed capacity, zero-allocation). See [Peer fields](#peer-fields). |
| `role` | string | `"manual"` | `manual`, `hub`, or `spoke`. Controls bootstrap-policy derivation — see [Roles](roles.md). |
| `local_routes` | array of CIDR | `[]` | `role=spoke`: subnets this node delivers **locally** (to its own TUN/host). When empty, `local_tun_ip` (as a `/32`) is used. |
| `remote_routes` | array of CIDR | `[]` | `role=spoke`: subnets reachable **through** the hub. When empty, the spoke routes `virtual_subnet` to the hub. |
| `keepalive_secs` | integer | role default | Built-in spoke→hub NAT keepalive interval. `0` disables it (hub/manual default). A NATed `spoke` defaults to `20`. |

## Peer fields

Each entry of `peers[]`:

| Field | Type | Default | Description |
|---|---|---|---|
| `id` | integer | — | The peer's mesh id (non-zero, `u16`). Used to derive directional link keys and as the on-wire `key_id` selector. |
| `endpoint` | string | — | The peer's underlay address as `host:port`, e.g. `203.0.113.2:51820`. For a hub on dynamic DNS, see the [deployment guide](../operations/deployment.md). |
| `allowed_src` | CIDR | `0.0.0.0/0` | The inner-source range this peer is permitted to send. A decrypted packet whose inner IPv4 source falls outside is dropped (`spoof`). **Set this explicitly** — the permissive default disables anti-spoofing. |
| `psk` | hex string | — | This link's **private** 32-byte pre-shared key (64 hex chars). Required, non-zero, and **unique per link**. Generate with `openssl rand -hex 32`. |
| `name` | string | `""` | Optional human-readable label. Over-long or non-printable values are rejected. |

> **There is no mesh-wide `psk`.** Every link carries its own key. A config that
> still has a top-level `psk` is rejected with `InvalidPsk`; reusing one PSK across
> peers is rejected with `DuplicatePsk`.

## Sanity checks

`config.zig` enforces these at load (and under `--check`); any failure aborts
startup:

- **MTU range:** `local_tun_mtu` must be 68–1500.
- **Subnet overlap:** the virtual subnet must not collide with the host's physical
  subnet in a way that would blackhole traffic.
- **Mesh ids:** `local_id` is non-zero and distinct from every peer id.
- **Unique PSKs:** no PSK is shared across peers (`DuplicatePsk`); no top-level
  `psk` (`InvalidPsk`).
- **Role rules** (see [Roles](roles.md)):
  - `hub` rejects a peer whose `allowed_src` is missing/`0.0.0.0/0` or overlaps
    another peer's `allowed_src`.
  - `spoke` requires exactly one hub peer, at least one local target
    (`local_routes` or `local_tun_ip`), and no `0.0.0.0/0` local route.

## MTU and wire overhead

The fixed per-packet overhead is **64 bytes**: a 20-byte private header + a 16-byte
AEAD tag + 28 bytes of outer IPv4/UDP. The safe tunnel MTU is therefore
`path_mtu − 64`. The default `local_tun_mtu = 1452` assumes a 1500-byte underlay.
On a smaller path (PPPoE, a VPN underlay), lower it — the
[host network plan](network-plan.md) computes and **warns** about this for you.

## Where config meets the rest of the docs

- Bootstrap policy from `role`: **[Roles](roles.md)**.
- Turning config into host commands: **[Host Network Plan](network-plan.md)**.
- What the keys/epoch/`allowed_src` defend against: **[Security Model](../concepts/security-model.md)**.
- Runtime policy injection that overlays this config: **[CLI Reference](../reference/cli.md)**.
