# Exit Node & Outbound

Subnetra is a **Layer-3 encrypted channel**, not a proxy or a rule engine. It
does not parse domains, resolve DNS, or match GeoIP — by
[design](../concepts/design-principles.md) those belong in tools built for them.
What Subnetra does well is carry traffic, fully encrypted and NAT-traversed, to a
spoke that has the internet access you want. That spoke is the **exit**.

This page shows two ways to send a node's internet traffic out through another
spoke, and where the "routing brain" (domain/GeoIP rules, DNS) should live.

> **Why not put the rules in Subnetra?** In-daemon DNS, an L7 router, and a path
> manager are explicit [non-goals](../reference/roadmap.md#explicit-non-goals).
> Domain-based split-tunnelling is fundamentally a DNS + L7 problem; keep that
> layer in a mature tool and let Subnetra be the transport underneath it.

## Topology

```
client spoke A ──► hub ──► exit spoke B ──► internet
  (10.0.0.2)     (relays)   (10.0.0.3,        (B's clean
  wants x.com               clean uplink)      public IP)
```

The hub **relays** A ↔ B (spokes never relay each other directly). B is the only
node that needs unrestricted internet; A reaches the internet *through* B.

## Which pattern?

| | Pattern B — proxy outbound *(recommended)* | Pattern A — L3 exit (masquerade) |
|---|---|---|
| Split by **domain/GeoIP** | ✅ yes (rule engine) | ❌ IP/CIDR only |
| Handles DNS pollution | ✅ yes (fake-ip / DoH) | ❌ you must fix DNS separately |
| Extra software on B | a small SOCKS/HTTP proxy | none (kernel only) |
| Anti-spoofing on the hub | ✅ stays intact | ⚠️ must widen B's `allowed_src` to `0.0.0.0/0` |
| Return path | trivial (proxy re-originates) | needs source = overlay IP |
| Best for | real "by-site" routing | full-tunnel / coarse CIDR egress |

## Pattern B — Rule-based outbound (recommended)

Run a proxy on the exit spoke, **bound to its overlay IP**, and point a rule
engine (mihomo / sing-box / Clash) on the client at it. Subnetra is *only* the
secure channel that reaches the proxy; the rule engine owns domains and DNS.

**On exit spoke B** — run any small SOCKS5/HTTP proxy (e.g. `microsocks`, `gost`,
`3proxy`, or sing-box/mihomo as a `socks` inbound), listening on **B's overlay
address** so it is reachable *only* through the mesh, never on B's public NIC:

```bash
# Example: microsocks bound to the overlay IP only
microsocks -i 10.0.0.3 -p 1080
# Firewall: make sure 1080 is NOT exposed on the public uplink (eth0).
```

**On client A** — mihomo (`config.yaml`), using the overlay address as the proxy:

```yaml
proxies:
  - name: via-exit
    type: socks5
    server: 10.0.0.3        # exit spoke B's OVERLAY ip — only reachable via Subnetra
    port: 1080

rules:
  - DOMAIN-SUFFIX,x.com,via-exit
  - GEOIP,CN,DIRECT
  - MATCH,DIRECT            # everything else stays direct (split-tunnel)

dns:
  enable: true
  enhanced-mode: fake-ip    # resolve matched domains to fake IPs, route by rule
  nameserver:
    - https://1.1.1.1/dns-query   # clean resolver, itself reached via the proxy
```

sing-box is equivalent: a `socks` outbound to `10.0.0.3:1080`, `route` rules by
domain/GeoIP, and a `fake-ip` DNS server.

**Why this is the clean composition**

- All overlay packets carry proper **overlay** source/destination IPs, so the
  hub's per-peer `allowed_src` anti-spoofing stays tight — nothing to widen.
- The proxy on B **re-originates** connections to the internet, so there is no
  `ip_forward`, no masquerade, and the return path is just the proxy's own
  sockets.
- The rule engine owns the hard parts — domains, **DNS pollution** (fake-ip /
  DoH), and rule-set refresh — which is exactly the layer Subnetra should not
  reimplement.

## Pattern A — L3 exit node (kernel masquerade)

Dependency-free: route a CIDR (or everything) into the overlay and let B's kernel
masquerade it to the internet. Good for full-tunnel or coarse IP/CIDR egress.
**Not domain-aware**, and it requires loosening one security control (below).

**On exit spoke B** — enable forwarding and masquerade the overlay out the uplink:

```bash
sudo sysctl -w net.ipv4.ip_forward=1          # persist in /etc/sysctl.d/
UPLINK=eth0; OVERLAY=10.0.0.0/24; TUN=snr0     # TUN = the [ready] banner's tun=…
sudo iptables -t nat -A POSTROUTING -s "$OVERLAY" -o "$UPLINK" -j MASQUERADE
sudo iptables -A FORWARD -i "$TUN"  -s "$OVERLAY" -j ACCEPT
sudo iptables -A FORWARD -o "$TUN"  -d "$OVERLAY" -j ACCEPT
```

B's return packets carry **internet** source IPs (e.g. `1.2.3.4`), so the hub's
inner-source check would drop them unless B is allowed to source any address. In
the **hub's** config, set the peer entry for B to:

```json
{ "id": 3, "allowed_src": "0.0.0.0/0", "...": "..." }
```

> ⚠️ This **disables inner-source anti-spoofing for B**. Only do it for a node you
> fully trust as an exit; B can now inject packets claiming any source.

**On the hub** — send all non-overlay traffic to B. Longest-prefix match means the
existing overlay `/32` delivery rules still win, so only internet-bound traffic
hits the catch-all:

```bash
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 0.0.0.0/0 --action forward --target 3
sudo -E subnetra save        # persist the replayable snapshot
```

**On client A** — route the traffic you want exited into the TUN. For a specific
destination set:

```bash
sudo ip route add 198.51.100.0/24 dev snr0     # this CIDR exits via B
```

For a **full tunnel**, override the default with two `/1` routes and pin the hub's
public IP to the physical gateway so the tunnel itself stays reachable:

```bash
sudo ip route add 0.0.0.0/1   dev snr0
sudo ip route add 128.0.0.0/1 dev snr0
sudo ip route add <HUB_PUBLIC_IP>/32 via <PHYSICAL_GATEWAY>
```

If A is a **LAN gateway** forwarding other hosts, masquerade LAN → overlay so the
source becomes A's overlay IP (otherwise B's replies to a private LAN address
cannot route back through the mesh):

