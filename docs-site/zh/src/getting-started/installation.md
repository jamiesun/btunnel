# 安装

Subnetra 以 **单个静态二进制** 形式交付。无需系统级安装，也没有共享库需要管理——
按你的环境选择合适的交付方式即可。

| 方式 | 适用于 | 备注 |
|---|---|---|
| [容器镜像](#容器镜像) | Linux 主机、RouterOS / BusyBox 容器 | 多架构 `amd64 / arm64 / armv7 / armv5` |
| [发布二进制](#发布二进制) | 裸 Linux 主机、离线安装 | 同时提供可 `docker load` 的镜像 tar 包 |
| [macOS Spoke 二进制](#macos-spoke-二进制) | Apple Silicon / Intel Mac（仅 Spoke） | 由 Runbook 验收，未纳入 CI 门禁 |
| [从源码构建](#从源码构建) | 开发、自定义目标 | 需要 Zig 0.16.0+ |

无论采用哪种方式，守护进程在运行时都需要两样东西：**`NET_ADMIN`** 能力（用于创建
TUN 网卡）以及对 **`/dev/net/tun`** 的访问权。

## 容器镜像

带标签的发布会向 GHCR 推送多架构镜像，Docker 会自动选择正确的架构：

```bash
docker pull ghcr.io/jamiesun/subnetra:latest

# 守护进程需要 NET_ADMIN + TUN 网卡，并把 config.json 挂载到其工作目录
# （/etc/subnetra）。
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:latest
```

镜像内置 Docker `HEALTHCHECK`（`subnetra status`），因此当守护进程开始提供控制套接字
后，`docker ps` / Compose / Kubernetes 会报告其为 `healthy`，停止响应时报告
`unhealthy`。

`amd64`、`arm64` 与 `arm/v7` 镜像基于 `busybox:musl` 构建（内含两个静态二进制、
`config.example.json` 以及一个用于容器内调试的微型 BusyBox shell）。`arm/v5` 镜像基于
`scratch` 构建（仍为静态 musl，无调试 shell），并拼入同一份 `:latest` / `:version`
清单。Compose 与 Kubernetes 细节见 [容器](../operations/containers.md)。

## 发布二进制

每个发布（`vX.Y.Z`）都会附上 `amd64`、`arm64`、`armv7`、`armv5` 的 **静态二进制 tar
包**。Linux 二进制基于 musl-libc 全静态链接——`ldd` 显示 `not a dynamic executable`。

```bash
tar -xzf subnetra-<version>-linux-amd64.tar.gz
sudo install -m 0755 subnetrad subnetra /usr/local/bin/
subnetrad --version
```

> 安装前请务必用发布附带的 `SHA256SUMS.txt` 校验下载产物。

### 离线 / 隔离网络安装

无法访问容器仓库的设备，可使用每个发布附带的、按架构区分的可 `docker load` 镜像
tar 包（`subnetra-image-<version>-<arch>.tar.gz`）：

```bash
docker load < subnetra-image-v0.1.0-arm64.tar.gz   # -> ghcr.io/jamiesun/subnetra:v0.1.0
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:v0.1.0
```

## macOS Spoke 二进制

每个发布还附带原生 macOS 二进制，用于以 **Spoke** 身份运行 Subnetra——
`subnetra-<version>-macos-arm64.tar.gz`（Apple Silicon）与 `-amd64.tar.gz`（Intel）。
它们是 Mach-O 二进制，**仅链接 `libSystem`**（零第三方依赖）。

```bash
tar -xzf subnetra-<version>-macos-arm64.tar.gz
cd subnetra-<version>-macos-arm64
# Gatekeeper 会隔离下载的二进制——清除隔离属性（或从源码构建）：
xattr -d com.apple.quarantine subnetrad subnetra 2>/dev/null || true

./subnetra --print-network-plan --config config.json   # 预览主机网络规划
sudo ./subnetrad --config config.json                  # 创建 utun 需要 root
```

创建 `utun` 网卡以及应用 `ifconfig` / `route` 规划都需要 root。macOS 仅作为
**Spoke** 支持（Hub 仍保持 Linux/RouterOS）；见 [macOS Spoke](../operations/macos-spoke.md)
指南。

## 从源码构建

需要 **Zig 0.16.0** 及以上。

```bash
# 本机构建（默认 ReleaseSmall；本地开发可加 -Doptimize=Debug）
zig build

# 静态交叉编译
zig build -Dtarget=x86_64-linux-musl     # amd64
zig build -Dtarget=aarch64-linux-musl    # arm64
zig build -Dtarget=arm-linux-musleabihf  # armv7（硬浮点）
zig build -Dtarget=arm-linux-musleabi    # armv5（软浮点）

# 运行测试
zig build test

# 运行守护进程
zig build run
```

产物位于 `zig-out/bin/`：`subnetrad`（守护进程）与 `subnetra`（控制工具）。

> **ARMv5 注意：** ARMv5 没有硬件原子指令，因此标准库的线程化 I/O 脚手架会引用 musl
> 未提供的 legacy `__sync_*` 内建函数。由于 Subnetra 严格单线程，
> `src/atomic_shim.zig` 提供了一份可证明正确的普通（非原子）实现，在 comptime 处门控，
> **仅** 为 ARMv6 以前的目标编译进来——其他所有架构逐字节不受影响。

## 验证安装

```bash
# Linux：确认二进制全静态
ldd ./subnetrad          # -> "not a dynamic executable"
ls -lh ./subnetrad       # -> < 512 KB

# 任意平台：打印版本横幅
./subnetrad --version
```

下一步：前往 **[快速上手](quickstart.md)** 拉起一个 Hub 和一个 Spoke。
