# RouterOS Spoke

This guide covers running Subnetra as a **spoke** inside a **RouterOS Container**
on a MikroTik device, dialing a public Linux **hub**. The full reference, including
scripted (`.rsc`) bring-up/teardown, is
[`docs/routeros-container.md`](https://github.com/jamiesun/subnetra/blob/main/docs/routeros-container.md);
scripts live in
[`deploy/routeros/`](https://github.com/jamiesun/subnetra/tree/main/deploy/routeros).

## Why RouterOS is different

RouterOS Container is not a normal Linux host:

- RouterOS manages the container's Ethernet side through a **`veth`**.
- Subnetra creates its own Linux **`snr0` TUN** device *inside* the container.
- RouterOS cannot manage that `snr0` directly — it routes **to** the container
  through the `veth` gateway.
- RouterOS image import may require a legacy Docker archive layout.

## Recommended topology

Put the hub on a public Linux server with a stable UDP endpoint; put NATed
RouterOS devices behind it as spokes.

```text
Public Linux Hub
  underlay: 203.0.113.10:51820
  overlay:  10.66.0.1/24

RouterOS office Spoke
  container veth:           172.30.66.2/30
  RouterOS veth side:       172.30.66.1/30
  subnetra TUN in container: 10.66.0.3/24
  published LAN:            192.168.88.0/24
```

> Do **not** make a NATed RouterOS device the public hub unless its UDP endpoint is
> stable and reachable from every spoke. LAN addresses here are examples — replace
> `192.168.88.0/24` with your real LAN.

## Prerequisites

- RouterOS v7 with the **`container`** package installed.
- Device mode allows containers (`/system/device-mode/print`).
- A writable storage path for container root dirs and image archives.
- **`/dev/net/tun`** visible inside RouterOS containers.
- Outbound UDP from the RouterOS device to the public hub.

```routeros
/system/package/print
/system/device-mode/print
/container/print
```

## Outline of the bring-up

1. **Provision the veth** pair and addressing (container side `172.30.66.2/30`,
   RouterOS side `172.30.66.1/30`).
2. **Import the image** (a `docker load`-able tarball from a release, or pull from
   GHCR if the device can reach it) and create the container with the mounted
   `config.json`, `NET_ADMIN`, and `/dev/net/tun`.
3. **Set the spoke config** (`role: spoke`, the hub as the single peer, the
   published LAN in `local_routes`) — see [Roles](../configuration/roles.md).
4. **Apply routing on RouterOS** so LAN traffic for the overlay/remote prefixes is
   routed to the container's `veth` gateway, and the published LAN is reachable
   across the tunnel.
5. **Verify** with `subnetra status` inside the container and a ping across the
   overlay.

The scripted `.rsc` files in `deploy/routeros/` automate steps 1–4 (and a matching
teardown). Follow the full guide for the exact commands, including LAN publishing
and the NAT/endpoint notes for NATed spokes.

## Endpoint roaming note

Protocol-level endpoint learning means the hub re-learns a NATed spoke's endpoint
from its next authenticated datagram, and the built-in NAT keepalive
(`role=spoke` default) keeps the pinhole open — so a RouterOS spoke behind a
changing NAT mapping stays reachable without manual endpoint correction.
