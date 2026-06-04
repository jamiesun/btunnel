# BTunnel production deployment guide

This guide deploys a public **Hub** and two NATed **Spokes** so that hosts on the
spokes' private LANs can reach each other through the Hub relay. BTunnel ships as
a single static binary with no runtime dependencies, so deployment is mostly
about config, capabilities, and host networking.

For MikroTik/RouterOS Container deployments, read
[`routeros-container.md`](routeros-container.md) in addition to this guide. The
RouterOS model needs dedicated veth routing and container-side forwarding.

> Topology (v1): single-hub hub-and-spoke. The Hub relays between spokes; spokes
> do not relay. Peer **identity** is the per-peer PSK selected by the header
> `key_id` (issue #34), not the source endpoint: a spoke's UDP endpoint is the
> configured **bootstrap** value but is re-learned at runtime once an
> authenticated datagram arrives, so a NATed/roaming spoke recovers without
> operator action. The Hub must still have a stable, reachable endpoint that
> every spoke can reach.

## 0. Components

| Node     | Mesh id | Overlay IP   | Underlay endpoint     | Private LAN        |
|----------|---------|--------------|-----------------------|--------------------|
| Hub      | 1       | (relay only) | `203.0.113.1:51820`   | —                  |
| Spoke A  | 2       | `10.0.0.2/24`| behind NAT            | `192.168.10.0/24`  |
| Spoke B  | 3       | `10.0.0.3/24`| behind NAT            | `192.168.31.0/24`  |

Example configs live next to this guide:
[`deploy/hub.json`](../deploy/hub.json),
[`deploy/spoke-a.json`](../deploy/spoke-a.json),
[`deploy/spoke-b.json`](../deploy/spoke-b.json).

## 1. Install the binary

Build (or download a release) and install the static binary plus the control
tool:

```bash
zig build -Doptimize=ReleaseSmall
sudo install -m 0755 zig-out/bin/btunnel /usr/local/bin/btunnel
sudo install -m 0755 zig-out/bin/ptctl  /usr/local/bin/ptctl
```

`ldd /usr/local/bin/btunnel` should report *not a dynamic executable*.

## 2. Provision per-node config and secrets

Each **link** between the Hub and a Spoke has its **own** private PSK (a single
shared mesh key is rejected). Generate one 32-byte key per link:

```bash
openssl rand -hex 32   # 64 hex chars; run once per Hub<->Spoke link
```

- Link Hub(1)<->Spoke A(2): the SAME value goes in the Hub's `peers[id=2].psk`
  and Spoke A's `peers[id=1].psk`.
- Link Hub(1)<->Spoke B(3): a DIFFERENT value, in the Hub's `peers[id=3].psk`
  and Spoke B's `peers[id=1].psk`.

Reusing one PSK across links is rejected (`DuplicatePsk`); a missing or non-hex
PSK is rejected (`InvalidPsk`). The example configs contain obviously-fake
placeholder keys (`aaaa…`, `bbbb…`) **only so they pass `--check`** — replace
every one before deploying.

Install each node's config as `/etc/btunnel/config.json`:

```bash
sudo mkdir -p /etc/btunnel
sudo install -m 0600 -o root -g root deploy/spoke-a.json /etc/btunnel/config.json
```

> **Secrets handling (required):** config files carry private PSKs. They MUST be
> root-owned and `0600` (not world-readable). `/etc/btunnel` itself should be
> `0700`. Never commit a real config to source control.

Validate before starting:

```bash
sudo btunnel --check --config /etc/btunnel/config.json
# btunnel v… (mtu=1400, udp_port=51820, mode=raw_direct, local_id=2, peers=1) [config ok]
```

`--config` is optional; without it the daemon reads `./config.json` from its
working directory (or `$BTUNNEL_CONFIG`). `btunnel --version` and `btunnel --help`
work without a config; an unrecognized flag is rejected rather than ignored.

## 3. Host networking

btunnel creates the TUN device but **prints** (never applies) the host setup, so
you keep the zero-dependency guarantee and stay in control of routing. Generate
the plan per node:

```bash
sudo btunnel --print-network-plan           # assumes a 1500-byte underlay
sudo btunnel --print-network-plan --path-mtu 1420   # e.g. behind PPPoE/another VPN
```

Apply the printed `ip` commands (or paste them into the `ExecStartPost` hooks of
the systemd unit). The plan also reports the **safe tunnel MTU** for the path and
warns if `local_tun_mtu` is too large — fixing that prevents the classic
"small packets work, large transfers stall" failure. To let LAN-to-LAN TCP
survive a smaller path MTU, apply the printed MSS-clamp rule.

For LAN-to-LAN reachability you typically also enable forwarding and route the
remote LAN via the overlay on each spoke:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
# On Spoke A, reach Spoke B's LAN through the tunnel:
sudo ip route add 192.168.31.0/24 dev btun0
```

## 4. Run as a service

Install the unit and start the daemon:

```bash
sudo install -m 0644 deploy/btunnel.service /etc/systemd/system/btunnel.service
sudo systemctl daemon-reload
sudo systemctl enable --now btunnel
```

The unit requests only `CAP_NET_ADMIN`, grants `/dev/net/tun`, runs
`btunnel --check` as `ExecStartPre`, restarts on failure, and is otherwise
sandboxed (`ProtectSystem=strict`, `NoNewPrivileges`, restricted address
families, etc.). Edit the commented `ExecStartPost` lines to match your
`--print-network-plan` output.

Logs go to the journal:

```bash
journalctl -u btunnel -f
```

## 5. Install the relay policy (Hub)

> **Shortcut (recommended):** the example configs in [`../deploy/`](../deploy/)
> set `"role": "hub"` / `"role": "spoke"`, so the daemon **derives this entire
> policy from config at boot** — you can skip this whole section. See
> [README → Roles](../README.md#roles-auto-derive-the-policy-from-config-role).
> The manual steps below apply to `"role": "manual"` configs, or when you want to
> layer extra rules on top of a derived table.

The Hub starts with an empty policy tree; install the relay/delivery rules at
runtime over the local control socket (hot-swapped, no restart). Set
`BTUNNEL_SOCK` to match the unit (`/run/btunnel/btunnel.sock`):

```bash
export BTUNNEL_SOCK=/run/btunnel/btunnel.sock
# Deliver/relay overlay traffic to the right spoke:
sudo -E ptctl policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2
sudo -E ptctl policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 3
sudo -E ptctl policy show
sudo -E ptctl save        # persist a replayable snapshot
```

On each Spoke, deliver tunnelled traffic destined for the local overlay address
to the local TUN (target `0` = local):

```bash
export BTUNNEL_SOCK=/run/btunnel/btunnel.sock
sudo -E ptctl policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0
```

## 6. Inspect, troubleshoot, upgrade

```bash
sudo -E ptctl status      # peers, traffic counters, and per-reason drop counters
```

`ptctl status` exits non-zero if the daemon is down. Rising drop counters point
straight at the cause: `unknown_peer` (header `key_id` matches no configured
peer), `auth_or_invalid` (PSK/epoch/wire mismatch), `spoof` (inner source outside
`allowed_src`), or `no_route` (no matching policy). The `endpoint_learned`
counter rises whenever an authenticated peer is observed at a new UDP endpoint
(roaming/NAT remap — see issue #34). PSKs are never printed.

**Upgrade / rollback:** install the new binary and restart; the on-wire format is
versioned and the data path is stateless across restarts (a fresh session epoch
is derived each lifetime). To roll back, reinstall the previous binary and
restart. Re-apply the saved policy snapshot if needed.

```bash
sudo install -m 0755 zig-out/bin/btunnel /usr/local/bin/btunnel
sudo systemctl restart btunnel
```

> **Time synchronization (required).** The fresh-epoch-per-restart property above
> relies on a sane wall clock: the session key is derived from a boot epoch
> sampled from `CLOCK_REALTIME` at startup, and a receiver orders sessions
> **forward-only** (a newer epoch supersedes an older one). The daemon fails
> closed if the clock reads earlier than 2024-01-01, but it **cannot** detect a
> clock that runs *backward across a restart*. If a node restarts with a wall
> clock earlier than its previous boot (e.g. no battery-backed RTC and NTP has
> not synced yet), its new, lower epoch is rejected by every peer until their
> clocks advance past the old value — the link silently blackholes and the peer's
> `auth_or_invalid` drop counter (above) climbs. **Mitigation:** run a time
> daemon (`chrony` / `systemd-timesyncd`); on hardware without an RTC, order
> `btunnel.service` after `time-sync.target` (`After=time-sync.target` +
> `Wants=time-sync.target`) so the clock is monotonic across restarts. If a clock
> did jump backward, restart **both** ends of the affected link to force a fresh
> epoch on each side. This is an accepted, permanent trade-off of the
> stateless, handshake-free transport (iron law #8): there is no in-protocol
> epoch exchange to repair it, so the fix is operational (keep the clock synced).

## 7. Firewall / NAT requirements

- The **Hub** must accept inbound UDP on its `listen_port` (default `51820`) from
  the internet.
- Each **Spoke** only needs **outbound** UDP reachability to the Hub's
  `ip:port`; no inbound port-forwarding is required (the spoke initiates).
- If a spoke's NAT mapping changes, the Hub re-learns the spoke's new endpoint
  from its next authenticated datagram (issue #34), so replies follow it
  automatically. Keep the **Hub** endpoint stable; spokes always initiate.

## 8. Cross-ISP / cross-region traffic shaping (运营商跨区整形)

On long, cross-ISP or cross-region links, the dominant cause of jitter and loss is
**not** that the tunnel is "detected" — it is the underlay: ISP interconnect
congestion, last-mile queueing, single-flow rate caps, and bursty UDP. BTunnel is
intentionally a **stateless, handshake-free, allocation-free data plane** (iron
laws #2, #3, #8): it does **not** ship an in-tunnel scheduler, an adaptive rate
controller, or an auto-switching path manager, and it never will. All of the
shaping below is done **at the OS layer with `tc`** and standard kernel tooling —
**no daemon changes, no protocol changes**. The kernel already sees the real inner
five-tuples on the cleartext `btun0` device, so let it do the work it is good at.

> Everything here is **optional host tuning**. Measure first (Section 6,
> `ptctl status` drop counters and the counters your monitoring scrapes), change
> one thing at a time, and keep a rollback. Do not enable all of it blindly.

**1. Cap the egress, don't let the ISP cap it for you.** A tunnel that fires UDP
at line rate looks exactly like the thing carrier QoS punishes. Shape your own
egress to ~60–80% of the link's *stable* throughput (measure it; don't trust the
sales figure). For a link that holds ~80 Mbit/s, start at 50–60 Mbit/s:

```bash
# Smooth bursts and pin a precise rate on the physical uplink.
sudo tc qdisc replace dev eth0 root tbf rate 60mbit burst 512k latency 80ms
```

**2. Fair-queue per flow so bulk traffic can't starve interactive traffic.**
Apply this on the **inner** device (`btun0`), where the kernel can see each real
flow (DNS, SSH, RDP, an HTTP API call, a backup) — not on the outer UDP socket,
where everything collapses into one flow:

```bash
sudo tc qdisc replace dev btun0 root fq_codel target 5ms interval 100ms limit 2000
```

On a home/branch gateway doing the egress shaping itself, CAKE is a good
single-qdisc alternative (it integrates shaping + AQM + fair queueing):

```bash
sudo tc qdisc replace dev eth0 root cake bandwidth 60mbit
```

This — kernel fair-queueing on the cleartext device — is the correct home for
per-flow prioritisation. It replaces any "in-tunnel QoS scheduler": the OS already
understands the flows, so BTunnel must not duplicate `tc` inside the data plane.

**3. Be conservative with MTU, and clamp MSS.** Stacked PPPoE / cloud VPC / bridge
hops plus BTunnel's own outer IP/UDP + AEAD overhead shrink the usable MTU. Don't
start at 1500. Use the daemon's own plan (Section 3) — it prints the safe tunnel
MTU **and** the MSS-clamp rule for the path:

```bash
sudo btunnel --print-network-plan --path-mtu 1280   # raise once it proves stable
```

If small packets pass but large transfers stall, this is almost always the cause.

**4. Don't expect the public path to honour your DSCP.** You may mark interactive
traffic inside your own LAN, but carriers frequently zero, ignore, or mis-route
odd DSCP marks. Normalise (clear) DSCP on the public egress and keep prioritisation
local to the host queues above:

```bash
sudo iptables -t mangle -A POSTROUTING -o eth0 -j DSCP --set-dscp 0
```

**5. Multi-path, if you need it, stays static and stateless.** Prefer
**same-ISP** Hub placement and per-region Hubs over one national Hub straining a
saturated backbone — but express that as **static per-link / per-spoke config and
routing**, chosen by the operator (or `ptctl`), **not** as an in-protocol health
probe or auto-failover state machine inside the daemon (iron law #8). If you fan a
link across multiple endpoints, hash by the **inner five-tuple** so a single TCP
connection always rides one path; never stripe one connection's packets across
paths — reordering wrecks TCP congestion control.

**6. Reliability (KCP/FEC) is a v2, static-config option — not a default.** FEC
redundancy can paper over mild loss, but on an already-congested or QoS'd link it
adds traffic and can make things worse. It is selected by static per-link config
only (iron law #8 / Section "v1 vs v2" in `AGENT.md`), never negotiated, never on
by default.

**Diagnosing which knob to turn (read the counters first):**

- RTT steady but throughput capped → rate limiting or a single-flow bottleneck
  (Section item 1/5).
- RTT p95 spikes under load → queueing/congestion (item 2).
- Large packets dropped, small ones fine → MTU (item 3).
- Same-ISP fine, cross-ISP bad → it's the **path**, not the protocol — move the
  Hub closer (item 5), not into the code.
- Bad at night, fine by day → a congestion window, not a regression.
