# Production Deployment

This page condenses the full hub + two-spoke production walkthrough. For the
exhaustive version — including traffic shaping, NIC tuning, and benchmarking — see
[`docs/deployment.md`](https://github.com/jamiesun/subnetra/blob/main/docs/deployment.md)
in the repository. Ready-to-edit artifacts live in
[`deploy/`](https://github.com/jamiesun/subnetra/tree/main/deploy)
(`subnetrad.service`, `net.subnetra.subnetrad.plist`, `hub.json`, `spoke-a.json`,
`spoke-b.json`).

## 0. Components

A deployment has one **hub** (stable public UDP endpoint) and one or more
**spokes** (outbound-only, often behind NAT). Each runs the same `subnetrad`
daemon and `subnetra` control tool; the difference is configuration
([Roles](../configuration/roles.md)).

## 1. Install the binary

Use a [release tarball or container image](../getting-started/installation.md). On
a bare host:

```bash
sudo install -m 0755 subnetrad subnetra /usr/local/bin/
```

## 2. Provision config and secrets

Place `config.json` where the service expects it (the units use
`/etc/subnetra/config.json`), owned by root and mode `0600` because it contains
PSKs:

```bash
sudo install -d -m 0750 /etc/subnetra
sudo install -m 0600 hub.json /etc/subnetra/config.json
subnetrad --check --config /etc/subnetra/config.json
# subnetra v… (mtu=…, mode=raw_direct, local_id=…, peers=…) [config ok]
```

Generate each link's PSK with `openssl rand -hex 32` and use a **unique** value per
link. See the [Security Model](../concepts/security-model.md).

## 3. Host networking

The daemon prints — but never applies — the host plan. Review and run it (see
[Host Network Plan](../configuration/network-plan.md)):

```bash
subnetrad --print-network-plan --config /etc/subnetra/config.json
```

## 4. Run as a service

### Linux — systemd

```bash
sudo install -m 0644 deploy/subnetrad.service /etc/systemd/system/subnetrad.service
sudo systemctl daemon-reload
sudo systemctl enable --now subnetrad
journalctl -u subnetrad -f
```

The unit requests only `CAP_NET_ADMIN`, grants `/dev/net/tun`, runs
`subnetrad --check` as `ExecStartPre`, restarts on failure, and is otherwise
sandboxed (`ProtectSystem=strict`, `NoNewPrivileges`, restricted address families).
Edit the commented `ExecStartPost` lines to match your `--print-network-plan`
output.

### macOS — launchd

A macOS **spoke** runs as a system daemon (creating a `utun` needs root):

```bash
sudo install -m 0644 deploy/net.subnetra.subnetrad.plist \
    /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl enable system/net.subnetra.subnetrad
sudo tail -f /var/log/subnetrad.log
# subnetra v… (… mode=raw_direct …) tun=utun4 sock=/var/run/subnetra.sock [ready]
```

The `utunN` name is kernel-assigned — read it from the `[ready]` banner and apply
the plan **after** the daemon is up. See the [macOS Spoke](macos-spoke.md) guide.

## 5. Install the relay policy (hub)

> **Shortcut:** if your config sets `"role": "hub"` / `"spoke"`, the daemon
> **derives this whole policy at boot** and you can skip this section. See
> [Roles](../configuration/roles.md).

For `role=manual`, install the relay/delivery rules at runtime over the control
socket (hot-swapped, no restart). Match `SUBNETRA_SOCK` to the unit:

```bash
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
# Hub: relay overlay traffic to the right spoke
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 3
sudo -E subnetra policy show
sudo -E subnetra save        # persist a replayable snapshot

# Spoke: deliver tunnelled traffic for the local overlay address to the local TUN (target 0)
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0
```

## 6. Operate

`subnetra status` shows peers, traffic, and per-reason drops; `--json` is the
stable schema for monitoring. See
[Observability & Troubleshooting](observability.md).

## 7. Firewall / NAT

- The **hub** must accept inbound UDP on its `listen_port` (default `51820`) from
  the internet.
- Each **spoke** needs only **outbound** UDP reachability to the hub — no inbound
  port-forwarding (the spoke initiates).
- If a spoke's NAT mapping changes, the hub re-learns its new endpoint from the
  next authenticated datagram. Keep the **hub** endpoint stable; spokes always
  initiate.

### NAT keepalive (built-in)

An idle spoke's NAT mapping times out (often ~30 s for UDP), after which inbound
relays would blackhole. A `role=spoke` runs a **built-in keepalive** by default
(`keepalive_secs = 20`): one tiny authenticated datagram per interval holds the
pinhole open and keeps the hub's learned endpoint fresh. It is allocation-free and
adds no thread or external process. Confirm it with the `keepalive tx` / `keepalive
rx` counters. Set `keepalive_secs = 0` to disable (e.g. a spoke not behind NAT).

### Hub on a dynamic IP (DDNS)

Endpoints are numeric `IP:port` and endpoint learning is one-way — a spoke cannot
discover a hub that moved. Prefer a **stable public IP** for the hub. If you must
run it behind a dynamic address, solve it operationally on each spoke with a small
DDNS watcher that rewrites the endpoint and restarts the (stateless) daemon — no
daemon changes.

## 8. High availability

v1 is **single-hub** by design; failover is made **outside** the daemon (the data
plane stays single-path, stateless, handshake-free):

- **Pattern A — shared hub VIP.** Two hub instances behind one VRRP/`keepalived`
  VIP or anycast prefix, indistinguishable to spokes (same `local_id`, same
  per-spoke PSKs, same policy). Mind the **epoch caveat**: a takeover hub must not
  present a *lower* boot epoch than spokes last accepted — keep both on NTP, and
  prefer active/standby where the standby is (re)started at takeover.
- **Pattern B — static multi-hub.** Two fully independent hubs with distinct
  `local_id` and distinct PSKs; each spoke lists both as peers and an **external**
  mechanism (route metric, split prefixes, operator script) picks the path.

Drive any switch from the **observe-only** health in `subnetra status --json`
(`online`, `last_seen_age_seconds`, a flat `auth_or_invalid`). The daemon makes no
failover decision itself.

## 9. Traffic shaping & tuning

On long cross-ISP links the dominant cause of jitter/loss is the **underlay**, not
detection. All shaping is done at the OS layer with `tc` — no daemon or protocol
changes. Cap your egress to ~60–80% of the link's *stable* throughput, smooth
bursts, and (optionally) tune socket buffers and IRQ/CPU affinity. The kernel sees
the real inner five-tuples on the cleartext `snr0` device. See
[`docs/deployment.md` §9–§10](https://github.com/jamiesun/subnetra/blob/main/docs/deployment.md)
for the full recipes and the live-overlay benchmark.
