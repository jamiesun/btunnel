# Quick Start

This walkthrough brings up the smallest useful mesh: **one hub** and **one
spoke**, building a virtual `10.0.0.0/24` overlay. It assumes you have the
`subnetrad` daemon and `subnetra` control tool installed (see
[Installation](installation.md)).

Throughout, the hub is reachable at the public address `203.0.113.1:18020` and
the spoke at `203.0.113.2`.

## 1. Generate a per-link key

Every link needs its **own** 32-byte pre-shared key (64 hex chars). Never reuse
one key across peers.

```bash
openssl rand -hex 32
# e.g. 9f2c…(64 hex chars)…  — use the SAME value in both nodes' configs
```

## 2. Write the configs

The simplest way is to set a [`role`](../configuration/roles.md) and let the
daemon derive the forwarding policy at boot.

**Hub** (`config.json` on `203.0.113.1`):

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "listen_ports": [18020, 18023, 18026],
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:18020", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" }
  ]
}
```

**Spoke** (`config.json` on `203.0.113.2`):

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

The PSK on link 1↔2 must be **identical** in both files. See the
[Configuration Reference](../configuration/reference.md) for every field.

## 3. Validate before running

`--check` parses the config, runs every sanity rule, and exits without touching
the network:

```bash
subnetrad --check --config config.json
# subnetra v… (mtu=1452, udp_ports={ 18020, 18023, 18026 }, mode=raw_direct, local_id=2, peers=1) [config ok]
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

## 5. Start the daemons

```bash
# On the hub and the spoke (TUN creation needs NET_ADMIN / root):
sudo subnetrad --config config.json
```

For a real deployment, run it under systemd or launchd instead — see
[Production Deployment](../operations/deployment.md).

## 6. Verify connectivity

From the spoke, ping the hub's overlay address:

```bash
ping 10.0.0.1
```

Then check the live counters on either node:

```bash
subnetra status
```

You should see `udp_tx` / `udp_rx` climbing and the peer listed as `online`. If
traffic is **not** flowing, the drop counters tell you why — read
[Observability & Troubleshooting](../operations/observability.md).

## 7. Add Site-to-Site routes (optional)

To reach a LAN *behind* a spoke (e.g. `192.168.2.0/24` behind spoke id 3), inject
a policy at runtime — it hot-updates over the control socket with no restart:

```bash
subnetra policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
subnetra policy show
subnetra save              # persist the active policy back to config.json
```

## Where to go next

- **[Roles](../configuration/roles.md)** — auto-derive policy from config.
- **[Architecture](../concepts/architecture.md)** — how the data path works.
- **[Security Model](../concepts/security-model.md)** — keys, epochs, anti-replay.
- **[Production Deployment](../operations/deployment.md)** — services, secrets,
  firewall/NAT, upgrades.
