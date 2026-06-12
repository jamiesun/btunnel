# Quick Start

This walkthrough brings up the smallest *useful* mesh: **one hub** and **two
spokes**, building a virtual `10.0.0.0/24` overlay. Two spokes is what makes the
hub earn its name — it **relays** traffic between the spokes, which never talk to
each other directly. It assumes you have the `subnetrad` daemon and `subnetra`
control tool installed (see [Installation](installation.md)).

Throughout: the hub is at the public address `203.0.113.1:18020`, spoke **A**
(overlay `10.0.0.2`) at `203.0.113.2`, and spoke **B** (overlay `10.0.0.3`) at
`203.0.113.3`.

## 1. Generate a per-link key

Every link needs its **own** 32-byte pre-shared key (64 hex chars). Never reuse
one key across peers — so this two-link mesh needs **two** keys:

```bash
openssl rand -hex 32   # → KEY_A, for the hub ↔ spoke-A link
openssl rand -hex 32   # → KEY_B, for the hub ↔ spoke-B link
```

## 2. Write the configs

The simplest way is to set a [`role`](../configuration/roles.md) and let the
daemon derive the forwarding policy at boot.

**Hub** (`config.json` on `203.0.113.1`) — lists both spokes:

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "listen_ports": [18020, 18023, 18026],
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:18020", "allowed_src": "10.0.0.2/32", "psk": "…KEY_A…" },
    { "id": 3, "endpoint": "203.0.113.3:18020", "allowed_src": "10.0.0.3/32", "psk": "…KEY_B…" }
  ]
}
```

**Spoke A** (`config.json` on `203.0.113.2`):

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…KEY_A…" }
  ]
}
```

**Spoke B** (`config.json` on `203.0.113.3`) — same shape, its own id and address:

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 3,
  "local_tun_ip": "10.0.0.3/24",
  "local_routes": ["10.0.0.3/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…KEY_B…" }
  ]
}
```

Each **link** carries its own PSK: `KEY_A` is shared by the hub's peer 2 and
spoke A; `KEY_B` by the hub's peer 3 and spoke B — and the two keys differ. The
spokes need no `listen_ports` (a `spoke` binds the single default port). See the
[Configuration Reference](../configuration/reference.md) for every field.

## 3. Validate before running

`--check` parses the config, runs every sanity rule, and exits without touching
the network:

```bash
subnetrad --check --config config.json
# spoke A: subnetra v… (mtu=1452, udp_ports={ 18020 }, mode=raw_direct, local_id=2, peers=1) [config ok]
# hub:     subnetra v… (mtu=1452, udp_ports={ 18020, 18023, 18026 }, mode=raw_direct, local_id=1, peers=2) [config ok]
```

## 4. Print and apply the host network plan

The daemon creates the TUN device but **does not** configure host addressing,
routes, or MTU (that would break the zero-dependency guarantee). Ask it to print
the exact commands instead:

```bash
subnetrad --print-network-plan --config config.json
```

Review the emitted `ip link` / `ip addr` / `ip route` commands and run them (on
macOS the plan emits `ifconfig` / `route`). See
[Host Network Plan](../configuration/network-plan.md) for details, including how
the safe MTU is computed.

Run this on **each spoke**. The hub has no `local_tun_ip`, so its plan only
creates the bare TUN device — it is a pure relay with no overlay address.

## 5. Start the daemons

```bash
# On the hub and both spokes (TUN creation needs NET_ADMIN / root):
sudo subnetrad --config config.json
```

For a real deployment, run it under systemd or launchd instead — see
[Production Deployment](../operations/deployment.md).

## 6. Verify connectivity

From **spoke A**, ping **spoke B** — the packet goes `A → hub → B` and back,
exercising the hub relay:

```bash
ping 10.0.0.3
```

Then check the live counters on any node:

```bash
subnetra status
```

On the spokes you should see `udp_tx` / `udp_rx` climbing and the peer `online`;
on the hub the `relay_*` counters increment as it forwards between the spokes. If
traffic is **not** flowing, the drop counters tell you why — read
[Observability & Troubleshooting](../operations/observability.md).

> The hub here is a **pure relay** with no overlay address, so there is nothing at
> `10.0.0.1` to ping. To make the hub itself reachable, see
> [Roles → Reaching the hub itself](../configuration/roles.md#reaching-the-hub-itself).

## 7. Add Site-to-Site routes (optional)

To reach a LAN *behind* spoke B (e.g. `192.168.3.0/24`), the **hub** needs a relay
rule for that prefix. Inject it at runtime — it hot-updates over the control
socket with no restart:

```bash
# On the hub:
subnetra policy add --src 0.0.0.0/0 --dst 192.168.3.0/24 --action forward --target 3
subnetra policy show
subnetra save              # persist the active policy back to config.json
```

Spoke B must also deliver that prefix locally (add it to `local_routes`) and be
allowed to source it (widen peer 3's `allowed_src` on the hub to cover it). The
full Site-to-Site walkthrough is in [Production Deployment](../operations/deployment.md).

## Where to go next

- **[Roles](../configuration/roles.md)** — auto-derive policy from config.
- **[Architecture](../concepts/architecture.md)** — how the data path works.
- **[Security Model](../concepts/security-model.md)** — keys, epochs, anti-replay.
- **[Production Deployment](../operations/deployment.md)** — services, secrets,
  firewall/NAT, upgrades.
