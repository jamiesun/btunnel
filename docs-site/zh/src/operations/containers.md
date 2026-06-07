# 容器

Subnetra 天生适合容器：守护进程是单个静态二进制，无共享库依赖。发布的镜像是多架构
（`amd64 / arm64 / armv7 / armv5`），Docker 会自动选择正确的一个。

## 要求

运行 `subnetrad` 的容器需要：

- **`NET_ADMIN`** 能力（创建 TUN 网卡），
- 对 **`/dev/net/tun`** 的访问，
- 挂载到其工作目录（`/etc/subnetra`）的一个 **`config.json`**。

## Docker

```bash
docker pull ghcr.io/jamiesun/subnetra:latest

docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:latest
```

镜像内置运行 `subnetra status` 的 Docker `HEALTHCHECK`，因此当守护进程开始提供控制套接字
后，`docker ps` 报告容器为 `healthy`，停止响应时为 `unhealthy`。

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

按你的拓扑，在主机上或容器网络命名空间内应用叠加网的
[主机网络规划](../configuration/network-plan.md)。

## Kubernetes

以 `DaemonSet`（或 `Deployment`）携带该能力与设备运行。一个最小容器规格：

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
    secret: { secretName: subnetra-config }   # config.json 含 PSK——用 Secret
```

`HEALTHCHECK` 可干净地映射到 liveness/readiness 探针：
`exec: { command: ["subnetra", "status"] }`。

> 因为 `config.json` 携带每链路 **PSK**，请把它存进 Kubernetes `Secret`（或权限 `0600` 的
> Compose/主机文件），绝不要放进普通 ConfigMap 或镜像层。

## 镜像内部

`amd64`、`arm64` 与 `arm/v7` 镜像基于 `busybox:musl` 构建：内含两个静态二进制、
`config.example.json`，以及一个用于容器内调试的微型 BusyBox shell 加核心工具。守护进程本身
完全静态，不需要基础镜像提供任何东西。

由于没有 musl BusyBox 发布 `linux/arm/v5`，`arm/v5` 镜像独立地基于 `scratch` 构建（仍为
静态 musl，但无调试 shell），并拼入同一份 `:latest` / `:version` 清单。构建用锁定到
`$BUILDPLATFORM` 的 Zig 交叉编译，因此无需 QEMU 模拟。见
[`Dockerfile`](https://github.com/jamiesun/subnetra/blob/main/Dockerfile)。

## 离线 / 隔离网络

无法访问仓库的设备可以 `docker load` 每个发布附带的、按架构区分的镜像 tar 包——见
[安装 → 离线安装](../getting-started/installation.md#离线--隔离网络安装)。

## RouterOS 容器

MikroTik/RouterOS Container 是特例（它通过 `veth` 管理容器的以太网侧，镜像导入可能需要
legacy 归档布局）。它有自己的指南：[RouterOS Spoke](routeros.md)。