```bash
sudo iptables -t nat -A POSTROUTING -o snr0 -j MASQUERADE
```

**Return path:** `A(10.0.0.2)→hub→B`; B masquerades to its public IP and sends to
the internet; the reply hits B, conntrack un-NATs it back to `10.0.0.2`, B sends
it into the overlay, the hub relays `dst 10.0.0.2/32 → A`. It works because the
traffic entered the mesh with A's overlay IP as its source.

## DNS — the part Layer-3 cannot fix

Routing by IP is blind to a poisoned resolver: if A resolves `x.com` to a fake IP
returned by a censored DNS, no amount of IP routing helps.

- **Pattern B** solves this for you — the rule engine does `fake-ip` and sends DNS
  to a clean resolver *through* the proxy.
- **Pattern A** does **not**. You must also send DNS to a clean resolver reachable
  via B (point the client's resolver at one that is routed through the tunnel, or
  use DoH), or you will still resolve poisoned addresses.

## Cautions (both patterns)

- **B is your exit.** Its public IP carries A's traffic — that is real abuse/legal
  exposure for whoever runs B. B also sees A's destination metadata (SNI, DNS);
  the TLS *payload* stays end-to-end encrypted, but the *who* is visible at B.
- **Double hop.** Traffic goes `A → hub → B → internet` and back. Expect added
  latency, and the hub now carries this bandwidth — shape it (see
  [Production Deployment → Traffic shaping](deployment.md#9-traffic-shaping--tuning)).
- **MTU stacks.** You are tunnelling inside a tunnel; size the inner MTU with the
  [Host Network Plan](../configuration/network-plan.md) guidance.
- **Stay small.** A circumvention pattern only keeps working while few people use
  it the same way; a popular, uniform setup is what gets fingerprinted and
  blocked. Keep deployments small and varied.

## Verify

```bash
# From client A — the public IP you present should be B's:
curl -s https://api.ipify.org ; echo

# On the hub — relay counters climb as A's traffic flows through:
subnetra status --json | grep relay_
```
