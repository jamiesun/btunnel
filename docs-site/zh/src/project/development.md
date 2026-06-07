# 开发

Subnetra 用 **纯 Zig** 编写，**零第三方依赖**——只有标准库与经 `std.posix` 的裸系统调用。
本页讲解构建、测试与本地集成测试框架。

## 前置条件

- **Zig 0.16.0** 或更高。
- 用于特权集成测试框架：一台 Linux 主机（或提供的开发容器），具备 `/dev/net/tun` 与
  `--privileged`。

## 构建与测试

```bash
# 本机构建（默认 ReleaseSmall；本地开发用 -Doptimize=Debug）
zig build

# 静态交叉编译到每个发布目标
zig build -Dtarget=x86_64-linux-musl     # amd64
zig build -Dtarget=aarch64-linux-musl    # arm64
zig build -Dtarget=arm-linux-musleabihf  # armv7（硬浮点）
zig build -Dtarget=arm-linux-musleabi    # armv5（软浮点）

# 单元测试（任何提交前必须保持绿色）
zig build test

# 运行守护进程
zig build run
```

产物落在 `zig-out/bin/`：`subnetrad` 与 `subnetra`。

### 有用的构建步骤

| 步骤 | 作用 |
|---|---|
| `zig build test` | 运行单元测试 |
| `zig build vectors` | 把线协议一致性向量（JSON）打印到 stdout |
| `zig build tools-test` | 运行 `tools/` 工具的单元测试 |
| `zig build tool:keygen` | 构建/运行每链路 PSK 生成器 |
| `zig build tool:config-lint` | 构建/运行离线配置校验器 |
| `zig build tool:wire-decode` | 构建/运行离线数据报解码器 |

## 项目布局

| 路径 | 用途 |
|---|---|
| `build.zig`、`build.zig.zon` | 双二进制构建（守护进程 + 控制工具），静态 musl 交叉编译；版本在 `.version` 单一来源 |
| `src/config.zig` | 配置解析 + 防呆自检 |
| `src/policy.zig` | CIDR 最长前缀匹配 + 无锁 RCU `ActiveTree` |
| `src/crypto.zig` | ChaCha20-Poly1305、单调 nonce、防重放 |
| `src/reactor.zig` | 线报头、出口分发、就绪反应堆 |
| `src/peer.zig` | 每对端 endpoint + 加密注册表 |
| `src/os/` | comptime OS 后端：`linux.zig`（epoll + `/dev/net/tun`）、`darwin.zig`（`poll(2)` + `utun`）、`mod.zig`（选择器） |
| `src/uds.zig` | 控制套接字 + 指令分词器 |
| `src/stats.zig` | 数据面计数器 |
| `src/netplan.zig` | `--print-network-plan` 生成器 |
| `src/main.zig`、`src/subnetra.zig` | 守护进程 / 控制工具入口 |
| `tools/` | 树外辅助工具（绝不打进守护进程） |
| `docs/` | 设计文档、规范协议、部署与 RFC |

## 测试驱动工作流

纯逻辑随附测试。PRD 的验收测试包括 JSON/防呆检查、CIDR 重叠/匹配、RCU 热替换安全、加密不变量
（密文恰好增长 16 字节 tag），以及 nonce 单调 / 防重放行为。线协议由从活代码生成的 **已知答案
向量**（`zig build vectors`）钉死，并在 `zig build test` 中有漂移哨兵。

## 本地集成测试（开发容器）

特权 Hub-and-Spoke 测试框架仅限 Linux，因此在
[`.devcontainer/`](https://github.com/jamiesun/subnetra/tree/main/.devcontainer)
下提供一个可复现的 Linux 容器。它仅是开发/测试辅助——发布产物仍是单个静态 musl 二进制。

```bash
# 构建 Linux 工具链镜像（Debian-slim + 锁定 Zig 0.16.0）
docker build -t subnetra-dev -f .devcontainer/Dockerfile .

# 运行集成 / 预检测试框架
docker run --rm --privileged --device=/dev/net/tun \
    -v "$PWD":/workspace subnetra-dev test/integration/run.sh
```

[`test/integration/run.sh`](https://github.com/jamiesun/subnetra/blob/main/test/integration/run.sh)
构建二进制、强制静态链接与 ≤ 512 KB 约束、冒烟运行守护进程、交叉构建另一个 musl 架构、运行
单元测试，然后跨网络命名空间运行一个 **3 节点 Hub-and-Spoke 端到端测试**：真实投递
spoke-A → Hub(中继) → spoke-B、线上加密（承载上无明文泄漏）、负载下不停顿的 RCU 策略热更新、
诚实的 drop 计数、承载丢包（netem）下的韧性与完全恢复，以及端点漫游 / NAT 重映射。

吞吐/PPS 基线见同级的
[`test/integration/bench.sh`](https://github.com/jamiesun/subnetra/blob/main/test/integration/bench.sh)，
它搭起同样的星型、用 `-Doptimize=ReleaseFast` 构建（仅测量），并从每个守护进程自己的计数器读取
达成的 pps / Gbps / Hub-CPU%。

## 贡献原则

Subnetra 受一份严格的运营契约
（[`AGENT.md`](https://github.com/jamiesun/subnetra/blob/main/AGENT.md)）治理。简言之：做外科手术
式、目标对齐的变更；保持 `zig build test` 绿色；维护零依赖、单线程、（数据面）零分配、无握手
不变量；并在宣布任务完成前验证二进制仍静态链接且在体积预算之内。见
[设计原则](../concepts/design-principles.md)。
