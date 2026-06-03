# BTunnel 系统需求与架构设计说明书（PRD & Architecture）

本文件旨在为**高级 AI Agent（如 Claude 4.8 Opus）**提供完全闭环的系统上下文。文档采用**测试驱动开发（TDD）**导向，面向 **RouterOS Container（BusyBox 环境）**的极致克制场景，指导 Agent 独立完成从底层系统调用到控制面策略引擎的模块化编写。

## 一、系统愿景与核心约束（Vision & Constraints）

BTunnel 是一个用**纯 Zig（锁定 2026 最新标准库 `std.posix`）**编写的虚拟三层（Layer 3）自适应组网工具。系统专门优化用于海内外专线环境，彻底抛弃高开销的动态混淆，只追求极致的吞吐量与确定性。

### AI Agent 必须绝对遵守的底层铁律

1. **分层零动态内存分配（Layered Zero-Allocation）：** 内存约束按职责分层，禁止一刀切。
   - **数据面（reactor / crypto）：严格零分配。** 所有数据包缓冲区、转发路径必须在启动时通过 `FixedBufferAllocator` 锁死在静态常驻内存中，运行期禁止任何隐式或频繁的 `alloc` 与 `free`。这是性能叙事的核心，必须死守。
   - **控制面与可靠层（uds / policy 重建 / 未来的 KCP、FEC）：允许独立 arena。** 这些路径可在与数据面物理隔离的 arena 中分配，生命周期独立回收，不得污染数据面的常驻内存线。
   - 验收时的「RSS 波动 0 字节」仅针对数据面（`raw_direct`）压测成立；控制面热更新允许短暂、可回收的 arena 波动。
2. **单线程事件驱动反应堆（Reactor 模式）：** 严禁使用多线程（Thread）。必须基于 Linux epoll 边缘触发（`EPOLLET`）异步复用 `TUN_FD`、`UDP_FD` 和 `UDS_FD`。由于全程单线程，**数据面与控制面不存在并发竞争，禁止引入任何锁**；策略热更新通过原子指针交换（见下文 RCU 模型）实现。
3. **完全无状态混淆：** 传输层报文使用 ChaCha20-Poly1305 全加密。密文禁止包含任何固定魔数（Magic Number）。对端认证失败必须直接丢弃（Drop），不回发任何 TCP Reset 或 ICMP 报文，对外部探测实现物理隐形。
4. **传输安全铁律（密钥 / Nonce / 防重放）：** 隧道的命门，v1 必须落地，不得推迟。
   - **密钥：** v1 支持预共享密钥（PSK），config 中定义 `psk` 字段（32 字节，hex/base64）。握手协商留作 v2 接口，但 v1 报头与 config 结构必须预留协商版本字段。
   - **Nonce：** ChaCha20-Poly1305 在 FixedBuffer 场景下**绝对禁止固定或复用 nonce**，否则认证保证当场归零。每端维护一个独立的 64-bit 单调递增计数器作为 nonce 来源，发送即自增，重启后从持久化或随机高位续接，杜绝跨会话复用。
   - **防重放：** 接收端维护滑动窗口（如 64 位 bitmap）校验序列号，窗口外或已见过的序列号一律 Drop。UDP 无状态传输必须配防重放，否则历史密文可被重放注入内网。
5. **单二进制产物：** 编译产物必须是完全静态链接的独立二进制文件（基于 musl-libc）。体积口径统一为：使用 `-O ReleaseSmall` 时目标 **≤ 512KB**，整体 Docker 镜像压缩在 **4MB** 以内。（若为追求吞吐改用 `ReleaseFast`，则放宽体积上限并在 `build.zig` 注释中标注权衡。）

## 二、完整系统架构设计（System Architecture）

### 1. 网络拓扑与虚拟层数据流

系统采用**星型拓扑（Hub-and-Spoke）**。海外中继节点作为 Hub，各 Spoke 客户端（如 RouterOS 容器）通过私有 UDP 隧道接入，在物理专线之上构建虚拟 `10.0.0.0/24` 子网，并支持跨网段（如 `192.168.1.0/24`）的 Site-to-Site 路由。

```text
[局域网流量] -> [RouterOS 内核] -> (路由指向 tun0) -> [/dev/net/tun]
                                                          |
    +----------------------------------------------------+
    | (非阻塞 epoll 边缘触发读取裸 IP 包)
    v
[BTunnel 核心反应堆]
    |
    ├── 1. 读取原始 IP 头 (提取 Src IP / Dst IP)
    ├── 2. 原子加载 active_tree 指针 (无锁只读，判定 FORWARD 或 DROP)
    ├── 3. 组装私有报头 (packed struct：含 8B 序列号/nonce)
    ├── 4. 经 egress 分发出口 (v1 仅 raw_direct；KCP/FEC 为 v2 预留分支)
    └── 5. ChaCha20-Poly1305 加密 (nonce=序列号，追加 16B Tag)
    |
    v
[物理 UDP 套接字] -> (公网专线隧道传输，延时 < 100ms) -> [海外中继 Hub]
```

