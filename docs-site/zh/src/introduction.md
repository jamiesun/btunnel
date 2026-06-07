# 简介

**Subnetra** 是一款纯 [Zig](https://ziglang.org/) 编写、零依赖的 **三层（Layer 3）UDP
隧道**，最终产出一个完全静态链接、体积小于 **512 KB** 的单二进制文件。

它在物理专线之上构建虚拟子网，采用 **星型拓扑（Hub-and-Spoke）**，通过私有的全加密
UDP 隧道转发裸 IP 包。它 **不依赖任何第三方网络框架**——TUN 网卡、加密、防重放、
策略引擎全部自研。

Subnetra 面向 **通用 Linux 环境**（含极度受限的容器，如 BusyBox / RouterOS Container），
并可在 **macOS 上作为 Spoke 原生运行**（`utun` + `poll(2)`）：零依赖、数据面零动态分配、
强隐蔽。

> 本文档站点为中英双语。使用顶栏的 **中文 / EN** 开关切换语言，或阅读
> [English documentation](https://jamiesun.github.io/subnetra/en/)。

## 为什么选择 Subnetra？

| 如果你需要…… | Subnetra 提供…… |
|---|---|
| 在 RouterOS / BusyBox 容器内运行隧道 | 一个 ≤ 512 KB 的静态 musl 单二进制，无任何共享库 |
| 专线上可预测的低延迟 | 单线程、零分配的数据面，无 GC、无抖动 |
| 抵御主动探测的隐蔽性 | ChaCha20-Poly1305 全加密，无魔数，认证失败静默 Drop |
| 分支之间的 Site-to-Site 路由 | CIDR 最长前缀策略引擎，RCU 热更新、无需重启 |
| 可复现、可审计的行为 | 一份带已知答案测试向量的[规范线协议](reference/wire-protocol.md) |

## 特性一览

- **零依赖单二进制**——基于 musl-libc 全静态链接；`ldd` 显示
  `not a dynamic executable`；体积 ≤ 512 KB。
- **分层零动态内存分配**——数据面（reactor / crypto）严格零分配，缓冲区在启动时
  锁死在常驻内存。
- **单线程事件驱动反应堆**——comptime 选择 Linux `epoll` 边缘触发（`EPOLLET`）
  或 macOS `poll(2)`；无锁、无并发竞争。
- **无状态混淆**——ChaCha20-Poly1305 全加密；密文无固定魔数；认证失败静默 Drop——
  对探测物理隐形。
- **传输安全**——每个对端独立的私有预共享密钥（每条 Hub 链路一把，绝非全网共享）
  + 每链路方向密钥 + 每次重启的会话 epoch + 64-bit 单调递增 nonce（绝不复用）
  + 每会话滑动窗口防重放。
- **无锁 RCU 热更新**——策略树以原子指针交换整体替换，热更新零拷贝、零抖动。
- **多网段策略引擎**——CIDR 最长前缀匹配，支持 Site-to-Site 路由。

## 数据通路五步

1. **TUN 入口**——从虚拟三层网卡读取裸 IPv4 包。
2. **加密封装**——在 20 字节私有报头上做 ChaCha20-Poly1305；失败静默 Drop。
3. **星型中继**——Hub 按策略中继到各 Spoke，绝不回送源端。
4. **策略路由**——CIDR 最长前缀匹配，RCU 热更新、无需重启。
5. **Spoke 出口**——校验 epoch、nonce、防重放与内层源地址后再投递。

## 如何阅读本文档

- 初次接触？从 **[安装](getting-started/installation.md)** 与
  **[快速上手](getting-started/quickstart.md)** 开始。
- 想理解设计？阅读 **[架构](concepts/architecture.md)** 与
  **[安全模型](concepts/security-model.md)**。
- 在写配置？查看 **[配置参考](configuration/reference.md)** 与
  **[角色](configuration/roles.md)**。
- 要上生产？跟随 **[生产部署](operations/deployment.md)**。
- 要做另一套实现？**[线协议](reference/wire-protocol.md)** 是规范契约。

## 项目状态

框架层、纯算法层与系统调用数据通路（TUN、就绪反应堆、AF_UNIX 控制面、守护进程主
循环）均已实现，并在开发容器中端到端跑通；macOS 原生 `utun`/`poll(2)` Spoke 由
comptime 的 `src/os/` 后端支撑。v1（`raw_direct` + PSK + 防重放 + RCU 策略）即交付物；
v2 可靠性模式（`kcp_arq`、`fec_xor`）仅为预留接口点——见
**[路线图](reference/roadmap.md)**。

## 许可证

[MIT](https://github.com/jamiesun/subnetra/blob/main/LICENSE) © 2026 jettwang。
