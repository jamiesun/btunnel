# Exit Node & Outbound

Subnetra is a **Layer-3 encrypted channel**, not a proxy or a rule engine. It
does not parse domains, resolve DNS, or match GeoIP — by
[design](../concepts/design-principles.md) those belong in tools built for them.
What it does well is carry traffic, fully encrypted and NAT-traversed, to a spoke
that has the network access you want. That spoke is the **exit**, and a small
proxy on it turns the mesh into a clean outbound.

The recipe is deliberately simple: run a SOCKS5 proxy on the exit spoke, bound to
its overlay IP, and point a rule-capable client (Shadowrocket, mihomo, sing-box)
at it. Subnetra is *only* the secure channel that reaches the proxy; the client
decides which destinations take the exit.

> **Why not build the rules into Subnetra?** In-daemon DNS, an L7 router, and a
> path manager are explicit [non-goals](../reference/roadmap.md#explicit-non-goals).
> Choosing destinations by domain is a DNS + L7 job; keep that in a mature client
> and let Subnetra be the transport underneath.

## Topology

```
rule-engine client ─► spoke A ─► hub ─► exit spoke B ─► internet
 (e.g. Shadowrocket)  (10.0.0.2) (relays) (10.0.0.3)      (B's uplink)
```

The hub **relays** A ↔ B (spokes never relay each other directly). Only B needs
the target access; the client reaches it through B. The device running the client
reaches B's overlay IP (`10.0.0.3`) through its local spoke A — A itself, or a
host on A's LAN with the overlay routed to it.

## 1. Run a SOCKS5 proxy on the exit spoke

Run a small SOCKS5 server on B, bound to **B's overlay IP** so it is reachable
*only* through the mesh, never on B's public NIC. [zsocks](https://github.com/jamiesun/zsocks)
is a tiny zero-dependency SOCKS5 server (also Zig, same philosophy as Subnetra —
a single static binary, bounded memory, TCP `CONNECT` + UDP `ASSOCIATE`, optional
auth):

```bash
# Bind to the overlay IP only and require username/password auth.
zsocks --listen 10.0.0.3 --port 1080 --user alice --pass <secret>
```

Useful flags (see `zsocks --help`):

| Flag | Purpose |
|---|---|
| `-l, --listen <host>` | Bind address — set to B's overlay IP (`10.0.0.3`) |
| `-p, --port <port>` | Listen port (default `1080`) |
| `-u/-P, --user/--pass` | Enable RFC1929 auth (recommended) |
| `--max-conns <n>` | Cap concurrent connections (default 256) |
| `--no-udp` | TCP only; drop UDP `ASSOCIATE` if you don't need it |
| `--udp-advertise <h>` | UDP relay address — leave default; the overlay IP is directly reachable |

UDP `ASSOCIATE` is supported, so QUIC / HTTP-3 apps work; the advertised UDP relay
address defaults to the listen host (`10.0.0.3`), which is directly reachable over
the overlay, so `--udp-advertise` is not needed here.

Because the proxy binds to the overlay address, all traffic to it stays inside the
encrypted mesh and every overlay packet keeps proper overlay source/destination
IPs — so the hub's per-peer `allowed_src` anti-spoofing stays intact. There is no
`ip_forward` and no masquerade: the proxy re-originates connections from B, and the
return path is just its own sockets.

## 2. Point a rule engine at it

On the client, send only the destinations you choose through the exit. Below is
Shadowrocket / Surge config format; mihomo and sing-box are equivalent. The
example routes a well-known international music streaming service (Spotify) through
the exit and leaves everything else direct:

```
[Proxy]
via-exit = socks5, 10.0.0.3, 1080, alice, <secret>

[Rule]
DOMAIN-SUFFIX,spotify.com,via-exit
DOMAIN-SUFFIX,scdn.co,via-exit
FINAL,DIRECT
```

mihomo equivalent:

```yaml
proxies:
  - name: via-exit
    type: socks5
    server: 10.0.0.3        # exit spoke B's overlay IP — only reachable via Subnetra
    port: 1080
    username: alice
    password: <secret>
rules:
  - DOMAIN-SUFFIX,spotify.com,via-exit
  - DOMAIN-SUFFIX,scdn.co,via-exit
  - MATCH,DIRECT
```

Everything not matched stays direct (split-tunnel), so only the chosen
destinations take the `A → hub → B` path.

## DNS

Domain rules still need names to resolve from the right vantage point: if the
client resolves locally it may get endpoints local to A's region. Let the client
resolve DNS through the exit (Shadowrocket's proxied DNS, or mihomo `fake-ip` with
the resolver reached via the proxy) so matched names resolve from B's location.

## Cautions

- **B is the exit.** Its IP carries the client's traffic — real responsibility for
  whoever runs B, which can see destination metadata (SNI, DNS) even though the TLS
  *payload* stays end-to-end encrypted. Always enable proxy auth and bind to the
  overlay IP only.
- **Double hop.** Traffic goes `client → A → hub → B → target` and back: added
  latency, and the hub now carries this bandwidth — shape it (see
  [Production Deployment → Traffic shaping](deployment.md#9-traffic-shaping--tuning)).
- **MTU stacks.** You are tunnelling inside a tunnel; size the inner MTU with the
  [Host Network Plan](../configuration/network-plan.md) guidance.

## Verify

```bash
# Through the exit proxy — the IP returned should be B's public IP:
curl -s --socks5-hostname alice:<secret>@10.0.0.3:1080 https://api.ipify.org ; echo

# On the hub — relay counters climb as the traffic flows through:
subnetra status --json | grep relay_
```
