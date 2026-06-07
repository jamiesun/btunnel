# Subnetra on RouterOS Container

This guide documents the RouterOS-specific deployment shape for Subnetra. Use it
when a MikroTik/RouterOS device is a **Spoke** behind NAT and a public Linux
server is the **Hub**.

RouterOS Container is not the same as a normal Linux host:

- RouterOS manages the container's Ethernet side through a `veth`.
- Subnetra creates its own Linux `snr0` TUN device inside the container.
- RouterOS cannot manage the container's `snr0` directly. It routes to the
  container through the `veth` gateway.
- RouterOS image import may require a legacy Docker archive layout.

## 0. Recommended topology

Put the Hub on a public Linux server with a stable UDP endpoint. Put RouterOS
devices behind NAT as Spokes.

```text
Public Linux Hub
  underlay: 203.0.113.10:51820
  overlay: 10.66.0.1/24

RouterOS office Spoke
  container veth: 172.30.66.2/30
  RouterOS veth side: 172.30.66.1/30
  subnetra TUN in container: 10.66.0.3/24
  published LAN: 192.168.88.0/24
```

Do not make a NATed RouterOS device the public Hub unless its UDP endpoint is
stable and reachable from every Spoke.

All LAN addresses in this guide are documentation examples. Replace
`192.168.88.0/24` and `192.168.88.1` with the local LAN CIDR and router address
for the target deployment.

> v0.2.0 note: peer endpoints are still static. For NATed Spokes, the Hub must
> know the real source endpoint seen on the public Hub. Protocol-level endpoint
> roaming is tracked in issue #34 and should replace manual endpoint correction.

## 1. RouterOS prerequisites

Requirements:

- RouterOS v7 with the `container` package installed.
- Device mode allows containers.
- A writable storage path for container root directories and image archives.
- `/dev/net/tun` visible inside RouterOS containers.
- Outbound UDP from the RouterOS device to the public Hub.

Typical checks:

```routeros
/system/package/print
/system/device-mode/print
/container/print
```

If containers are disabled, enable container mode according to MikroTik's device
mode procedure, then reboot if RouterOS asks for it.

## 2. Build a RouterOS-importable image archive

The release image is OCI-compatible, but some RouterOS versions reject OCI image
archives with errors such as:

```text
download/extract error: no config found in manifest
```

When that happens, build or convert the image into a legacy Docker archive with
top-level files:

```text
manifest.json
config.json
layer.tar
```

The image must include:

- `/usr/local/bin/subnetrad`
- `/usr/local/bin/subnetra`
- `/etc/subnetra/config.json`
- an entrypoint script that configures the container-local TUN interface

The entrypoint should:

```sh
export SUBNETRA_SOCK="${SUBNETRA_SOCK:-/etc/subnetra/subnetra.sock}"
export SUBNETRA_TUN="${SUBNETRA_TUN:-snr0}"
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

/usr/local/bin/subnetrad &
pid=$!

for i in $(seq 1 100); do
  ip link show "$SUBNETRA_TUN" >/dev/null 2>&1 && break
  sleep 0.1
done

ip addr add "$SUBNETRA_TUN_IP" dev "$SUBNETRA_TUN" 2>/dev/null || true
ip link set "$SUBNETRA_TUN" mtu "${SUBNETRA_TUN_MTU:-1400}" up

# If this RouterOS Spoke publishes a LAN, return traffic to RouterOS over veth.
if [ -n "${SUBNETRA_LAN_CIDR:-}" ]; then
  ip route replace "$SUBNETRA_LAN_CIDR" via 172.30.66.1 2>/dev/null || true
fi
ip route replace 10.66.0.0/24 dev "$SUBNETRA_TUN" 2>/dev/null || true

/usr/local/bin/subnetra status || true
wait "$pid"
```

Set these image environment values in the image config, not in RouterOS secrets:

```text
SUBNETRA_TUN_IP=10.66.0.3/24
SUBNETRA_TUN_MTU=1400
SUBNETRA_LAN_CIDR=192.168.88.0/24
SUBNETRA_SOCK=/etc/subnetra/subnetra.sock
```

Real PSKs live in `/etc/subnetra/config.json` inside the image. Do not commit
production configs or image build directories containing real PSKs.

## 3. Spoke config shape

RouterOS as a Spoke should point at the public Hub:

```json
{
  "role": "spoke",
  "virtual_subnet": "10.66.0.0/24",
  "local_tun_mtu": 1400,
  "listen_port": 51823,
  "local_id": 3,
  "local_tun_ip": "10.66.0.3/24",
  "local_routes": ["192.168.88.0/24"],
  "remote_routes": ["10.66.0.0/24"],
  "peers": [
    {
      "id": 1,
      "endpoint": "203.0.113.10:51820",
      "allowed_src": "10.0.0.0/8",
      "psk": "REPLACE_WITH_64_HEX_CHARS"
    }
  ]
}
```

Important semantics:

- `local_tun_ip` is the Spoke overlay address inside the container.
- `local_routes` are the prefixes this Spoke is allowed to originate. For LAN
  publishing, use the RouterOS LAN CIDR, for example `192.168.88.0/24`.
- The Hub peer entry for this RouterOS Spoke must use the same LAN CIDR in
  `allowed_src`, for example `192.168.88.0/24`.
- `remote_routes` should include the overlay or remote LAN prefixes that this
  Spoke sends through the Hub.

## 4. RouterOS veth, address, and route

> **Scripted happy path.** The veth/address/route in this section, the container
> in §5, and the optional self-SNAT in §6 are automated by
> [`deploy/routeros/subnetra-spoke-up.rsc`](../deploy/routeros/) (idempotent,
> parameterized, prints verification; teardown is `subnetra-spoke-down.rsc`). The
> manual commands below remain as the explanation of what that script does — read
> them to review the change, then prefer the script for a repeatable bring-up.

