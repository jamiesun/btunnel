# 配置参考

守护进程从其工作目录读取单个 `config.json`（用 `--config <path>` 覆盖）。文件缺失时回退到
编译进二进制的默认值。解析器是严格的：未知结构、非法 CIDR 或越界取值都会导致
**失败即关闭** 的启动。部署前用 `subnetrad --check` 校验任何变更。

一个最小示例（`config.example.json`）：

```json
{
  "negotiation_version": 1,
  "local_tun_mtu": 1452,
  "listen_port": 51820,
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:51820", "allowed_src": "10.0.0.2/32", "name": "bj-office-gw", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:51820", "allowed_src": "10.0.0.3/32", "name": "colo-hub",     "psk": "…64 hex…" }
  ]
}
```

## 顶层字段

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `negotiation_version` | 整数 | `1` | 线/配置版本，v1 固定为 `1`。为未来 **静态** 的每链路传输模式选择预留——绝非线上握手。 |
| `local_tun_mtu` | 整数 | `1452` | 隧道 MTU，必须在 **68–1500** 内。默认值在 1500 字节承载上为 64 字节线开销留出余量。 |
| `listen_port` | 整数 | `51820` | 守护进程为承载绑定的本地 UDP 端口。 |
| `virtual_subnet` | CIDR | `10.0.0.0/24` | 本网格构建的叠加子网。 |
| `local_tun_ip` | CIDR | _(不设)_ | 本节点自身的 TUN 地址（主机 + 前缀），例如 `10.0.0.2/24`。仅用于生成[主机网络规划](network-plan.md)；守护进程 **不** 自行配置主机地址。 |
| `local_id` | 整数 | `0` | 本节点网格 id。必须 **非零**、可放入 `u16`（`1–65535`），且当 `peers` 非空时与每个对端 id 不同。`0` 表示「单节点 / 无网格」。 |
| `peers` | 数组 | `[]` | 配置的网格对端（固定容量、零分配）。见 [对端字段](#对端字段)。 |
| `role` | 字符串 | `"manual"` | `manual`、`hub` 或 `spoke`。控制启动策略推导——见 [角色](roles.md)。 |
| `local_routes` | CIDR 数组 | `[]` | `role=spoke`：本节点 **本地** 投递（到自身 TUN/主机）的子网。为空时使用 `local_tun_ip`（作为 `/32`）。 |
| `remote_routes` | CIDR 数组 | `[]` | `role=spoke`：**经由** Hub 可达的子网。为空时，Spoke 把 `virtual_subnet` 路由到 Hub。 |
| `keepalive_secs` | 整数 | 角色默认 | 内置 spoke→hub NAT 保活间隔。`0` 关闭（hub/manual 默认）。NAT 后的 `spoke` 默认 `20`。开启 `obfuscate` 时，每次间隔在 `[secs/2, secs]` 内随机化，使保活节奏不构成指纹。 |
| `obfuscate` | 布尔 | `true` | [报头混淆](https://github.com/jamiesun/subnetra/blob/main/docs/PROTOCOL.md)，**默认开启**：按包对 20 字节报头做 XOR 掩码，使数据报对被动观察者不可与随机串区分，并随机化 spoke 保活节奏。设 `false` 可关闭（改发可读的明文报头，例如抓包调试）。**必须在网格内所有节点上设置一致**（不协商；不一致则全部认证失败、fail-closed）。仅隐藏协议指纹，不隐藏包长或时序。 |

## 对端字段

`peers[]` 的每个条目：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | 整数 | — | 对端网格 id（非零、`u16`）。用于派生方向链路密钥，并作为线上 `key_id` 选择器。 |
| `endpoint` | 字符串 | — | 对端承载地址，形如 `host:port`，例如 `203.0.113.2:51820`。Hub 使用动态 DNS 时见[部署指南](../operations/deployment.md)。 |
| `allowed_src` | CIDR | `0.0.0.0/0` | 允许该对端发送的内层源范围。解密后内层 IPv4 源落在范围之外的包被丢弃（`spoof`）。**请显式设置**——宽松的默认值会关闭反伪造。 |
| `psk` | 十六进制串 | — | 本链路的 **私有** 32 字节预共享密钥（64 个十六进制字符）。必填、非零、**每链路唯一**。用 `openssl rand -hex 32` 生成。 |
| `name` | 字符串 | `""` | 可选的人类可读标签。过长或不可打印的值会被拒绝。 |

> **不存在全网 `psk`。** 每条链路携带自己的密钥。仍有顶层 `psk` 的配置以 `InvalidPsk`
> 拒绝；在多个对端间复用一把 PSK 以 `DuplicatePsk` 拒绝。

## 防呆自检

`config.zig` 在加载时（以及 `--check` 下）执行这些检查；任何失败都中止启动：

- **MTU 区间：** `local_tun_mtu` 必须为 68–1500。
- **子网重叠：** 虚拟子网不得与主机物理子网以会黑洞流量的方式冲突。
- **网格 id：** `local_id` 非零且与每个对端 id 不同。
- **唯一 PSK：** 没有 PSK 在对端间共享（`DuplicatePsk`）；没有顶层 `psk`（`InvalidPsk`）。
- **角色规则**（见 [角色](roles.md)）：
  - `hub` 拒绝 `allowed_src` 缺失/为 `0.0.0.0/0` 或与另一对端 `allowed_src` 重叠的对端。
  - `spoke` 要求恰好一个 Hub 对端、至少一个本地目标（`local_routes` 或 `local_tun_ip`），
    且没有 `0.0.0.0/0` 本地路由。

## MTU 与线开销

固定的每包开销是 **64 字节**：20 字节私有报头 + 16 字节 AEAD tag + 28 字节外层 IPv4/UDP。
因此安全隧道 MTU 为 `path_mtu − 64`。默认 `local_tun_mtu = 1452` 假设 1500 字节承载。在更小
的路径上（PPPoE、VPN 承载），请调低它——[主机网络规划](network-plan.md) 会为你计算并
**告警**。

## 配置与文档其余部分的衔接

- 从 `role` 推导启动策略：**[角色](roles.md)**。
- 把配置变成主机命令：**[主机网络规划](network-plan.md)**。
- 密钥/epoch/`allowed_src` 抵御什么：**[安全模型](../concepts/security-model.md)**。
- 叠加在本配置之上的运行时策略注入：**[命令行参考](../reference/cli.md)**。
