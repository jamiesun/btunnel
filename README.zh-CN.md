# BTunnel

**纯 Zig 编写、零依赖的三层 UDP 隧道，最终产出一个小于 512KB 的静态单二进制文件。**

[English](README.md) · **简体中文**

> 用**纯 Zig**（锁定 2026 最新标准库 `std.posix`）编写的虚拟三层（Layer 3）自适应组网工具。
> 面向通用 Linux 环境（含轻量级容器如 BusyBox / Container），零依赖、零动态分配、强隐蔽。

BTunnel 在物理专线之上构建虚拟子网，采用**星型拓扑（Hub-and-Spoke）**，通过私有 UDP 隧道
转发裸 IP 包。它**不依赖任何第三方网络框架**——TUN 网卡、加密、防重放、
策略引擎全部自研，最终产出一个完全静态链接的单二进制文件。

## ✨ 特性

- **零依赖单二进制**：基于 musl-libc 全静态链接，`ldd` 显示 `not a dynamic executable`，体积 ≤ 512KB。
- **分层零动态内存分配**：数据面（reactor / crypto）严格零分配，缓冲区启动时锁死在常驻内存。
- **单线程事件驱动反应堆**：基于 Linux epoll 边缘触发（`EPOLLET`），无锁、无并发竞争。
- **无状态混淆**：ChaCha20-Poly1305 全加密，密文无固定魔数，认证失败静默 Drop，对探测物理隐形。
- **传输安全**：PSK 预共享密钥 + 每链路方向密钥 + 每次重启的会话 epoch（每个进程生命周期派生全新会话密钥）+ 64-bit 单调递增 nonce（绝不复用）+ 每会话滑动窗口防重放。
- **无锁 RCU 热更新**：策略树以原子指针交换整体替换，热更新零拷贝、零抖动。
- **多网段策略引擎**：CIDR 逆序最长前缀匹配，支持 Site-to-Site 路由。

## 📦 项目结构

```
build.zig            双产物构建（btunnel 守护进程 + ptctl 控制工具），静态 musl 交叉编译
build.zig.zon        包清单
config.example.json  示例配置（复制为 config.json 使用）
src/
  root.zig     core 库，汇聚各模块
  config.zig   配置解析 + 防呆自检（MTU 区间 / 子网重叠）
  policy.zig   CIDR 解析 + 最长前缀匹配 + 无锁 RCU ActiveTree
  crypto.zig   ChaCha20-Poly1305 + 单调 nonce + 滑动窗口防重放
  reactor.zig  packed 私有报头 + egress 出口分发 + epoll 反应堆
  tun.zig      TUN 网卡系统驱动
  uds.zig      控制面 Unix 域套接字 + 指令分词器
  main.zig     btunnel 守护进程入口
  ptctl.zig    ptctl 控制工具入口
docs/
  btunnel-develop.md  系统需求与架构设计说明书（PRD & Architecture）
```

## 🛠 构建

需要 **Zig 0.16.0** 及以上。

```bash
# 本机构建（默认 ReleaseSmall；本地开发可加 -Doptimize=Debug）
zig build

# 静态交叉编译
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-linux-musl

# 运行测试
zig build test

# 运行守护进程
zig build run
```

产物位于 `zig-out/bin/`：`btunnel`（守护进程）与 `ptctl`（控制工具）。

## 🧪 本地集成测试（开发容器）

系统调用密集的数据通路（TUN 设备、epoll 反应堆、AF_UNIX 控制套接字）只能在
Linux 上运行，因此在 [`.devcontainer/`](.devcontainer/) 下提供了一个可复现的
Linux 容器。它**仅用于开发/测试**——最终交付物依然是单个零三方依赖的静态
musl 二进制。

可在支持开发容器的编辑器中直接打开该目录，或以无界面方式运行预检脚本：

```bash
# 构建 Linux 工具链镜像（Debian-slim + 锁定版 Zig 0.16.0）
docker build -t btunnel-dev -f .devcontainer/Dockerfile .

# 在容器内运行集成/预检脚本
docker run --rm --privileged --device=/dev/net/tun \
    -v "$PWD":/workspace btunnel-dev test/integration/run.sh
```