Create a dedicated veth for the Subnetra container:

```routeros
/interface/veth/add name=subnetra-test-veth address=172.30.66.2/30 gateway=172.30.66.1
/ip/address/add address=172.30.66.1/30 interface=subnetra-test-veth comment=subnetra-test-veth
```

Route overlay traffic from RouterOS into the container:

```routeros
/ip/route/add dst-address=10.66.0.0/24 gateway=172.30.66.2 comment=subnetra-test-overlay
```

If remote nodes should reach the RouterOS LAN, they must have a route to the LAN
through Subnetra. On a Linux Hub/Spoke this is usually:

```bash
ip route add 192.168.88.0/24 dev snr0
```

## 5. Add and start the container

Upload the legacy archive to RouterOS, then add the container:

```routeros
/container/add \
  file=subnetra-routeros-spoke.legacy.tar.gz \
  interface=subnetra-test-veth \
  root-dir=subnetra-routeros-spoke-root \
  logging=yes \
  start-on-boot=no \
  comment=subnetra-routeros-spoke

/container/start [find comment="subnetra-routeros-spoke"]
/container/print detail where comment="subnetra-routeros-spoke"
```

Check logs:

```routeros
/log/print where message~"subnetra-routeros-spoke|subnetra"
```

Expected startup evidence:

```text
subnetrad v0.2.0 ... local_id=3 peers=1 ... [ready]
snr0 ... mtu 1400 ... inet 10.66.0.3/24
subnetra status shows udp/tun counters
```

## 6. NAT rules

Do not add broad NAT rules for Subnetra traffic.

For LAN publishing, preserve the real LAN source addresses. The Hub should see
inner sources from the published LAN, for example `192.168.88.0/24`, and
enforce that with `allowed_src`.

RouterOS itself may choose the veth-side address (`172.30.66.1`) as the source
when it pings overlay addresses. That source is outside the published LAN and
will be rejected by the Hub as `spoof`. If you want RouterOS self-originated
diagnostic traffic to work, add a narrow SNAT rule only for the RouterOS veth
source:

```routeros
/ip/firewall/nat/add \
  chain=srcnat \
  src-address=172.30.66.1 \
  dst-address=10.66.0.0/24 \
  out-interface=subnetra-test-veth \
  action=src-nat \
  to-addresses=192.168.88.1 \
  comment=subnetra-routeros-self-snat \
  place-before=[find chain=srcnat action=masquerade]
```

Do not use a broad rule that rewrites the entire office LAN to the overlay IP.
That makes return traffic terminate at the Spoke container instead of returning
to LAN clients.

## 7. Validation

From the public Hub:

```bash
ping -c 3 10.66.0.3
ping -c 3 192.168.88.1
SUBNETRA_SOCK=/run/subnetra-test/subnetra.sock sudo -E subnetra status
```

From another Linux Spoke:

```bash
ping -c 3 10.66.0.1
ping -c 3 192.168.88.1
```

From RouterOS:

```routeros
/tool/ping 10.66.0.1 count=5
/tool/ping 10.66.0.2 count=5
```

Useful counters:

```text
udp.unknown_peer
  Hub saw traffic from an endpoint that does not match a configured peer.
  In v0.2.0 this usually means NAT changed the source IP or port.

udp.spoof
  The packet authenticated, but the inner IPv4 source was outside the peer's
  allowed_src. Check Hub allowed_src and the RouterOS/container routing model.

udp.auth_or_invalid
  PSK, epoch, replay window, or wire-format mismatch.

tun.not_ipv4
  Usually IPv6 or non-IPv4 traffic entered the TUN. It is not necessarily fatal.
```

## 8. MTU guidance

Subnetra v0.2.0 overhead is 64 bytes:

```text
wire header 20 + AEAD tag 16 + outer IPv4/UDP 28 = 64
```

Set:

```text
local_tun_mtu = underlay_path_mtu - 64
```

Examples:

```text
1500 path MTU -> local_tun_mtu <= 1436
1400 path MTU -> local_tun_mtu <= 1336
1280 path MTU -> local_tun_mtu <= 1216
```

When the underlay path is unknown, `1400` is a conservative default for many
public-internet paths. For a known 1400-byte VPN/private-line underlay, use
`1336` to avoid fragmentation.

## 9. Cleanup

> Scripted: [`deploy/routeros/subnetra-spoke-down.rsc`](../deploy/routeros/)
> removes exactly the tagged objects the bring-up script created (container,
> overlay route, optional self-SNAT, and the veth if `removeVeth=true`). The
> manual commands below are the equivalent.

Stop and remove the container:

```routeros
/container/stop [find comment="subnetra-routeros-spoke"]
/container/remove [find comment="subnetra-routeros-spoke"]
/file/remove [find name="subnetra-routeros-spoke-root"]
```

Remove the test route and optional self-SNAT:

```routeros
/ip/route/remove [find comment="subnetra-test-overlay"]
/ip/firewall/nat/remove [find comment="subnetra-routeros-self-snat"]
```

Keep the veth if you plan to redeploy; otherwise remove it:

```routeros
/ip/address/remove [find comment="subnetra-test-veth"]
/interface/veth/remove [find name="subnetra-test-veth"]
```

## 10. Production notes

- Prefer a public Linux Hub and NATed RouterOS Spokes.
- Do not depend on packet capture or manual endpoint correction in production.
- Until endpoint roaming lands, v0.2.0 still requires the Hub peer endpoint to
  match the NAT source endpoint seen by the Hub.
- Use one unique per-link PSK for each Hub-Spoke link.
- Keep real PSKs out of Git, logs, tickets, and shared image build directories.
