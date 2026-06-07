# Subnetra 生产部署指南

> 本文是 [`deployment.md`](deployment.md) 的中文版，内容保持同步；如有出入，以英文版为准。

本指南部署一个公网 **Hub** 和两个位于 NAT 后的 **Spoke**，使各 Spoke 私有局域网内的主机能够通过 Hub 中继互相访问。Subnetra 以单一静态二进制发布，无运行时依赖，因此部署主要围绕配置、capabilities 和主机网络。

如果是 MikroTik/RouterOS Container 部署，除本指南外还需阅读
[`routeros-container.md`](routeros-container.md)。RouterOS 模型需要专门的 veth 路由和容器侧转发。

> 拓扑（v1）：单 Hub 的 hub-and-spoke。Hub 在各 Spoke 之间中继；Spoke 不做中继。
> Peer 的**身份**是由报文头 `key_id` 选中的逐 peer PSK（issue #34），而不是源端点：
> Spoke 的 UDP 端点是配置里的**引导（bootstrap）**值，但在收到一个通过认证的数据报后
> 会在运行时重新学习，因此处于 NAT 后/漫游的 Spoke 无需运维介入即可恢复。Hub 仍必须
> 拥有一个稳定、可达、每个 Spoke 都能到达的端点。

如需把 **macOS 主机作为 Spoke** 接入（原生 `utun`），服务化方式见下文 §4（launchd），
端到端真机验收流程见手册
[`macos-spoke-acceptance.md`](macos-spoke-acceptance.md)。Hub 与中继仍为 Linux/RouterOS；
macOS 仅作为 **Spoke** 支持。

## 0. 组件

| 节点     | Mesh id | Overlay IP   | Underlay 端点         | 私有局域网          |
|----------|---------|--------------|-----------------------|--------------------|
| Hub      | 1       | （仅中继）   | `203.0.113.1:51820`   | —                  |
| Spoke A  | 2       | `10.0.0.2/24`| NAT 后                | `192.168.10.0/24`  |
| Spoke B  | 3       | `10.0.0.3/24`| NAT 后                | `192.168.31.0/24`  |

示例配置就在本指南旁边：
[`deploy/hub.json`](../deploy/hub.json)、
[`deploy/spoke-a.json`](../deploy/spoke-a.json)、
[`deploy/spoke-b.json`](../deploy/spoke-b.json)。

## 1. 安装二进制

构建（或下载发布版）并安装静态二进制和控制工具：

```bash
zig build -Doptimize=ReleaseSmall
sudo install -m 0755 zig-out/bin/subnetrad /usr/local/bin/subnetrad
sudo install -m 0755 zig-out/bin/subnetra  /usr/local/bin/subnetra
```

`ldd /usr/local/bin/subnetrad` 应当报告 *not a dynamic executable*。

