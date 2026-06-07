# Containers

Subnetra is a natural fit for containers: the daemon is a single static binary
with no shared-library dependencies. The published image is multi-arch
(`amd64 / arm64 / armv7 / armv5`) and Docker selects the right one automatically.

## Requirements

A container running `subnetrad` needs:

- the **`NET_ADMIN`** capability (to create the TUN device),
- access to **`/dev/net/tun`**,
- a **`config.json`** mounted into its working directory (`/etc/subnetra`).

## Docker

```bash
docker pull ghcr.io/jamiesun/subnetra:latest

docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:latest
```

The image ships a Docker `HEALTHCHECK` that runs `subnetra status`, so
`docker ps` reports the container `healthy` once the daemon is serving its control
socket and `unhealthy` if it stops responding.

## Docker Compose

```yaml
services:
  subnetra:
    image: ghcr.io/jamiesun/subnetra:latest
    container_name: subnetra
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices:
      - /dev/net/tun
    volumes:
      - ./config.json:/etc/subnetra/config.json:ro
```

Apply the [host network plan](../configuration/network-plan.md) for the overlay on
the host or inside the container's network namespace as appropriate for your
topology.

## Kubernetes

Run it as a `DaemonSet` (or `Deployment`) with the capability and device. A
minimal container spec:

```yaml
securityContext:
  capabilities:
    add: ["NET_ADMIN"]
volumeMounts:
  - name: tun
    mountPath: /dev/net/tun
  - name: config
    mountPath: /etc/subnetra/config.json
    subPath: config.json
volumes:
  - name: tun
    hostPath: { path: /dev/net/tun, type: CharDevice }
  - name: config
    secret: { secretName: subnetra-config }   # config.json contains PSKs — use a Secret
```

The `HEALTHCHECK` maps cleanly to a liveness/readiness probe:
`exec: { command: ["subnetra", "status"] }`.

> Because `config.json` carries per-link **PSKs**, store it in a Kubernetes
> `Secret` (or a Compose/host file with `0600` permissions), never in a plain
> ConfigMap or image layer.

## Image internals

The `amd64`, `arm64`, and `arm/v7` images are built `FROM busybox:musl`: they carry
the two static binaries, `config.example.json`, and a tiny BusyBox shell plus core
utilities for in-container debugging. The daemon itself is fully static and needs
nothing from the base.

Because no musl BusyBox publishes `linux/arm/v5`, the `arm/v5` image is built
independently `FROM scratch` (still static musl, but without a debug shell) and
stitched into the same `:latest` / `:version` manifest. The build cross-compiles
with Zig pinned to `$BUILDPLATFORM`, so no QEMU emulation is needed. See the
[`Dockerfile`](https://github.com/jamiesun/subnetra/blob/main/Dockerfile).

## Offline / air-gapped

Devices that cannot reach a registry can `docker load` the per-arch image tarballs
attached to each release — see
[Installation → Offline install](../getting-started/installation.md#offline--air-gapped-install).

## RouterOS containers

MikroTik/RouterOS Container is a special case (it manages the container's Ethernet
side through a `veth`, and image import may need a legacy archive layout). It has
its own guide: [RouterOS Spoke](routeros.md).