### 2. 关键内存模型

- **私有报头：** 使用 Zig packed struct 物理对齐。报头需容纳：1 字节版本/标志位、（预留）协商字段、**8 字节单调递增序列号（兼作 ChaCha20-Poly1305 的 nonce 与防重放依据）**。原先的 4 字节设计不足以承载序列号，报头长度按字段重新核算（建议 12～16 字节，最终以 packed struct 实际对齐为准）。
- **并发控制（无锁 RCU 模型）：** 全程单线程，**不使用任何锁**。策略树以 `*const PolicyTree` 形式被数据面原子只读（`@atomicLoad`）。控制面 UDS 注入规则时，在独立 arena 中**构建一棵全新的树**，构建完成后用一次 `@atomicStore` 将 `active_tree` 指针整体交换（RCU 思路）；旧树在下一轮事件循环空闲时回收。数据面从头到尾只读一个不变指针，热替换零拷贝、零抖动。

## 三、功能清单与实现规范（Feature List）

### 模块 1：数据面核心反应堆（Data-Plane Reactor）

- [ ] **TUN 网卡异步挂载：** 通过原生系统调用打开 `/dev/net/tun`，利用 ioctl 实例化虚拟网卡，设置 `O_NONBLOCK`。
- [ ] **epoll 盲转引擎：** 统一调度 `TUN_FD` 与外网 `UDP_FD`，使用 `MSG_DONTWAIT` 循环读尽内核缓冲区，精确捕获并处理 `EWOULDBLOCK`。
- [ ] **自适应多模式流控（接口预留，分期实现）：** 出口统一经 `egress(mode, pkt)` 分发（tagged-union / vtable），新增模式只填分支，不动主循环。
  - **v1（必交付）** `raw_direct`：跳过所有重传，MTU 设为 1452 字节。
  - **v2（Roadmap，接口预留，分支暂 `return error.NotImplemented`）** `kcp_arq`：在控制/可靠层 arena 中**自研** arena 版 ARQ（不引入 ikcp.c 等第三方 C 库，避免其内部 malloc 与零分配铁律冲突），消化专线微小丢包，MTU 设为 1428 字节。
  - **v2（Roadmap）** `fec_xor`：自研前向纠错。注意：4:1 XOR 仅能恢复「每 5 包恰好丢 1 包」，对连续丢包无效，v2 设计时需重新评估纠错策略（如更高冗余或交织）。

### 模块 2：多网段命令行策略引擎（Policy Engine & CLI）

- [ ] **CIDR 动态解析：** 支持将 `"192.168.1.0/24"` 字符串高效解析为 u32 网络号与掩码。
- [ ] **Unix Domain Socket（UDS）通信：** 守护进程监听 `/var/run/btunnel.sock`。
- [ ] **独立控制工具 ptctl：** 20KB 的轻量客户端，通过 UDS 向主进程动态发送明文指令：
  - `ptctl policy add --src X --dst Y --action forward --target Z`
  - `ptctl policy show`
  - `ptctl save`（触发主进程将当前内存策略树序列化覆写回配置文件）

### 模块 3：启动与配置快照模块（Configuration Snapshot）

- [ ] **std.json 安全吞入：** 启动时一次性解析 `config.json`，若文件缺失，自动加载 comptime 编译期硬编码的缺省底盘配置。
- [ ] **防呆边界自检（Sanity Check）：** 强制校验 MTU 是否在合理区间（68 ～ 1500），自动检查虚拟子网与 ROS 宿主机物理子网是否重叠，异常则熔断启动。

## 四、开发任务清单（Task Backlog）

AI Agent 需按照以下原子任务顺序，采用 **TDD 模式**逐步推进：

