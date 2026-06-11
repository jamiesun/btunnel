# macOS Spoke

macOS is supported as a **spoke** that dials an existing Linux/RouterOS **hub**.
The data path runs natively on `utun` + `poll(2)`, selected at comptime behind
`src/os/`. A macOS **hub**, `kqueue`, and automatic route mutation are explicitly
out of scope.

Because macOS has no network namespaces and hosted-mac CI runners cannot create a
`utun` without elevated privileges, the macOS spoke is **runbook-certified** rather
than CI-gated. The authoritative procedure is
[`docs/macos-spoke-acceptance.md`](https://github.com/jamiesun/subnetra/blob/main/docs/macos-spoke-acceptance.md).

## Prerequisites

- A real Mac (Apple Silicon or Intel) with `sudo` access — `utun` creation needs
  root.
- A release macOS binary, or **Zig 0.16.0+** to build from source.
- A reachable, already-working Linux/RouterOS hub with a stable underlay endpoint
  and a per-peer **PSK** issued for this Mac.
- At least one remote overlay target to ping across the tunnel.

> The macOS binary is **minimal-dynamic** — it links only `libSystem` (still zero
> third-party deps), so it is *not* a static executable. Do **not** run the
> Linux-only `ldd → not a dynamic executable` check against it.

## Install

From a release tarball (`subnetra-<version>-macos-arm64.tar.gz` or `-amd64`):

```bash
tar -xzf subnetra-<version>-macos-arm64.tar.gz
cd subnetra-<version>-macos-arm64
# Gatekeeper quarantines downloaded binaries — clear it (or build from source):
xattr -d com.apple.quarantine subnetrad subnetra 2>/dev/null || true
```

Or build locally with `zig build` (see [Installation](../getting-started/installation.md)).

## Configure

Write a spoke `config.json` (see [Roles](../configuration/roles.md)) with the hub
as the single peer and this Mac's overlay address:

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 4,
  "local_tun_ip": "10.0.0.4/24",
  "local_routes": ["10.0.0.4/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

## Preview the host plan

On macOS the plan emits `ifconfig` / `route` commands (the daemon never applies
them):

```bash
./subnetra --print-network-plan --config config.json
```

## Run

```bash
sudo ./subnetrad --config config.json
# subnetra v… (… mode=raw_direct …) tun=utun4 sock=/var/run/subnetra.sock [ready]
```

The `utunN` interface name is **kernel-assigned** — read it from the `[ready]`
banner, then apply the plan with the real name:

```bash
sudo ifconfig utun4 inet 10.0.0.4 10.0.0.4 mtu 1400 up
sudo route add -net 10.0.0.0/24 -interface utun4
```

## Run under launchd

For a persistent spoke, install the system daemon plist (it runs as root, restarts
on abnormal exit, and logs to `/var/log/subnetrad.log`):

```bash
sudo install -m 0644 deploy/net.subnetra.subnetrad.plist \
    /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl enable system/net.subnetra.subnetrad
```

Manage it with `sudo launchctl kickstart -k system/net.subnetra.subnetrad`
(restart) and `sudo launchctl bootout system/net.subnetra.subnetrad` (stop).

> `KeepAlive` may restart the daemon onto a **different** `utunN`; re-read the
> banner and re-apply the plan. Subnetra deliberately leaves routing to you (no
> automatic route mutation).

## Verify

```bash
sudo ./subnetra status      # peer online, counters climbing
ping 10.0.0.3               # a remote overlay target across the tunnel
```
