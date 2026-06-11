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

`manual` is the original, explicit mode and the default. The daemon derives **no**
policy at boot — the forwarding table starts **empty** and you install every rule
yourself over the control socket. Configs that predate roles keep working unchanged.

**What `manual` changes vs. a derived role:**

- **No derived policy.** You build the table with `subnetra policy add`.
- **No role-specific `--check`.** `subnetrad --check` still runs the universal sanity
  checks (MTU range, 16-bit ids, host-subnet overlap), but it does **not** apply the
  `hub`/`spoke` structural rules (per-peer `allowed_src`, exactly-one-hub, a local
  target, no `0.0.0.0/0` local route). A malformed forwarding intent is yours to catch.
- **Keepalive defaults to `0`.** If a `manual` node sits behind NAT, set
  `keepalive_secs` yourself (a `spoke` does this for you).

**What `manual` does _not_ change — security is identical.** Role only chooses the
*bootstrap* policy; it never touches the data plane. Per-link encryption, session-epoch
ordering, anti-replay, and — crucially — the **per-peer `allowed_src` inner-source
check** all run exactly the same. Policy match is destination-only (longest-prefix);
each peer's `allowed_src` independently binds which inner source addresses that peer
may assert. A hand-built `manual` table therefore cannot be tricked into accepting a
spoofed inner source — you give up the *derived convenience table* and the
*role-specific guardrails*, **not** the cryptographic guarantees.

### When to use `manual`

- Topologies the `hub`/`spoke` shapes can't express in a single node — e.g. a node
  that is a **spoke upstream and a relay downstream** at the same time (the `hub`/`spoke`
  roles each validate one posture; `manual` lets one node hold both). This is outside
  the single-tier model the derived roles validate, so the table — and the upstream
  hub's `allowed_src` aggregation — is on you.
- Reproducing a hand-tuned policy table verbatim, or backward compatibility with a
  pre-role config.

### Building the table by hand

Rules are destination-matched longest-prefix; `src` is permissive (`0.0.0.0/0`).
`--target 0` delivers to the local TUN, any other target relays to that peer id:

```bash
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
# Deliver this node's own overlay address locally.
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.9/32  --action forward --target 0
# Relay a downstream prefix to peer 5; send everything else up to the hub (peer 1).
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.32/27 --action forward --target 5
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.0/24  --action forward --target 1
sudo -E subnetra policy show      # verify ordering
sudo -E subnetra save             # persist across restarts
```

Each peer must still carry the right `allowed_src` for the inner sources it is allowed
to assert — that binding is enforced regardless of these rules.

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
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
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
    { "id": 2, "endpoint": "203.0.113.2:18020", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:18020", "allowed_src": "10.0.0.3/32", "psk": "…64 hex…" }
  ]
}
```

This derives `10.0.0.2/32 → peer 2` and `10.0.0.3/32 → peer 3`. The hub relays
between spokes by longest-prefix match, and never reflects a packet back to its
source.

### Reaching the hub itself

The derived hub table forwards **only to spokes** — it never delivers to the hub's
own TUN. So by default a hub has **no overlay address and is not reachable** on the
overlay: it is a pure relay. This is usually exactly what you want — the relay
exposes nothing addressable on the mesh.

To make the hub itself reachable over the tunnel (to SSH into it, or to host a
service on the overlay), do **two** things:

1. give it an address with [`local_tun_ip`](reference.md) so the
   [network plan](network-plan.md) configures its TUN, **and**
2. add a local-delivery rule for that address — either run the node as `manual`
   with an explicit table, or layer one rule on top of the derived hub table:

   ```bash
   # deliver the hub's own overlay address to its local TUN
   sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.1/32 --action forward --target 0
   ```

Leave `local_tun_ip` unset (and add no such rule) to keep the hub relay-only, with
nothing on the overlay able to address it.

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