[`test/integration/run.sh`](test/integration/run.sh) 会在容器原生架构上构建
二进制，强制校验静态链接与 ≤ 512KB 约束，冒烟运行守护进程（`btunnel --check`），
交叉编译另一个 musl 架构，运行单元测试，最后运行**多点 + 中继端到端测试**：
在网络命名空间中搭建 3 节点 Hub-and-Spoke 星型拓扑（一个 Hub 中继 + 两个
Spoke），断言端到端投递 spoke-A → Hub（中继）→ spoke-B、链路加密（明文标记
不会泄漏到底层）、以及负载下 RCU 策略热更新不阻塞数据面。该测试需要
`--privileged` + `--device=/dev/net/tun`。

## 🚀 使用

```bash
# v1 强制要求非零 PSK（铁律 #5）。先生成密钥并写入 config.json：
cp config.example.json config.json
# 然后把 "psk" 设为 32 字节随机数（64 个十六进制字符），例如：
#   openssl rand -hex 32
# 没有合法 PSK，守护进程将拒绝启动（配置自检：InvalidPsk）。

# 启动守护进程（从工作目录读取 config.json）
./zig-out/bin/btunnel

# 动态注入策略（通过 UDS 热更新，无需重启）
./ptctl policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
./ptctl policy show
./ptctl save
```

配置示例见 [`config.example.json`](config.example.json)。

## 📊 开发进度

当前框架层、纯算法层与系统调用数据通路（TUN、epoll 反应堆、AF_UNIX 控制面、
守护进程主循环）均已落地，并在开发容器中完成端到端验证。

| 任务 | 模块 | 状态 |
|---|---|---|
| 1 编译配置 | `build.zig` | ✅ 完成（musl 静态、ReleaseSmall、双产物） |
| 2 配置自检 | `config.zig` | ✅ 完成（std.json 解析 + 十六进制 PSK + CIDR；边界熔断） |
| 3 策略匹配 | `policy.zig` | ✅ 完成（CIDR / 最长前缀 / RCU） |
| 4 系统驱动 | `tun.zig` | ✅ 完成（TUNSETIFF ioctl，非阻塞 L3 fd） |
| 5 密码学管道 | `crypto.zig` | ✅ 完成（AEAD / 每链路密钥 / 会话 epoch / 防重放） |
| 6 核心反应堆 | `reactor.zig`、`peer.zig` | ✅ 完成（epoll ET 主循环；多对端注册表 + 每链路独立密钥 + 每次重启的会话 epoch；封包转发、解封防重放、源端过滤、内层源地址绑定、Hub 中继） |
| 7 控制面 UDS | `uds.zig` | ✅ 完成（分词器 + AF_UNIX 数据报监听；原子 RCU 策略热替换，双缓冲） |
| 8 控制工具 | `ptctl.zig` | ✅ 完成（UDS 投递；`policy add` 即发即弃，`policy show`/`save` 读取守护进程回包；守护进程未运行时非零退出） |
| 9 守护进程主循环 + e2e | `main.zig`、`test/integration/run.sh` | ✅ 完成（接线 TUN + UDP + UDS + 反应堆；落地多点 + 中继网络命名空间端到端测试） |

> **当前可验证**：`zig build test` 全绿（Linux 开发容器内 46/46；macOS 宿主
> 35 通过 + 11 个仅 Linux 用例跳过），可产出 < 512KB 静态二进制。
> Linux 开发容器（[`.devcontainer/`](.devcontainer/)）提供集成/预检脚本
> （[`test/integration/run.sh`](test/integration/run.sh)），在两个 musl 目标上
> 强制校验静态链接与体积约束，**并运行一套真实的多点 + 中继端到端隧道测试**
> （网络命名空间中的 3 节点 Hub-and-Spoke 星型）：真实投递 spoke-A → Hub（中继）
> → spoke-B、链路加密、以及负载下的 RCU 策略热更新。

详细架构、内存模型与验收清单见 [`docs/btunnel-develop.md`](docs/btunnel-develop.md)。

## 📄 许可证

[MIT](LICENSE) © 2026 jettwang

---

> 🔁 本文件是 [`README.md`](README.md) 的中文镜像。
> **两者必须保持同步：修改任意一方时，需在同一次改动中更新另一方。**
