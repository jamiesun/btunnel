# RouterOS Container Spoke — scripted bring-up

Parameterized, idempotent RouterOS scripts that automate the **error-prone
RouterOS-side plumbing** for a Subnetra Spoke container — the veth pair, its
addresses, the overlay route into the container, the container itself, and an
optional narrow self-SNAT. They replace the manual command sequence in
[`docs/routeros-container.md`](../../docs/routeros-container.md) §4–§6 with one
reviewable step, so a single mistyped veth/route no longer yields a silently dead
tunnel.

| File | Purpose |
| --- | --- |
| `subnetra-spoke-up.rsc`   | Bring up the veth + address + overlay route + container (+ optional self-SNAT); prints verification. |
| `subnetra-spoke-down.rsc` | Reverse it — removes only the objects the up-script created (tagged), veth kept by default. |

## Prerequisites (not scripted)

These scripts do the **RouterOS** side only. Before running them you still need,
per `docs/routeros-container.md`:

- **§1** RouterOS v7 with the `container` package, container mode enabled, and
  `/dev/net/tun` available.
- **§2** the **legacy Docker image archive** (built host-side with the subnetra
  binaries, entrypoint, and your `/etc/subnetra/config.json` baked in) uploaded to
  the device. The image carries the env (`SUBNETRA_TUN_IP`, `SUBNETRA_TUN_MTU`,
  `SUBNETRA_LAN_CIDR`, …) and the **real per-link PSK** — keep that archive out of
  Git/logs.
- **§3** a Spoke `config.json` inside that image. Generate the matching mesh with
  `config-gen` and keep the values consistent (see below).

## Use

1. Review and edit the `:local` parameter block at the top of
   `subnetra-spoke-up.rsc`. Defaults mirror the documentation example.
2. Upload `subnetra-spoke-up.rsc` (and the image archive) to the device.
3. On the device:

   ```routeros
   /import file-name=subnetra-spoke-up.rsc
   ```

   It prints each object it adds (or skips, if it already exists) and the
   verification commands to run next.

Teardown:

```routeros
/import file-name=subnetra-spoke-down.rsc
```

## Composes with `config-gen`

Keep these script parameters equal to your `config-gen` / `config.json` values so
the overlay actually lines up:

| Script parameter | Must match |
| --- | --- |
| `overlaySubnet` | `config-gen --subnet` / `virtual_subnet` in `config.json` |
| `lanCidr`       | the Spoke's `local_routes` LAN **and** the Hub peer's `allowed_src` for this Spoke |
| `imageFile`     | the uploaded archive filename |

The port/MTU/ids live in the baked `config.json` (from `config-gen --port` /
`--mtu` and the per-spoke `local_id`), so they are not repeated here.

## What it changes (auditable)

Every object the up-script creates is tagged with the `$tag` value
(`subnetra-routeros-spoke` by default):

- one `/interface/veth` + its `/ip/address` (comment `…-veth`),
- one `/ip/route` for the overlay (comment `…-overlay`),
- one `/container` (comment `$tag`),
- optionally one `/ip/firewall/nat` srcnat rule (comment `…-self-snat`).

It touches **nothing else** — no existing routes, no broad NAT. Re-running is
safe (existing objects are skipped). The down-script removes exactly those tagged
objects, in dependency order.
