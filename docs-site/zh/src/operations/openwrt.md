# OpenWrt Spoke

本指南介绍如何在 **OpenWrt** 路由器（MIPS 或 ARM 家用/SOHO CPE）上、于 NAT 之后把
Subnetra 作为 **spoke** 运行，拨向一台公网 Linux **hub**。OpenWrt 天然契合：它本身就用
**musl**，静态二进制直接能跑；而一台位于 NAT 之后的路由器，正是 spoke 角色为之而生的场景。

可直接使用的 procd 服务见
[`deploy/openwrt/subnetrad.init`](https://github.com/jamiesun/subnetra/blob/main/deploy/openwrt/subnetrad.init)。

## OpenWrt 的不同之处

- **用 procd，不是 systemd。** 使用随附的 `/etc/init.d/subnetrad` init 脚本，而非
  [systemd 单元](deployment.md#4-作为服务运行)。
- **TUN 是内核模块。** 安装 `kmod-tun`，守护进程才能经 `/dev/net/tun` 创建其 `snr0` 设备。
- **BusyBox 用户态。** [`doctor.sh`](https://github.com/jamiesun/subnetra/blob/main/tools/doctor.sh)
  预检对 BusyBox 友好，可直接运行。
- **闪存小。** 每个二进制都远小于 512 KB，两个都能轻松放进 overlay（`/usr/sbin`、`/usr/bin`）。

## 选对二进制

Subnetra 按架构发布静态 musl tarball。用 `opkg print-architecture`（或 `uname -m`）把你的
路由器映射到对应包：

| OpenWrt target（举例） | `opkg` 架构 | Release tarball |
|---|---|---|
| ramips（mt7621 / mt7628），多数现代 MIPS | `mipsel_24kc` | `…-linux-mipsel.tar.gz` |
| ath79 / Atheros（大端 MIPS） | `mips_24kc` | `…-linux-mips.tar.gz` |
| mvebu / ipq40xx / sunxi（32 位 ARM） | `arm_cortex-a*` | `…-linux-armv7.tar.gz` |
| filogic / ipq807x / bcm27xx（64 位 ARM） | `aarch64_cortex-a*` | `…-linux-arm64.tar.gz` |

> **MIPS 字节序要分清。** `mipsel` 是小端（ramips 及多数现代设备）；`mips` 是大端
> （ath79/Atheros）。装错了会无法 exec。拿不准时查 `opkg print-architecture`。

## 安装

```sh
# 1. TUN 模块（一次性）
opkg update && opkg install kmod-tun

# 2. 解析最新 release + 你的架构，下载、校验、安装
ARCH=mipsel   # mipsel | mips | armv7 | arm64 之一（见上表）
VER=$(uclient-fetch -qO - \
        https://api.github.com/repos/jamiesun/subnetra/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
base="https://github.com/jamiesun/subnetra/releases/download/$VER"
cd /tmp
uclient-fetch -q "$base/subnetra-$VER-linux-$ARCH.tar.gz"
uclient-fetch -q "$base/SHA256SUMS.txt"
sha256sum -c SHA256SUMS.txt 2>/dev/null | grep "subnetra-$VER-linux-$ARCH.tar.gz: OK"
tar -xzf "subnetra-$VER-linux-$ARCH.tar.gz"

# 3. 放置二进制（守护进程进 sbin，客户端进 bin）
install -m 0755 "subnetra-$VER-linux-$ARCH/subnetrad" /usr/sbin/subnetrad
install -m 0755 "subnetra-$VER-linux-$ARCH/subnetra"  /usr/bin/subnetra
subnetrad --version
```

## 配置 spoke

把本节点的配置（含 PSK）放在 `/etc/subnetra/config.json`，root 属主、权限 `0600`。一个
把路由器 LAN 经隧道发布出去的最小 spoke：

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 7,
  "local_tun_ip": "10.0.0.7/24",
  "local_routes": ["10.0.0.7/32", "192.168.1.0/24"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

`spoke` 角色推导出什么见 [角色](../configuration/roles.md)；用
[`config-gen`](https://github.com/jamiesun/subnetra/tree/main/tools) /
[`keygen`](https://github.com/jamiesun/subnetra/tree/main/tools) 可生成一套带全新每链路
PSK 的 hub + spoke 配置。

```sh
mkdir -p /etc/subnetra
# （把配置拷进去，然后锁权限）
chmod 0600 /etc/subnetra/config.json
subnetrad --check --config /etc/subnetra/config.json   # 离线校验
```

## 安装 procd 服务

```sh
# 从 checkout 拷，或直接下载 raw 文件：
uclient-fetch -qO /etc/init.d/subnetrad \
  https://raw.githubusercontent.com/jamiesun/subnetra/main/deploy/openwrt/subnetrad.init
chmod 0755 /etc/init.d/subnetrad
/etc/init.d/subnetrad enable
/etc/init.d/subnetrad start
logread -e subnetrad        # 确认启动（且没在 --check 处失败）
```

init 脚本会在启动前先跑 `subnetrad --check`（配置错就快速失败，而不是 respawn 死循环），
保持守护进程被 respawn，并在网络配置 reload 时重启它。

## 应用主机网络计划

Subnetra **从不自己改路由**——只打印计划。预览后在服务起来之后再应用（`snr0` 设备只在守护
进程运行时存在）：

```sh
subnetra --print-network-plan --config /etc/subnetra/config.json
# 然后应用打印出的 ip/route 命令，例如：
ip link set snr0 mtu 1400 up
ip addr add 10.0.0.7/24 dev snr0
```

要让它在重启后仍生效，把等价配置加进 `/etc/config/network`（一个绑定 `snr0`、`proto none`
的 `interface` 加静态路由）或一个小的 hotplug 脚本——但路由应用始终放在 **OpenWrt 侧**，
绝不进守护进程。

## 验证

```sh
subnetra status                 # 对端、流量、按原因分类的丢包
sh doctor.sh                    # TUN / 能力 / 时钟 预检（BusyBox 可用）
ping -c3 10.0.0.1               # 经叠加网 ping 到 hub
```

## 拓扑提示

- **NAT 之后 = 理想 spoke。** 内置 NAT 保活（`role=spoke` 默认，`keepalive_secs = 20`）
  保持孔打开、保持 hub 学到的端点新鲜，因此漫游/CGNAT 变动的映射无需手工纠正即可保持可达。
- **有静态端口映射的路由器可做 hub。** 若这台 OpenWrt 有一组稳定公网 UDP 端口经 DNAT 映射
  到它的 `listen_ports`，它可以改跑 `role=hub`——见
  [Hub behind NAT](deployment.md#hub-位于-nat-之后静态端口映射)。
- **时间同步。** 会话密钥使用 `CLOCK_REALTIME` boot epoch 且 forward-only 排序，所以请运行
  `sysntpd` 并让时钟在启动前/时稳定（init 启动较晚，`START=95`）。见
  [生产部署](deployment.md) 的时间同步说明。
