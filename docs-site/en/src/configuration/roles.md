# Roles

Instead of hand-injecting `subnetra policy add` rules, set a **`role`** and let the
daemon derive the forwarding table at boot. Three roles are available; `role`
defaults to `"manual"`.

| Role | Derives policy? | Typical node |
|---|---|---|
| `manual` | No (empty initial policy — inject rules yourself) | Custom setups, backward compatibility |
| `spoke` | Yes — local targets + everything else via the hub | Branch office, RouterOS container, Mac |
| `hub` | Yes — one forward rule per spoke's `allowed_src` | The central relay |

You can always layer extra `subnetra policy` rules on top of a derived table at
runtime.

## `manual` (default)

Keeps the original behavior: the initial policy is empty and you inject every rule
yourself over the control socket. Existing configs that predate roles are
unchanged.

## `spoke`

A home/office spoke that exposes its own overlay IP and routes everything else
through the relay needs only:

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:51820", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

This derives, automatically:

- `10.0.0.2/32 → LOCAL` (deliver to this node's own TUN)
- `10.0.0.0/24 → hub(id 1)` (everything else goes through the relay)

To publish a LAN behind the spoke (Site-to-Site), add it to `local_routes`
(e.g. `["10.0.0.2/32", "192.168.2.0/24"]`) so the derived table delivers that
prefix locally.

### Built-in NAT keepalive

A `spoke` turns on the **NAT keepalive** by default (`keepalive_secs = 20`). It
sends one tiny authenticated datagram to its hub every interval so an idle spoke's
NAT pinhole stays open and the hub keeps a fresh route back — no external pinger,
no cron job. Set `keepalive_secs` explicitly to tune it, or `0` to disable.

### Validation rules for `spoke`

`subnetrad --check` enforces:

- exactly **one** hub peer,
- at least one local target (`local_routes` **or** `local_tun_ip`),
- no `0.0.0.0/0` local route (which would tie the host default route to the
  tunnel and blackhole it).

## `hub`

The matching hub just lists its spokes; each peer's `allowed_src` becomes a forward
rule to that peer:

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:51820", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:51820", "allowed_src": "10.0.0.3/32", "psk": "…64 hex…" }
  ]
}
```

This derives `10.0.0.2/32 → peer 2` and `10.0.0.3/32 → peer 3`. The hub relays
between spokes by longest-prefix match, and never reflects a packet back to its
source.

### Validation rules for `hub`

`subnetrad --check` rejects:

- a peer with a **missing** `allowed_src` (or the permissive `0.0.0.0/0`), since the
  hub could not tell which spoke a packet belongs to;
- two peers whose `allowed_src` prefixes **overlap**, which would make forwarding
  ambiguous.

A hub's keepalive defaults to `0` (it does not initiate keepalives to spokes).

## Ready-to-edit examples

The repository's [`deploy/`](https://github.com/jamiesun/subnetra/tree/main/deploy)
directory ships editable `hub.json`, `spoke-a.json`, and `spoke-b.json`, plus the
service units. The full hub + two-spoke walkthrough is in
[Production Deployment](../operations/deployment.md).
