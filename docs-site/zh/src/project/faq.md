# 常见问题

### 一句话说，Subnetra 是什么？

一款纯 Zig、零依赖的三层 UDP 隧道，产出小于 512 KB 的单个静态二进制，以星型叠加网连接站点
与设备，并对每条链路全加密。

### 它是 VPN 吗？和 WireGuard 有何不同？

它是三层加密叠加网，所以解决与 WireGuard 类似的问题。差异是刻意的权衡：

- **无握手。** Subnetra 无状态、无握手；每包 epoch 加静态配置取代了会话协商。没有 Noise
  握手、没有 rekey 定时器、没有漫游握手。
- **单个静态二进制、无内核模块、无第三方库**——它完全在用户态、在 TUN 设备上运行，并交叉编译
  到低至 armv5 的 musl 目标。
- **天生星型（Hub-and-Spoke）**，带二进制内 CIDR 策略引擎做站点间路由与 Hub 中继，热更新无需
  重启。

它不试图做 WireGuard 的即插即用替代品；它面向固定的、运维管理的部署，其中极小可审计的二进制
与静态拓扑是首要诉求。

### 和 n2n 有何不同？

两者都构建加密叠加网，但设计几乎相反：

- **星型，非 P2P。** n2n 的招牌是 supernode 协助的 NAT 打洞，让 edge 之间直连。Subnetra 是严格
  星型，并 **刻意不做 P2P / 打洞**——每个 Spoke 到 Spoke 的包都经 Hub 中继，换取单一可预测路径
  （一项[非目标](../reference/roadmap.md#明确的非目标)）。
- **三层，非二层。** n2n 是以太（TAP）叠加网，带广播、ARP 与任意协议。Subnetra 只按 CIDR 路由
  IPv4——没有广播域。
- **无握手、单一固定加密。** n2n 有注册协议、按 community 可选 cipher。Subnetra 无注册往返，只有
  一种强制 AEAD（ChaCha20-Poly1305），且每链路一把唯一密钥。
- **静态，非发现。** n2n 经 supernode 动态发现对端。Subnetra 用静态数字 endpoint，守护进程内无
  发现、无 DNS。

要即插即用的 P2P 与 L2 局域网语义，选 n2n；要极小、可审计、拓扑确定的单路径隧道，选 Subnetra。

### 为什么无握手？那不安全吗？

不。每个包都用每链路密钥经 ChaCha20-Poly1305 加密并认证。重放被 64-bit 单调 nonce 与滑动窗口
过滤器阻止，且每次重启的 **会话 epoch** 被混入密钥派生，使旧的捕获无法跨重启重放。「无握手」
意味着没有 *协商* 往返——不是说包未经认证。见 [安全模型](../concepts/security-model.md)。

### 它会隐藏自己是隧道吗？算「隐身」吗？

部分如此。混淆是 **无状态、尽力而为** 的：一个格式错误或未认证的数据报被静默丢弃、**无任何
错误回复**，因此监听者不会向盲扫描者暴露自己。Subnetra **不** 声称击败成熟的 DPI 对手，并对此
诚实——见 [设计原则 → 无状态混淆](../concepts/design-principles.md)。

### 支持哪些平台？

- **Linux** 是生产目标：`x86_64`、`aarch64`、`armv7`（硬浮点）、`armv5`（软浮点），全部静态
  musl。Hub 通常跑在 Linux 上。
- **macOS** 经原生 `utun` 设备作为受支持的 **Spoke / 开发** 平台（最小动态，仅链接 libSystem）。
  它不是生产 Hub 目标。

### 它有多大 / 多快？

Linux 发布二进制是单个静态 musl 可执行文件，**小于 512 KB**。数据面单线程、无锁，且热路径
**严格零分配**，所以内存使用有界且可预测。要在自己硬件上得吞吐基线，运行
[`test/integration/bench.sh`](https://github.com/jamiesun/subnetra/blob/main/test/integration/bench.sh)。

### 我该用什么 MTU？

固定线开销是 **64 字节**（20 字节报头 + 16 字节 tag + 28 字节外层 IPv4/UDP）。因此安全隧道
MTU 为 `path_mtu − 64`——例如 1500 字节承载上为 1452。据此设置 `local_tun_mtu`，并用
`subnetrad --print-network-plan --path-mtu <n>` 计算并预览主机规划。见
[主机网络规划](../configuration/network-plan.md)。

### Subnetra 会替我配置主机网络吗？

不会——按设计它 **只打印** 规划；绝不改动主机路由或防火墙状态。`subnetrad --print-network-plan`
输出确切的 `ip`/`route` 命令，让你（或你的配置管理工具）有意识、可审计地应用。守护进程确实会
创建并管理它自己的 TUN 设备。

### PSK 如何工作？两条链路能共用一把密钥吗？

每条 **链路**（每个对端对、每个方向）使用自己的 64 位十六进制预共享密钥。密钥必须 **每链路
唯一**——绝不要跨对端复用 PSK。用 `zig build tool:keygen` 生成。方向密钥从 PSK 派生，因此 A→B
与 B→A 两个方向使用不同密钥。

### 如何路由 Spoke 背后的真实 LAN（站点间）？

在 `remote_routes`/`local_routes` 中设置 LAN 前缀，并添加把目的前缀转发到正确网格 id 的策略
规则。Hub 在 Spoke 之间中继。见 [配置 → 角色](../configuration/roles.md) 与
[`policy add`](../reference/cli.md#policy-add-参数) 示例。

### 如何在 RouterOS / MikroTik 上运行？

通过 RouterOS **容器** 特性（设备上的静态二进制容器）。见
[运维 → RouterOS](../operations/routeros.md)。

### Hub 是动态 IP——怎么办？

endpoint 刻意是数字的（守护进程内无 DNS）。在运维侧解决：在 Spoke 上跑一个小型 DDNS 监视器，
重写 Hub `endpoint` 并重载。Spoke 的 NAT 保活让路径保持打开。见
[安全模型 → NAT 保活](../concepts/security-model.md)。

### 有内置的故障切换 / 多路径吗？

没有。数据面刻意单路径；故障切换是 **外部** 决策（VRRP / 健康检查 DNS / 编排）。这让守护进程
保持小而可预测。见 [部署 → 高可用](../operations/deployment.md#8-高可用) 与
[路线图](../reference/roadmap.md#明确的非目标)。

### v2（`kcp_arq` / `fec_xor`）何时到来？

那些是 **预留接口点**，仅为设计，在维护者批准设计 RFC 之前返回 `error.NotImplemented`。v1 只
交付 `raw_direct`。见 [路线图](../reference/roadmap.md)。

### 为什么用 Zig，为什么零依赖？

为了得到一个极小、静态链接、可审计的二进制，具备可预测内存且无供应链——整个数据面就是标准库
加裸系统调用。[设计原则](../concepts/design-principles.md)（「八条铁律」）完整解释了缘由。

### 权威规格在哪里？

规范的线上契约是
[`docs/PROTOCOL.md`](https://github.com/jamiesun/subnetra/blob/main/docs/PROTOCOL.md)；
产品需求是
[`docs/subnetra-develop.md`](https://github.com/jamiesun/subnetra/blob/main/docs/subnetra-develop.md)。
本站点对它们做摘要与运维化；若它们与本站点冲突，**以它们为准**。
