# Observability & Troubleshooting

The data plane drops malformed, unauthenticated, replayed, spoofed, unrouted, or
oversized packets **silently by design** (stealth). `subnetra status` makes those
silent drops **countable**, so you can tell *why* traffic is not flowing without
weakening the stealth property.

## `subnetra status`

```text
subnetrad v0.6.0 [running]
mode=raw_direct local_id=1 udp_port=51820 tun=snr0 peers=2
peers:
  id=2 endpoint=203.0.113.2:51820 allowed_src=10.0.0.2/32
  id=3 endpoint=203.0.113.3:51820 allowed_src=10.0.0.3/32
traffic:
  tun_rx packets=... bytes=...
  udp_tx packets=... bytes=...
  udp_rx packets=... bytes=...
  tun_tx packets=... bytes=...
  relay  packets=... bytes=...
  endpoint_learned=..
  keepalive rx=.. tx=..
drops:
  tun: not_ipv4=.. no_route=.. drop_rule=.. local_loop=.. unknown_target=.. oversized=.. egress_err=.. send_err=..
  udp: unknown_peer=.. auth_or_invalid=.. not_ipv4=.. spoof=.. no_route=.. drop_rule=.. unknown_target=.. no_reflect=.. oversized=.. send_err=..
```

`subnetra status` **exits non-zero** when the daemon is not running, so scripts can
detect it. PSKs and derived keys are **never** printed.

## Reading the drop taxonomy

| Counter | Meaning | Likely cause |
|---|---|---|
| `udp: unknown_peer` | A datagram's header `key_id` matches no configured peer | Wrong mesh id at the sender, or unsolicited traffic |
| `udp: auth_or_invalid` | PSK/epoch or wire format does not match | PSK mismatch, key-rotation skew, clock/epoch issue, or a wire-breaking version gap |
| `udp: spoof` | A peer sent an inner source **outside** its `allowed_src` | Misconfigured `allowed_src`, or actual spoofing |
| `udp: no_route` / `tun: no_route` | No policy rule matches the destination | Missing forward rule / role derivation |
| `udp: no_reflect` | Hub avoided sending a packet back to its source | Normal guard; not an error |
| `tun: not_ipv4` | A non-IPv4 frame appeared on the TUN | IPv6 or other traffic hitting the L3 device |
| `*: oversized` | Packet exceeds the safe MTU | Lower `local_tun_mtu` / add an MSS clamp |

Benign signals: a rising `endpoint_learned` just counts authenticated peers seen at
a new UDP endpoint (roaming / NAT remap). The `keepalive rx` / `tx` line counts the
built-in spoke→hub NAT keepalive: `tx` on the emitting spoke, `rx` on the receiving
hub.

## Machine-readable status (`--json`)

For monitoring and automation, `subnetra status --json` emits the same data as a
stable, **versioned** JSON object — so health can be scraped without parsing
free-form text (and still never serializes secrets):

```bash
subnetra status --json | jq .
```

```jsonc
{
  "schema_version": 1,                 // bumped only on a breaking schema change
  "version": "0.5.1",
  "mode": "raw_direct",
  "local_id": 1,
  "listen_port": 51820,
  "tun": "snr0",
  "peers": [
    {
      "id": 2,
      "endpoint": "203.0.113.7:51822",
      "name": "bj-office-gw",            // optional operator label ("" when unset)
      "allowed_src": "10.66.0.2/32",
      "last_seen_age_seconds": 5,        // null if the peer has never authenticated
      "online": true                     // last_seen within the freshness window (~90s)
    }
  ],
  "counters": { "tun_rx_packets": 3, "udp_tx_packets": 0 /* …every data-plane counter… */ }
}
```

- `online` / `last_seen_age_seconds` give a per-peer heartbeat (the freshness window
  is ~90 s — long enough to tolerate a few missed keepalives without flapping).
- `counters` carries **every** counter from the human view, so a scrape never misses
  a field.
- Pin `schema_version` in your monitor; it increments only on a breaking change.

## Prometheus textfile exporter

There is deliberately **no HTTP server in the daemon** (extra attack surface,
against the single-binary ethos). Instead,
[`deploy/subnetra-textfile-exporter.sh`](https://github.com/jamiesun/subnetra/blob/main/deploy/subnetra-textfile-exporter.sh)
turns `subnetra status --json` into node_exporter **textfile collector** metrics
(the only prerequisite is `jq`):

```bash
sudo install -m 0755 deploy/subnetra-textfile-exporter.sh /usr/local/bin/
sudo install -m 0644 deploy/subnetra-textfile-exporter.service /etc/systemd/system/
sudo install -m 0644 deploy/subnetra-textfile-exporter.timer   /etc/systemd/system/
sudo systemctl enable --now subnetra-textfile-exporter.timer
```

It emits (atomically):

| Metric | Type | Notes |
|---|---|---|
| `subnetra_up` | gauge | `1` if status was read, `0` if down/unbound |
| `subnetra_build_info{version,mode,tun,local_id,listen_port}` | gauge | constant `1`; identity in labels |
| `subnetra_peer_online{id,allowed_src}` | gauge | `1` within the freshness window |
| `subnetra_peer_last_seen_age_seconds{id,allowed_src}` | gauge | omitted if never authenticated |
| `subnetra_<counter>_total` | counter | **every** `counters` field, drift-proof |

Useful alert expressions: `subnetra_up == 0`, `subnetra_peer_online == 0`,
`subnetra_peer_last_seen_age_seconds > 120`, and a climbing
`rate(subnetra_drop_udp_auth_or_invalid_total[5m]) > 0` (PSK/epoch/wire skew) or
`rate(subnetra_drop_udp_spoof_total[5m]) > 0`.

## A troubleshooting checklist

1. **Daemon up?** `subnetra status` (non-zero exit ⇒ down). Check
   `journalctl -u subnetrad`.
2. **Config valid?** `subnetrad --check`.
3. **Peer online?** Look at `online` / `last_seen_age_seconds`.
4. **Large transfers stall but pings work?** MTU/PMTU — recheck the
   [host network plan](../configuration/network-plan.md) and add an MSS clamp.
5. **`auth_or_invalid` climbing?** PSK mismatch, key-rotation skew, a backward
   clock/epoch, or a wire-breaking version gap during a partial upgrade (see
   [Upgrade & Release](upgrade.md)).
6. **`spoof` climbing?** A peer's inner source is outside its `allowed_src`.
7. **`no_route`?** A missing policy rule — check [Roles](../configuration/roles.md)
   or inject one with `subnetra policy add`.
