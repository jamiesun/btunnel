# OpenWrt Spoke

This guide covers running Subnetra as a **spoke** on an **OpenWrt** router
(MIPS or ARM home/SOHO CPE) behind NAT, dialing a public Linux **hub**. OpenWrt
is a natural fit: it already ships **musl**, so the static binary just runs, and
a NATed router is exactly what the spoke role is built for.

The ready-to-use procd service is
[`deploy/openwrt/subnetrad.init`](https://github.com/jamiesun/subnetra/blob/main/deploy/openwrt/subnetrad.init).

## Why OpenWrt is different

- **procd, not systemd.** Use the provided `/etc/init.d/subnetrad` init script
  instead of the [systemd unit](deployment.md#4-run-as-a-service).
- **TUN is a module.** Install `kmod-tun` so the daemon can create its `snr0`
  device via `/dev/net/tun`.
- **BusyBox userland.** The [`doctor.sh`](https://github.com/jamiesun/subnetra/blob/main/tools/doctor.sh)
  preflight is BusyBox-friendly and runs as-is.
- **Small flash.** Each binary is well under 512 KB; both fit comfortably in the
  overlay (`/usr/sbin`, `/usr/bin`).

## Pick the right binary

Subnetra publishes static musl tarballs per architecture. Map your router to one
with `opkg print-architecture` (or `uname -m`):

| OpenWrt target (examples) | `opkg` arch | Release tarball |
|---|---|---|
| ramips (mt7621 / mt7628), most modern MIPS | `mipsel_24kc` | `…-linux-mipsel.tar.gz` |
| ath79 / Atheros (big-endian MIPS) | `mips_24kc` | `…-linux-mips.tar.gz` |
| mvebu / ipq40xx / sunxi (32-bit ARM) | `arm_cortex-a*` | `…-linux-armv7.tar.gz` |
| filogic / ipq807x / bcm27xx (64-bit ARM) | `aarch64_cortex-a*` | `…-linux-arm64.tar.gz` |

> **Endianness matters for MIPS.** `mipsel` is little-endian (ramips and most
> modern devices); `mips` is big-endian (ath79/Atheros). Installing the wrong one
> fails to exec. When in doubt, check `opkg print-architecture`.

## Install

```sh
# 1. TUN module (one-time)
opkg update && opkg install kmod-tun

# 2. Resolve the latest release + your arch, download, verify, install
ARCH=mipsel   # one of: mipsel | mips | armv7 | arm64  (see the table above)
VER=$(uclient-fetch -qO - \
        https://api.github.com/repos/jamiesun/subnetra/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
base="https://github.com/jamiesun/subnetra/releases/download/$VER"
cd /tmp
uclient-fetch -q "$base/subnetra-$VER-linux-$ARCH.tar.gz"
uclient-fetch -q "$base/SHA256SUMS.txt"
sha256sum -c SHA256SUMS.txt 2>/dev/null | grep "subnetra-$VER-linux-$ARCH.tar.gz: OK"
tar -xzf "subnetra-$VER-linux-$ARCH.tar.gz"

# 3. Place the binaries (daemon in sbin, client in bin)
install -m 0755 "subnetra-$VER-linux-$ARCH/subnetrad" /usr/sbin/subnetrad
install -m 0755 "subnetra-$VER-linux-$ARCH/subnetra"  /usr/bin/subnetra
subnetrad --version
```

## Configure the spoke

Put this node's config (with its PSKs) at `/etc/subnetra/config.json`,
root-owned and mode `0600`. A minimal spoke that publishes the router's LAN
across the tunnel:

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 7,
  "local_tun_ip": "10.0.0.7/24",
  "local_routes": ["10.0.0.7/32", "192.168.1.0/24"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:51820", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

See [Roles](../configuration/roles.md) for what the `spoke` role derives, and
[`config-gen`](https://github.com/jamiesun/subnetra/tree/main/tools) /
[`keygen`](https://github.com/jamiesun/subnetra/tree/main/tools) to scaffold a
matching hub + spoke set with fresh per-link PSKs.

```sh
mkdir -p /etc/subnetra
# (copy your config in, then lock it down)
chmod 0600 /etc/subnetra/config.json
subnetrad --check --config /etc/subnetra/config.json   # validate offline
```

## Install the procd service

```sh
# from a checkout, or download the raw file:
uclient-fetch -qO /etc/init.d/subnetrad \
  https://raw.githubusercontent.com/jamiesun/subnetra/main/deploy/openwrt/subnetrad.init
chmod 0755 /etc/init.d/subnetrad
/etc/init.d/subnetrad enable
/etc/init.d/subnetrad start
logread -e subnetrad        # check it came up (and didn't fail --check)
```

The init script runs `subnetrad --check` before starting (so a bad config fails
fast instead of respawn-looping), keeps the daemon respawned, and bounces it when
the network config reloads.

## Apply the host network plan

Subnetra **never edits routes itself** — it only prints the plan. Preview it and
apply the result after the service is up (the `snr0` device exists only while the
daemon runs):

```sh
subnetra --print-network-plan --config /etc/subnetra/config.json
# then apply the printed ip/route commands, e.g.:
ip link set snr0 mtu 1400 up
ip addr add 10.0.0.7/24 dev snr0
```

To make it survive reboots, add the equivalent to `/etc/config/network` (an
`interface` with `proto none` bound to `snr0`, plus static routes) or a small
hotplug script — but keep route application **on the OpenWrt side**, never in the
daemon.

## Verify

```sh
subnetra status                 # peers, traffic, per-reason drops
sh doctor.sh                    # TUN / capabilities / clock preflight (BusyBox-ok)
ping -c3 10.0.0.1               # across the overlay to the hub
```

## Topology notes

- **Behind NAT = ideal spoke.** The built-in NAT keepalive (`role=spoke` default,
  `keepalive_secs = 20`) holds the pinhole open and keeps the hub's learned
  endpoint fresh, so a roaming/CGNAT-changing mapping stays reachable with no
  manual endpoint correction.
- **A router with a static port-forward can be a hub.** If this OpenWrt box has a
  stable public `IP:port` DNAT'd to its `listen_port`, it can run `role=hub`
  instead — see
  [Hub behind NAT](deployment.md#hub-behind-nat-static-port-forward).
- **Time sync.** The session key uses a `CLOCK_REALTIME` boot epoch ordered
  forward-only, so run `sysntpd` and let the clock settle before/at start (the
  init starts late, `START=95`). See the time-sync note in
  [Production Deployment](deployment.md).