> **macOS：** 从[发布页](https://github.com/jamiesun/subnetra/releases/latest)下载
> `subnetra-<ver>-macos-<arch>.tar.gz`（或 `zig build`），用 `sudo install -m 0755`
> 把两个二进制装入 `/usr/local/bin`，再清除 Gatekeeper 隔离属性：
> `sudo xattr -d com.apple.quarantine /usr/local/bin/subnetrad /usr/local/bin/subnetra`。
> macOS 二进制为*最小动态链接*（Apple 不提供静态 libc），因此用 `otool -L`（而非 `ldd`）
> 验证——应当只显示 `/usr/lib/libSystem.B.dylib`。

## 2. 下发逐节点配置与密钥

Hub 与每个 Spoke 之间的每条**链路**都有自己**独立的**私有 PSK（共用一把全网 mesh 密钥会被拒绝）。
每条链路生成一把 32 字节密钥：

```bash
openssl rand -hex 32   # 64 个十六进制字符；每条 Hub<->Spoke 链路运行一次
```

- 链路 Hub(1)<->Spoke A(2)：**相同**的值放进 Hub 的 `peers[id=2].psk`
  和 Spoke A 的 `peers[id=1].psk`。
- 链路 Hub(1)<->Spoke B(3)：**不同**的值，放进 Hub 的 `peers[id=3].psk`
  和 Spoke B 的 `peers[id=1].psk`。

跨链路复用同一把 PSK 会被拒绝（`DuplicatePsk`）；缺失或非十六进制的 PSK 会被拒绝（`InvalidPsk`）。
示例配置里包含明显伪造的占位密钥（`aaaa…`、`bbbb…`），**仅用于让 `--check` 通过**——
部署前请逐一替换。

把每个节点的配置安装为 `/etc/subnetra/config.json`：

```bash
sudo mkdir -p /etc/subnetra
sudo install -m 0600 -o root -g root deploy/spoke-a.json /etc/subnetra/config.json
```

> **密钥处理（必须）：** 配置文件携带私有 PSK。它们必须 root 属主、`0600`（不可被所有人读取）。
> `/etc/subnetra` 本身应为 `0700`。切勿把真实配置提交到版本控制。

启动前先校验：

```bash
sudo subnetrad --check --config /etc/subnetra/config.json
# subnetra v… (mtu=1400, udp_port=51820, mode=raw_direct, local_id=2, peers=1) [config ok]
```

`--config` 是可选的；不指定时守护进程会从其工作目录读取 `./config.json`（或 `$SUBNETRA_CONFIG`）。
`subnetrad --version` 和 `subnetrad --help` 无需配置即可使用；无法识别的参数会被拒绝而不是被忽略。

## 3. 主机网络

subnetrad 创建 TUN 设备，但只**打印**（绝不应用）主机配置，这样你既保留零依赖保证，又能掌控路由。
为每个节点生成方案：

```bash
sudo subnetrad --print-network-plan           # 假设 1500 字节 underlay
sudo subnetrad --print-network-plan --path-mtu 1420   # 例如位于 PPPoE/另一层 VPN 之后
```

应用打印出来的 `ip` 命令（或粘贴进 systemd unit 的 `ExecStartPost` 钩子）。该方案还会报告该路径的
**安全隧道 MTU**，并在 `local_tun_mtu` 过大时发出警告——修正它可以避免经典的
“小包能通、大包传输卡死”故障。要让 LAN 到 LAN 的 TCP 在更小的路径 MTU 下存活，请应用打印出的
MSS-clamp 规则。

要实现 LAN 到 LAN 可达，通常还需在每个 Spoke 上开启转发，并把对端 LAN 路由经由 overlay：

```bash
sudo sysctl -w net.ipv4.ip_forward=1
# 在 Spoke A 上，通过隧道到达 Spoke B 的 LAN：
sudo ip route add 192.168.31.0/24 dev snr0
```

> **macOS：** `subnetrad --print-network-plan` 输出的是 `ifconfig`/`route` 方案，而非
> `ip …`。`utun` 名字由**内核分配**（`utunN`），因此请在守护进程启动**之后**、用 `[ready]`
> 横幅里的真实名字替换后再应用方案（见 §4 launchd 与验收手册）。subnetra 在任何平台都不会
> 自行改动路由。

## 4. 以服务方式运行

### Linux — systemd

安装 unit 并启动守护进程：

```bash
sudo install -m 0644 deploy/subnetrad.service /etc/systemd/system/subnetrad.service
sudo systemctl daemon-reload
sudo systemctl enable --now subnetra
```

该 unit 仅申请 `CAP_NET_ADMIN`，授予 `/dev/net/tun`，以 `ExecStartPre` 运行 `subnetrad --check`，
失败时重启，其余均做了沙箱限制（`ProtectSystem=strict`、`NoNewPrivileges`、受限地址族等）。
编辑注释掉的 `ExecStartPost` 行以匹配你的 `--print-network-plan` 输出。

日志进入 journal：

```bash
journalctl -u subnetrad -f
```

### macOS — launchd

在 macOS Spoke 上，用 `launchd` 托管守护进程。由于创建 `utun` 需要 root，它是一个**系统级**
守护进程（`/Library/LaunchDaemons`，以 root 运行），而非每用户的 LaunchAgent。安装
[`deploy/net.subnetra.subnetrad.plist`](../deploy/net.subnetra.subnetrad.plist)（配置按 §2
准备好——`/etc/subnetra/config.json`，root 拥有、`0600`）：

```bash
sudo install -m 0644 deploy/net.subnetra.subnetrad.plist \
    /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl enable  system/net.subnetra.subnetrad
# 较旧的 macOS：sudo launchctl load -w /Library/LaunchDaemons/net.subnetra.subnetrad.plist
```

该任务以 root 运行 `subnetrad --config /etc/subnetra/config.json`，异常退出时重启
（`KeepAlive.SuccessfulExit=false`，带节流——相当于 systemd 的 `Restart=on-failure`），
日志写入 `/var/log/subnetrad.log`。请先用 `subnetrad --check` 校验配置，避免坏配置反复崩溃重启。
从日志的 `[ready]` 横幅读取内核分配的接口名：

```bash
sudo tail -f /var/log/subnetrad.log
# subnetra v… (… mode=raw_direct …) tun=utun4 sock=/var/run/subnetra.sock [ready]
```

**主机网络方案需单独应用。** 与所有平台一样，守护进程只**打印**方案；在 macOS 上 `utunN`
名字由内核分配，因此请在守护进程启动**之后**、用横幅里的真实名字替换后再应用：

```bash
subnetrad --print-network-plan --config /etc/subnetra/config.json   # ifconfig/route 方案
sudo ifconfig utun4 inet 10.0.0.2 10.0.0.2 mtu 1400 up
sudo route add -net 10.0.0.0/24 -interface utun4
```

> `KeepAlive` 重启后可能落在**不同的** `utunN` 上；请重新读取横幅并重新应用方案。subnetra
> 刻意把路由留给你掌控（不自动改动路由），且 macOS 仅作为 **Spoke**。用
> `sudo launchctl kickstart -k system/net.subnetra.subnetrad` 重启、
> `sudo launchctl bootout system/net.subnetra.subnetrad` 停止并卸载。完整的真机验收流程见
> [`macos-spoke-acceptance.md`](macos-spoke-acceptance.md)。

## 5. 安装中继策略（Hub）

> **捷径（推荐）：** [`../deploy/`](../deploy/) 中的示例配置设置了
> `"role": "hub"` / `"role": "spoke"`，因此守护进程会在启动时**从配置推导出整套策略**——
> 你可以跳过本节。参见
> [README → Roles](../README.md#roles-auto-derive-the-policy-from-config-role)。
> 下面的手动步骤适用于 `"role": "manual"` 配置，或当你想在推导出的表上叠加额外规则时。

Hub 以空策略树启动；在运行时通过本地控制套接字安装中继/投递规则（热替换，无需重启）。
设置 `SUBNETRA_SOCK` 以匹配 unit（`/run/subnetra/subnetra.sock`）：

```bash
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
# 把 overlay 流量投递/中继到正确的 spoke：
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 3
sudo -E subnetra policy show
sudo -E subnetra save        # 持久化一个可重放的快照
```

在每个 Spoke 上，把目的为本地 overlay 地址的隧道流量投递到本地 TUN（target `0` = 本地）：

```bash
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0
```

## 6. 查看、排障、升级

```bash
sudo -E subnetra status      # peers、流量计数器，以及逐原因的丢包计数器
```

守护进程不在时 `subnetra status` 以非零退出。上升的丢包计数器直指原因：
`unknown_peer`（报文头 `key_id` 匹配不到任何已配置 peer）、
`auth_or_invalid`（PSK/epoch/wire 不匹配）、
`spoof`（内层源地址在 `allowed_src` 之外）、
`no_route`（无匹配策略）。每当一个已认证 peer 在新的 UDP 端点被观察到时（漫游/NAT 重映射——见 issue #34），
`endpoint_learned` 计数器上升。PSK 永远不会被打印。

**升级 / 回滚：** 安装新二进制并重启；on-wire 格式带版本号，且数据路径在重启之间是无状态的
（每个生命周期都派生出一个全新的 session epoch）。要回滚，重新安装上一版二进制并重启。
如有需要，重新应用保存的策略快照。

```bash
sudo install -m 0755 zig-out/bin/subnetrad /usr/local/bin/subnetrad
sudo systemctl restart subnetrad
```

> **时间同步（必须）。** 上述“每次重启一个全新 epoch”的特性依赖于正常的挂钟：session 密钥派生自
> 启动时从 `CLOCK_REALTIME` 采样的 boot epoch，且接收方对 session 做**仅向前**排序
> （更新的 epoch 取代更旧的）。当时钟读数早于 2024-01-01 时守护进程会 fail-closed，
> 但它**无法**检测一个在重启之间**倒退**的时钟。如果某节点以早于其上次启动的挂钟重启
> （例如没有电池供电的 RTC 且 NTP 尚未同步），它新的、更低的 epoch 会被每个 peer 拒绝，
> 直到对端时钟前进越过旧值——链路会静默黑洞，对端的 `auth_or_invalid` 丢包计数器（见上）攀升。
> **缓解：** 运行时间守护进程（`chrony` / `systemd-timesyncd`）；在没有 RTC 的硬件上，
> 让 `subnetrad.service` 排在 `time-sync.target` 之后（`After=time-sync.target` +
> `Wants=time-sync.target`），使时钟在重启之间单调。如果时钟确实发生过倒退，
> **重启受影响链路的两端**以在各自一侧强制刷新 epoch。这是无状态、无握手传输（铁律 #8）
> 一个被接受的、永久的取舍：协议内没有 epoch 交换来修复它，因此修复是运维层面的（保持时钟同步）。

## 7. 防火墙 / NAT 要求

- **Hub** 必须接受来自互联网、到其 `listen_port`（默认 `51820`）的入站 UDP。
- 每个 **Spoke** 只需要对 Hub 的 `ip:port` 有**出站** UDP 可达性；无需任何入站端口转发（由 spoke 发起）。
- 如果某个 spoke 的 NAT 映射发生变化，Hub 会从它下一个已认证数据报中重新学习该 spoke 的新端点
  （issue #34），因此回包会自动跟随。保持 **Hub** 端点稳定；始终由 spoke 发起。

### Hub 使用动态 IP（DDNS）

端点配置是数字 `IP:port`，且 endpoint learning 是**单向**的——Hub 能学到漫游的 spoke，
但 spoke 无法发现一个换了地址的 Hub（它要发出第一个包必须先有正确的目的地址）。因此守护进程
**不**解析主机名、也不在运行时重解析：一个守护进程内的实时 DNS 客户端会把解析器/线程/状态
拉进刻意保持极简、零依赖、单线程的数据面（铁律 #1/#3）。

常规答案是给 Hub 一个**稳定的公网 IP**（一台小 VPS）。如果你必须让 Hub 跑在**动态**地址后面，
就在每个 spoke 上用一个极小的 DDNS 监视脚本从运维层解决——无需任何守护进程改动。重启是
**无状态且廉价的**（每个生命周期都派生一个全新的 session epoch），所以"重新指向"只是改配置 + 重启：

```bash
# /usr/local/bin/subnetrad-ddns.sh —— 在每个 spoke 上用 systemd timer 每约 60s 运行一次
new=$(getent hosts hub.example.com | awk '{print $1}')
cur=$(grep -oE '[0-9.]+:[0-9]+' /etc/subnetra/config.json | head -1 | cut -d: -f1)
[ -n "$new" ] && [ "$new" != "$cur" ] && {
  sed -i "s/$cur/$new/" /etc/subnetra/config.json
  systemctl restart subnetrad        # 无状态重启：派生一个全新 epoch
}
```

只在启动时解析一次主机名**并不是** DDNS——它会漏掉启动之后的任何地址变化，而这正是本监视脚本
处理的情况。

## 8. 运营商跨区整形（Cross-ISP / cross-region traffic shaping）

在长距离、跨运营商或跨地域的链路上，抖动和丢包的主要成因**不是**隧道“被识别”，而是 underlay：
运营商互联拥塞、最后一公里排队、单流速率上限、突发 UDP。Subnetra 刻意是一个
**无状态、无握手、零分配的数据面**（铁律 #2、#3、#8）：它**不**提供隧道内调度器、
自适应速率控制器或自动切换的选路管理器，而且永远不会。下面所有整形都在
**操作系统层用 `tc`** 和标准内核工具完成——**无守护进程改动，无协议改动**。
内核在明文 `snr0` 设备上本来就能看到真实的内层五元组，让它去做它擅长的事。

> 这里的一切都是**可选的主机调优**。先测量（第 6 节，`subnetra status` 丢包计数器以及你的监控所采集的计数器），
> 一次只改一项，并保留回滚手段。不要不加判断地全部开启。

**1. 自己把出口限速，别让运营商替你粗暴限。** 一条以线速喷 UDP 的隧道，看起来恰恰就是运营商 QoS
要惩罚的东西。把你自己的出口整形到链路*稳定*吞吐的约 60–80%（实测它；别信销售数字）。
对一条稳定在约 80 Mbit/s 的链路，从 50–60 Mbit/s 起步：

```bash
# 在物理上行口平滑突发并钉死一个精确速率。
sudo tc qdisc replace dev eth0 root tbf rate 60mbit burst 512k latency 80ms
```

**2. 按 flow 做公平队列，让批量流量无法饿死交互流量。** 把它应用在**内层**设备（`snr0`）上，
那里内核能看到每一条真实 flow（DNS、SSH、RDP、一次 HTTP API 调用、一次备份）——
而不是应用在外层 UDP socket 上，那里一切都坍缩成一条 flow：

```bash
sudo tc qdisc replace dev snr0 root fq_codel target 5ms interval 100ms limit 2000
```

如果是在家庭/分支网关上自己做出口整形，CAKE 是一个很好的单 qdisc 替代
（它集成了整形 + AQM + 公平队列）：

```bash
sudo tc qdisc replace dev eth0 root cake bandwidth 60mbit
```

这件事——在明文设备上做内核公平队列——才是逐 flow 优先级的正确归宿。它取代任何“隧道内 QoS 调度器”：
操作系统本来就理解这些 flow，因此 Subnetra 绝不能在数据面里重造 `tc`。

**3. MTU 要保守，并 clamp MSS。** 叠加的 PPPoE / 云 VPC / 网桥跳数，加上 Subnetra 自身的
外层 IP/UDP + AEAD 开销，会缩小可用 MTU。不要从 1500 起步。使用守护进程自己的方案（第 3 节）——
它会打印该路径的安全隧道 MTU**以及** MSS-clamp 规则：

```bash
sudo subnetrad --print-network-plan --path-mtu 1280   # 稳定后再往上加
```

如果小包能通但大包传输卡死，几乎总是这个原因。

**4. 别指望公网路径尊重你的 DSCP。** 你可以在自己的局域网内标记交互流量，但运营商经常把奇怪的
DSCP 标记清零、忽略，或错误地引入异常路径。在公网出口归一化（清零）DSCP，
把优先级留在上面的本机队列里解决：

```bash
sudo iptables -t mangle -A POSTROUTING -o eth0 -j DSCP --set-dscp 0
```

**5. 多路径——如果你确实需要——保持静态且无状态。** 优先选择**同运营商**的 Hub 选址和分地域 Hub，
而不是让一个全国中心 Hub 去硬扛一条饱和的骨干——但要把这表达为**静态的逐链路/逐 spoke 配置和路由**，
由运维（或 `subnetra`）决定，**而不是**守护进程内的协议内健康探测或自动切换状态机（铁律 #8）。
如果你把一条链路扇出到多个端点，按**内层五元组**做哈希，让同一条 TCP 连接始终走同一条路径；
绝不要把一条连接的包跨多条路径分散乱序发送——乱序会把 TCP 拥塞控制打傻。

**6. 可靠性（KCP/FEC）是 v2 的静态配置选项——不是默认。** FEC 冗余能掩盖轻微丢包，
但在一条本就拥塞或被 QoS 的链路上，它会增加流量、甚至让情况更糟。它只由静态逐链路配置选择
（铁律 #8 / `AGENT.md` 中的“v1 vs v2”），绝不协商，绝不默认开启。

**判断该拧哪个旋钮（先读计数器）：**

- RTT 平稳但吞吐上不去 → 限速或单流瓶颈（第 1/5 项）。
- 负载下 RTT p95 飙升 → 排队/拥塞（第 2 项）。
- 大包丢、小包通 → MTU（第 3 项）。
- 同运营商好、跨运营商坏 → 是**路径**问题，不是协议——把 Hub 挪近（第 5 项），别往代码里改。
- 晚上坏、白天好 → 是拥塞时段，不是代码突然回归。

## 9. 对生产部署做基准测试（Benchmarking a live deployment）

第 8 节讲的是*调优*，这一节讲的是*测量*——从已部署的 overlay 上取得真实的 RTT 与
吞吐/pps 数字，并定位丢包。这里是对真实 mesh 的**现场测量**（真实 NAT/WAN、hub 中继、
跨操作系统的 spoke）；它刻意不同于 issue #97 所跟踪的、单机可复现的 CI 基线。用
`iperf3`（**主机**工具——绝不链接进守护进程，铁律 #1）和 `ping`，然后读守护进程自己的计数器。

> **被部署的守护进程保持原样。** `subnetrad` 始终以 `-O ReleaseSmall` 发布（铁律 #6）。
> 你测量的是已部署的二进制，**不要**为了端到端测试把它重编为 `ReleaseFast`。
> （`ReleaseFast` 构建只用于离线的密码学/转发微基准——`tools/crypto-bench`，以及 #101 的
> `forward-bench`。）

### 快速开始

`deploy/bench-overlay.sh` 驱动整套矩阵，且是只读的：

```bash
# 在目标端（例如 hub）——绑定到 overlay IP 起服务端，使只有隧道流量能到达它：
deploy/bench-overlay.sh serve 10.66.0.1

# 在对端（一个 spoke）——对目标跑 ping + iperf3 客户端矩阵：
deploy/bench-overlay.sh 10.66.0.1 -u -t 30
#   -u  额外跑 UDP 吞吐 + 64 字节小包 pps
#   -d <direct-ip>  额外跑一次直连（underlay）以计算隧道开销 %
```

### 或者手动逐项运行

```bash
# RTT / 抖动 / 丢包
ping -c 50 10.66.0.1

# 批量吞吐（先在 hub 上起服务端：iperf3 -s -B 10.66.0.1）
iperf3 -c 10.66.0.1 -t 30            # 单条 TCP 流
iperf3 -c 10.66.0.1 -t 30 -P 4       # 并行——把 hub 的单核上限压出来
iperf3 -c 10.66.0.1 -t 30 -R         # 反向（hub -> spoke 方向）

# 包速率 + 丢包
iperf3 -c 10.66.0.1 -u -b 0 -t 30        # UDP 无上限：抖动 + 丢包%
iperf3 -c 10.66.0.1 -u -b 0 -l 64 -t 30  # 64 字节包：小包 pps
```

**隧道开销。** 对 overlay IP 和对端的直连（underlay/公网）IP 各跑一次同样的单流测试；
吞吐之比就是隧道税（外层 IP/UDP + AEAD + 单线程 reactor）。`bench-overlay.sh -d <direct-ip>`
会替你算出来。

### 用守护进程的计数器定位丢包

`iperf3` 告诉你*丢了*包；`subnetra status`（第 6 节）告诉你丢在*哪里*。在一次运行前后各
快照一次，读增量（`bench-overlay.sh` 在 Linux 上会自动做）：

| 计数器（位于 `drops:`） | 增量非零意味着 |
|---|---|
| `udp spoof` | 内层源 IP 不在该 peer 的 `allowed_src` 内——前缀配错了 |
| `udp no_route` / `tun no_route` | 目的地没有策略条目——中继策略缺失/不全（第 5 节） |
| `udp unknown_peer` | 数据报的 `key_id` 匹配不到任何已配置 peer |
| `udp auth_or_invalid` | AEAD/重放/格式校验失败——密钥不匹配或被篡改 |
| `*_send_err` | 内核拒绝了发送——本节点的本地路由/MTU/缓冲问题 |
| `relay packets`（位于 `traffic:`） | 正在发生 hub 转发（在 hub 上属预期） |

一次干净的运行：traffic 计数器在涨，而 `drop_*` 计数器保持不动。如果 `iperf3` 报告丢包，
但**两端**的每个 `drop_*` 都不动，那丢包在 **underlay**（第 8 节），不在 subnetra。

> **macOS spoke：** `subnetra status` 按设计返回 `Unsupported`（控制客户端仅 Linux）。
> spoke 自身健康用 `deploy/mac-spoke-status.sh`；逐 peer 的 relay/drop/last_seen 计数器到
> **hub** 上查（`ssh <hub> 'sudo subnetra status'`）。

### 结合 MTU 解读结果

overlay MTU 为 **1452**（raw_direct）；内层负载不得超过它。经典特征——小包正常、大块传输卡死——
是 MTU/MSS 问题，不是吞吐问题（第 8 节第 3 项；另见 #98）。在你相信一个偏低的批量数字之前，
先用 `subnetrad --print-network-plan` 打印安全隧道 MTU 与 MSS-clamp 规则。
