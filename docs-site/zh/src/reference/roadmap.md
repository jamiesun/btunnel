# 路线图

Subnetra 刻意交付一个小而完整的 **v1**，并预留一组狭窄的 **v2** 接口点。本页描述什么已交付、
什么被预留，以及——同样重要——什么 **永远不会** 被构建。

## v1 —— 已交付

发布的数据面是 `raw_direct`：一个无状态、零分配、无握手的隧道，具备：

- ChaCha20-Poly1305 全加密，含每链路密钥 + 每次重启的会话 epoch，
- 64-bit 单调 nonce + 滑动窗口防重放，
- CIDR 最长前缀策略引擎，带无锁 RCU 热更新，
- 单线程反应堆（Linux `epoll` / macOS `poll(2)`），
- 由已知答案向量钉死的规范[线协议](wire-protocol.md)。

逐模块进度见
[开发状态表](https://github.com/jamiesun/subnetra#-development-status)。

## v2 —— 仅预留接口点

PRD 为有损/长途专线预留了两个 **自研** 出口模式。它们今天 **仅为设计**——分支返回
`error.NotImplemented`，在维护者签署设计 RFC
（[`docs/v2-reliability-rfc.md`](https://github.com/jamiesun/subnetra/blob/main/docs/v2-reliability-rfc.md)）
之前不授权任何代码：

| 模式 | 思路 | 内层 MTU |
|---|---|---|
| `kcp_arq` | 基于 arena 的选择性重传 ARQ，吸收专线上小而零星的丢包（不用 `ikcp.c`——自研） | 1428 |
| `fec_xor` | 前向纠错（已知朴素 4:1 XOR 不够；真正的设计必须做得更好） | 1428 |

树中已存在的预留点：

| 预留 | 所在位置 |
|---|---|
| `EgressMode { raw_direct, kcp_arq, fec_xor }` | `src/reactor.zig`（v2 ⇒ `error.NotImplemented`） |
| `mtuFor(mode)` → 1452 / 1428 / 1428 | `src/reactor.zig` |
| `flags` 报头字节（v1 必须为 `0`，`KEEPALIVE` 除外） | `src/reactor.zig`、`docs/PROTOCOL.md` |
| `negotiation_version`（每配置） | `src/config.zig` |

关键在于：v2 模式由 **静态的每链路配置** 选择，绝非线上握手。`negotiation_version` / `flags`
字段仅用于 *静态* 模式选择。

## 明确的非目标

这些不是「暂未」——而是 **永不**，因为它们会破坏[设计原则](../concepts/design-principles.md)：

- **无线上握手 / 挑战应答 / 能力交换。** 每包 epoch *就是* 会话建立。
- **守护进程内无健康探测或自动切换路径管理器。** 数据面单路径；故障切换是 **外部** 决策
  （见 [生产部署 → 高可用](../operations/deployment.md)）。
- **无隧道内调度器 / 自适应速率控制器。** 流量整形在 OS 层用 `tc` 做。
- **无第三方依赖。** 即便 v2 可靠性也不行——ARQ 必须自研。
- **守护进程内无 DNS 解析器。** endpoint 是数字的；动态 Hub 在运维侧解决（Spoke 上的 DDNS
  监视器）。

更改任何非目标都是一个 **修订铁律的 RFC**，而非一个功能 PR——且有意不在待办之列。

## 保活例外（已在 v1 中）

`wire_version = 1` 下唯一的新增是单向、永不确认的 spoke→hub NAT 保活（`flags` bit 0）。它向后
兼容，且 **不是** 握手——见
[安全模型](../concepts/security-model.md)。
