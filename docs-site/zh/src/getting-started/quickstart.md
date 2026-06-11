# 快速上手

本指南拉起最小可用的网格：**一个 Hub** 与 **一个 Spoke**，构建一个虚拟的
`10.0.0.0/24` 叠加网。假设你已安装 `subnetrad` 守护进程与 `subnetra` 控制工具
（见 [安装](installation.md)）。

全文中，Hub 的公网地址为 `203.0.113.1:18020`，Spoke 为 `203.0.113.2`。

## 1. 生成每链路密钥

每条链路都需要 **自己的** 32 字节预共享密钥（64 个十六进制字符）。绝不要在多个对端
之间复用同一把密钥。

```bash
openssl rand -hex 32
# 例如 9f2c…（64 个十六进制字符）…  — 在两端配置里填入相同的值
```

## 2. 编写配置

最简单的方式是设置一个 [`role`](../configuration/roles.md)，让守护进程在启动时自动
推导转发策略。

**Hub**（`203.0.113.1` 上的 `config.json`）：

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "listen_ports": [18020, 18023, 18026],
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:18020", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" }
  ]
}
```

**Spoke**（`203.0.113.2` 上的 `config.json`）：

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

链路 1↔2 上的 PSK 在两份文件中必须 **完全一致**。每个字段详见
[配置参考](../configuration/reference.md)。

## 3. 运行前校验

`--check` 解析配置、运行全部防呆规则，并在不触碰网络的情况下退出：

```bash
subnetrad --check --config config.json
# subnetra v… (mtu=1452, udp_ports={ 18020, 18023, 18026 }, mode=raw_direct, local_id=2, peers=1) [config ok]
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

## 5. 启动守护进程

```bash
# 在 Hub 与 Spoke 上（创建 TUN 需要 NET_ADMIN / root）：
sudo subnetrad --config config.json
```

正式部署时，请改用 systemd 或 launchd 托管——见
[生产部署](../operations/deployment.md)。

## 6. 验证连通性

在 Spoke 上 ping Hub 的叠加网地址：

```bash
ping 10.0.0.1
```

然后在任一节点查看实时计数：

```bash
subnetra status
```

你应当看到 `udp_tx` / `udp_rx` 在增长，且对端被列为 `online`。如果流量 **没有**
流动，drop 计数会告诉你原因——阅读
[可观测性与排障](../operations/observability.md)。

## 7. 添加 Site-to-Site 路由（可选）

要访问某个 Spoke *背后* 的局域网（例如 id 为 3 的 Spoke 背后的 `192.168.2.0/24`），
在运行时注入一条策略——它通过控制套接字热更新，无需重启：

```bash
subnetra policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
subnetra policy show
subnetra save              # 把生效策略持久化回 config.json
```

## 接下来

- **[角色](../configuration/roles.md)**——从配置自动推导策略。
- **[架构](../concepts/architecture.md)**——数据通路如何工作。
- **[安全模型](../concepts/security-model.md)**——密钥、epoch、防重放。
- **[生产部署](../operations/deployment.md)**——服务、密钥、防火墙/NAT、升级。
