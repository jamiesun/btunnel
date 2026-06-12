# 快速上手

本指南拉起最小*可用*的网格：**一个 Hub** 与 **两个 Spoke**，构建一个虚拟的
`10.0.0.0/24` 叠加网。两个 Spoke 才能体现 Hub 的价值——它在两个 Spoke 之间**中继**
流量，而 Spoke 彼此之间从不直接通信。假设你已安装 `subnetrad` 守护进程与 `subnetra`
控制工具（见 [安装](installation.md)）。

全文中：Hub 的公网地址为 `203.0.113.1:18020`，Spoke **A**（叠加网 `10.0.0.2`）为
`203.0.113.2`，Spoke **B**（叠加网 `10.0.0.3`）为 `203.0.113.3`。

## 1. 生成每链路密钥

每条链路都需要 **自己的** 32 字节预共享密钥（64 个十六进制字符）。绝不要在多个对端
之间复用同一把密钥——所以这个两链路的网格需要 **两把** 密钥：

```bash
openssl rand -hex 32   # → KEY_A，用于 Hub ↔ Spoke-A 链路
openssl rand -hex 32   # → KEY_B，用于 Hub ↔ Spoke-B 链路
```

## 2. 编写配置

最简单的方式是设置一个 [`role`](../configuration/roles.md)，让守护进程在启动时自动
推导转发策略。

**Hub**（`203.0.113.1` 上的 `config.json`）—— 列出两个 Spoke：

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "listen_ports": [18020, 18023, 18026],
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:18020", "allowed_src": "10.0.0.2/32", "psk": "…KEY_A…" },
    { "id": 3, "endpoint": "203.0.113.3:18020", "allowed_src": "10.0.0.3/32", "psk": "…KEY_B…" }
  ]
}
```

**Spoke A**（`203.0.113.2` 上的 `config.json`）：

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…KEY_A…" }
  ]
}
```

**Spoke B**（`203.0.113.3` 上的 `config.json`）—— 同样的结构，换成自己的 id 与地址：

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 3,
  "local_tun_ip": "10.0.0.3/24",
  "local_routes": ["10.0.0.3/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…KEY_B…" }
  ]
}
```

每条**链路**各有自己的 PSK：`KEY_A` 由 Hub 的 peer 2 与 Spoke A 共享；`KEY_B` 由 Hub
的 peer 3 与 Spoke B 共享——两把密钥互不相同。Spoke 无需配置 `listen_ports`（`spoke`
只绑定单个默认端口）。每个字段详见 [配置参考](../configuration/reference.md)。

## 3. 运行前校验

`--check` 解析配置、运行全部防呆规则，并在不触碰网络的情况下退出：

```bash
subnetrad --check --config config.json
# Spoke A: subnetra v… (mtu=1452, udp_ports={ 18020 }, mode=raw_direct, local_id=2, peers=1) [config ok]
# Hub:     subnetra v… (mtu=1452, udp_ports={ 18020, 18023, 18026 }, mode=raw_direct, local_id=1, peers=2) [config ok]
```

## 4. 打印并应用主机网络规划

守护进程会创建 TUN 网卡，但 **不会** 配置主机地址、路由或 MTU（那会破坏零依赖保证）。
改为让它打印出确切的命令：

```bash
subnetrad --print-network-plan --config config.json
```

检查输出的 `ip link` / `ip addr` / `ip route` 命令并执行（macOS 上输出 `ifconfig` /
`route`）。细节（包括安全 MTU 如何计算）见
[主机网络规划](../configuration/network-plan.md)。

请在**每个 Spoke** 上执行。Hub 没有配置 `local_tun_ip`，所以它的网络规划只创建一个裸
TUN 设备——它是一个没有叠加网地址的纯中继。

## 5. 启动守护进程

```bash
# 在 Hub 与两个 Spoke 上（创建 TUN 需要 NET_ADMIN / root）：
sudo subnetrad --config config.json
```

正式部署时，请改用 systemd 或 launchd 托管——见
[生产部署](../operations/deployment.md)。

## 6. 验证连通性

在 **Spoke A** 上 ping **Spoke B**——报文走 `A → hub → B` 再返回，正好验证 Hub 的中继：

```bash
ping 10.0.0.3
```

然后在任一节点查看实时计数：

```bash
subnetra status
```

在 Spoke 上你应当看到 `udp_tx` / `udp_rx` 在增长，且对端被列为 `online`；在 Hub 上，
`relay_*` 计数会随着它在两个 Spoke 之间转发而增长。如果流量 **没有** 流动，drop 计数会
告诉你原因——阅读 [可观测性与排障](../operations/observability.md)。

> 这里的 Hub 是一个**纯中继**，没有叠加网地址，所以 `10.0.0.1` 上没有任何东西可 ping。
> 若要让 Hub 自身可达，见
> [角色 → 访问 Hub 自身](../configuration/roles.md#访问-hub-自身)。

## 7. 添加 Site-to-Site 路由（可选）

要访问 Spoke B *背后* 的局域网（例如 `192.168.3.0/24`），**Hub** 需要为该前缀添加一条
中继规则。在运行时注入它——通过控制套接字热更新，无需重启：

```bash
# 在 Hub 上：
subnetra policy add --src 0.0.0.0/0 --dst 192.168.3.0/24 --action forward --target 3
subnetra policy show
subnetra save              # 把生效策略持久化回 config.json
```

Spoke B 还必须在本地投递该前缀（加入 `local_routes`），并被允许以它为源（把 Hub 上
peer 3 的 `allowed_src` 放宽到覆盖该前缀）。完整的 Site-to-Site 演练见
[生产部署](../operations/deployment.md)。

## 接下来

- **[角色](../configuration/roles.md)**——从配置自动推导策略。
- **[架构](../concepts/architecture.md)**——数据通路如何工作。
- **[安全模型](../concepts/security-model.md)**——密钥、epoch、防重放。
- **[生产部署](../operations/deployment.md)**——服务、密钥、防火墙/NAT、升级。