- [ ] **任务 1（编译配置）：** 编写 `build.zig`。支持 `-target x86_64-linux-musl` 和 `-target aarch64-linux-musl` 的全静态交叉编译。默认 `-O ReleaseSmall` 剔离调试信息、精简体积（目标 ≤ 512KB）。
- [ ] **任务 2（配置自检）：** 编写 `config.zig`。实现 JSON 解析器与编译期备用配置，定义 `psk` 与协商版本字段。编写测试用例验证非法的 MTU 输入能正确被拦截。
- [ ] **任务 3（策略匹配）：** 编写 `policy.zig`。定义 `PolicyEntry` 结构体，实现基于位运算（`ip & mask`）的逆序最长前缀匹配。**不加锁**；策略树以 `*const PolicyTree` 提供原子只读接口与一个 `swap(new_tree)` 原子指针交换接口（RCU），通过「热替换后旧指针仍可安全读取」的单元测试。
- [ ] **任务 4（系统驱动）：** 编写 `tun.zig`。使用最新的 `std.posix` 进行 ioctl 系统调用，完成虚拟网卡的无依赖初始化。
- [ ] **任务 5（密码学管道）：** 编写 `crypto.zig`。封装 `std.crypto.stream.chacha20.ChaCha20Poly1305`，实现固定大小切片（Slice）的加密与认证，运行时无内存分配。**Nonce 由每端 64-bit 单调递增计数器派生，绝不复用**；接收端实现滑动窗口防重放校验。
- [ ] **任务 6（核心反应堆）：** 编写 `reactor.zig`。构建单线程 `epoll_wait` 闭环状态机。分别处理 TUN 可读、UDP 可读、UDS 可读事件，实现底层数据的非阻塞盲转；出口走 egress 分发（v1 仅 `raw_direct`）。
- [ ] **任务 7（控制面 UDS）：** 编写 `uds.zig`。建立本地 Unix 域套接字监听器，编写字符串 Token 分词器，在 arena 中重建策略树后调用 `policy.zig` 的原子 swap 接口（无锁注入）。
- [ ] **任务 8（控制工具）：** 编写 `ptctl.zig`。编写精简的分支控制逻辑，负责将终端命令行参数打包成文本流通过 UDS 掷给主进程。

> **分期说明：** v1 仅交付 `raw_direct` 数据面 + PSK 加密 + 防重放 + RCU 热更新策略。`kcp_arq` / `fec_xor` / 握手协商为 v2 Roadmap，仅预留 `egress` 分支与报头协商字段，不在 v1 实现。

## 五、TDD 测试用例与验收清单（Acceptance Criteria）

Agent 必须通过以下测试用例和现实场景校验，方可宣布交付：

### 1. 单元测试覆盖要求（Unit Tests）

在开发期间，Agent 必须通过执行 `zig test src/main.zig` 跑通以下断言：

- **`test "JSON Parser & Sanity Check"`**：输入 `local_tun_mtu: 9000` 触发断言错误；输入非法 JSON 触发解析终止。
- **`test "CIDR Overlap & Matching"`**：验证规则树中，当同时存在 `0.0.0.0/0`（DROP）和 `192.168.2.0/24`（FORWARD）时，目标为 `192.168.2.100` 的流量必须命中 FORWARD，目标为 `8.8.8.8` 的流量必须命中 DROP。
- **`test "RCU Hot-Swap"`**：在数据面持有旧 `active_tree` 指针期间执行一次 `swap(new_tree)`，旧指针仍能安全读出原规则，新读取命中新规则，且全程无锁、无数据面分配。
- **`test "Crypto Invariance"`**：验证 1000 次随机生成的裸 IP 包经过 encrypt 后长度精确增加 16 字节（Tag），且经过 decrypt 后明文绝对一致。
- **`test "Nonce Monotonic & Anti-Replay"`**：验证连续加密的 nonce 严格递增且不重复；接收端对窗口外或已见过的序列号必须 Drop，乱序但在窗口内的序列号必须接受。

### 2. 运行时终极验收清单（Runtime Checklist）

- [ ] **无依赖校验：** 在 Linux 终端执行 `ldd ./btunnel`，输出结果必须显示 `not a dynamic executable`（纯静态链接）。
- [ ] **体积校验：** 执行 `ls -lh ./btunnel`，二进制产物体积必须小于 **512KB**。
- [ ] **内存不泄露校验：** 将程序部署在 BusyBox 容器内，使用 `top` 或 `pmap` 监控其常驻内存（RSS）。在专线跑满千兆带宽（大包压测）10 分钟后，内存线必须是一条绝对平直的直线，波动为 **0 字节**。
- [ ] **主动探测防封锁校验：** 使用第三方工具（如 `nc -u`）向运行中的 BTunnel 中继服务器 UDP 端口发送非法的二进制垃圾数据（含重放旧密文），中继服务器的 CPU 必须无异常波动，且网络抓包显示对端**没有回复任何数据包（完美 Drop）**；重放包必须被滑动窗口拦截。
- [ ] **动态策略热更新校验：** 在网络运行中，执行 `./ptctl policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3`，上层正在进行的 TCP 吞吐测试延迟抖动不得超过 **2ms**，证明原子指针交换（RCU）与非阻塞事件反应堆的零拷贝热替换工作完美。

---

**Punchline（给 Agent 的终极提示）：** 保持代码的纯粹。拒绝任何第三方网络框架（包括 ikcp.c），v2 的可靠层也须自研 arena 版 ARQ，紧抱最新的 `std.posix`。记住：v1 只交付 `raw_direct` 数据面 + PSK 加密 + 防重放 + RCU 热更新，KCP/FEC/握手仅预留接口。当你准备好构建这个完美契合 RouterOS 容器的底层钢铁管道时，请先从生成任务 1 的 `build.zig` 和任务 2 的配置自检单元测试代码开始。
