# BTunnel

[English](README.md) · **简体中文**

> 用**纯 Zig**（锁定 2026 最新标准库 `std.posix`）编写的虚拟三层（Layer 3）自适应组网工具。
> 面向通用 Linux 环境（含轻量级容器如 BusyBox / Container），零依赖、零动态分配、强隐蔽。

BTunnel 在物理专线之上构建虚拟子网，采用**星型拓扑（Hub-and-Spoke）**，通过私有 UDP 隧道
转发裸 IP 包。它**不依赖任何第三方网络框架**——TUN 网卡、加密、防重放、
策略引擎全部自研，最终产出一个完全静态链接的单二进制文件。

## ✨ 特性

- **零依赖单二进制**：基于 musl-libc 全静态链接，`ldd` 显示 `not a dynamic executable`，体积 ≤ 200KB。
- **分层零动态内存分配**：数据面（reactor / crypto）严格零分配，缓冲区启动时锁死在常驻内存。
- **单线程事件驱动反应堆**：基于 Linux epoll 边缘触发（`EPOLLET`），无锁、无并发竞争。
- **无状态混淆**：ChaCha20-Poly1305 全加密，密文无固定魔数，认证失败静默 Drop，对探测物理隐形。
- **传输安全**：PSK 预共享密钥 + 64-bit 单调递增 nonce（绝不复用）+ 滑动窗口防重放。
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
# 本机构建（默认 ReleaseSmall）
zig build --release=small

# 静态交叉编译
zig build --release=small -Dtarget=x86_64-linux-musl
zig build --release=small -Dtarget=aarch64-linux-musl

# 运行测试
zig build test

# 运行守护进程
zig build run
```

产物位于 `zig-out/bin/`：`btunnel`（守护进程）与 `ptctl`（控制工具）。

## 🚀 使用

```bash
# 启动守护进程（读取 config.json，缺失则用编译期缺省配置）
./zig-out/bin/btunnel

# 动态注入策略（通过 UDS 热更新，无需重启）
./ptctl policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
./ptctl policy show
./ptctl save
```

配置示例见 [`config.example.json`](config.example.json)。

## 📊 开发进度

当前为脚手架阶段：框架与纯算法层已落地并测试通过，系统调用密集部分为占位。

| 任务 | 模块 | 状态 |
|---|---|---|
| 1 编译配置 | `build.zig` | ✅ 完成（musl 静态、ReleaseSmall、双产物） |
| 2 配置自检 | `config.zig` | 🟡 部分（边界自检完成；JSON 解析占位） |
| 3 策略匹配 | `policy.zig` | ✅ 完成（CIDR / 最长前缀 / RCU） |
| 4 系统驱动 | `tun.zig` | 🔴 占位（TUNSETIFF ioctl 待实现） |
| 5 密码学管道 | `crypto.zig` | ✅ 完成（AEAD / nonce / 防重放） |
| 6 核心反应堆 | `reactor.zig` | 🟡 部分（报头 + egress 完成；epoll 主循环占位） |
| 7 控制面 UDS | `uds.zig` | 🟡 部分（分词器完成；socket 监听占位） |
| 8 控制工具 | `ptctl.zig` | 🟡 部分（参数校验完成；UDS 投递待实现） |

> **当前可验证**：`zig build test` 全绿（16/16），可产出 < 200KB 静态二进制。
> **联网端到端**待补齐：TUN ioctl（任务 4）、epoll 收发主循环（任务 6）、UDS 通信（任务 7/8）。

详细架构、内存模型与验收清单见 [`docs/btunnel-develop.md`](docs/btunnel-develop.md)。

## 📄 许可证

[MIT](LICENSE) © 2026 jettwang

---

> 🔁 本文件是 [`README.md`](README.md) 的中文镜像。
> **两者必须保持同步：修改任意一方时，需在同一次改动中更新另一方。**
