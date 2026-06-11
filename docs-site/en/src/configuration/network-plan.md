# Host Network Plan

`subnetrad` creates the TUN device but deliberately does **not** configure host
addressing, routes, or MTU. Auto-applying host networking would mean shelling out
or linking extra libraries, which breaks the zero-dependency single-binary
guarantee. Instead, the daemon **prints the exact commands** for the loaded config
so you can review and run them.

## Print the plan

```bash
# Print the host networking plan for this node (defaults to a 1500-byte underlay).
subnetrad --print-network-plan --config config.json

# Override the underlay path MTU (e.g. behind a PPPoE / VPN underlay):
subnetrad --print-network-plan --path-mtu 1420 --config config.json
```

Output is **deterministic and print-only** — nothing on the host is modified. The
backend is selected at comptime, so the plan matches your platform:

- **Linux** emits `ip link` / `ip addr` / `ip route` commands.
- **macOS** emits `ifconfig` / `route` commands.

## What it emits

For the loaded config the Linux plan emits:

- `ip link set <tun> mtu <local_tun_mtu> up`
- `ip addr add <local_tun_ip> dev <tun>` — set the optional `local_tun_ip` config
  field (e.g. `"local_tun_ip": "10.0.0.2/24"`); otherwise a placeholder is shown.
- `ip route add <subnet> dev <tun>` for each peer's `allowed_src` — a permissive
  `0.0.0.0/0` is **skipped** so you never blackhole the default route.
- an optional TCP **MSS clamp** hint (nftables / iptables) to avoid PMTU
  blackholes.

## The MTU calculation

The plan computes the safe tunnel MTU from the real wire overhead:

```text
header 20  +  AEAD tag 16  +  outer IPv4/UDP 28  =  64 bytes
max tunnel MTU = path_mtu − 64
```

If the configured `local_tun_mtu` exceeds that, the plan prints a **warning** —
this is the classic cause of "small packets work, large transfers stall" (PMTU
blackholing). On a standard 1500-byte path, `1436` is the safe default; on a
1420-byte underlay you would lower `local_tun_mtu` to `1356`.

## Measure the real path MTU

`--print-network-plan` *assumes* a 1500-byte underlay (override with
`--path-mtu`). But the real path is often smaller — PPPoE is 1492, and
CGNAT/mobile/tunneled uplinks vary — and the usual way to discover it, kernel
Path MTU Discovery, relies on routers returning ICMP "fragmentation needed".
That ICMP is frequently filtered (a *PMTU black hole*), which is exactly the
kind of network an obfuscated overlay runs across.

The [`mtu-probe`](https://github.com/jamiesun/subnetra/tree/main/tools) tool
measures the path **actively, end to end, over plain UDP** without trusting
ICMP, then prints the `local_tun_mtu` to configure. Run the responder on one
node and the prober on the other:

```bash
zig build tool:mtu-probe

# on the far node (e.g. the hub, at its public endpoint):
zig-out/tools/mtu-probe --listen 18020

# on the near node — binary-searches the largest datagram that round-trips
# with the Don't-Fragment bit set, then recommends a safe local_tun_mtu:
zig-out/tools/mtu-probe --probe 203.0.113.9:18020
#   underlay path MTU : 1492 bytes   (largest UDP payload that round-tripped: 1464 + 28 IPv4/UDP)
#   subnetra overhead : 64 bytes
#   recommended       : local_tun_mtu = 1428
```

Set the printed value as `local_tun_mtu` (and re-run `--print-network-plan` to
confirm the warning is gone). On jumbo-frame paths pass `--ceil 9000`. See
[`tools/README.md`](https://github.com/jamiesun/subnetra/tree/main/tools) for
details.

## Apply it

Review the emitted commands, then run them (most require root):

```bash
subnetrad --print-network-plan --config config.json | sudo sh   # after reviewing!
```

> Prefer to inspect the output first and paste the commands deliberately, rather
> than piping straight to a shell — the plan is meant to be auditable.

## Why this design

Keeping host networking out of the daemon means:

- the binary stays dependency-free and tiny,
- the same daemon behaves identically across Linux, containers, and macOS,
- operators retain full control and an auditable record of every change to the
  host's addressing and routing.

See the [Configuration Reference](reference.md) for the fields that feed the plan
(`local_tun_ip`, `local_tun_mtu`, each peer's `allowed_src`) and
[Production Deployment](../operations/deployment.md) for wiring it into a service.
