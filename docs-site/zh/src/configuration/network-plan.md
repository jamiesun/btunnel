# 主机网络规划

`subnetrad` 会创建 TUN 网卡，但刻意 **不** 配置主机地址、路由或 MTU。自动配置主机网络意味
着要 shell 外调或链接额外库，那会破坏零依赖单二进制保证。取而代之，守护进程为加载的配置
**打印出确切的命令**，供你审阅并执行。

## 打印规划

```bash
# 打印本节点的主机网络规划（默认按 1500 字节承载）。
subnetrad --print-network-plan --config config.json

# 覆盖承载路径 MTU（例如位于 PPPoE / VPN 承载之后）：
subnetrad --print-network-plan --path-mtu 1420 --config config.json
```

输出是 **确定的、仅打印** 的——主机上不会有任何改动。后端在 comptime 选择，因此规划与你的
平台匹配：

- **Linux** 输出 `ip link` / `ip addr` / `ip route` 命令。
- **macOS** 输出 `ifconfig` / `route` 命令。

## 它输出什么

对于加载的配置，Linux 规划输出：

- `ip link set <tun> mtu <local_tun_mtu> up`
- `ip addr add <local_tun_ip> dev <tun>`——设置可选的 `local_tun_ip` 配置字段
  （例如 `"local_tun_ip": "10.0.0.2/24"`）；否则显示一个占位符。
- 为每个对端的 `allowed_src` 输出 `ip route add <subnet> dev <tun>`——宽松的 `0.0.0.0/0`
  会被 **跳过**，以免黑洞默认路由。
- 一条可选的 TCP **MSS clamp** 提示（nftables / iptables），以避免 PMTU 黑洞。

## MTU 计算

规划从真实线开销计算安全隧道 MTU：

```text
报头 20  +  AEAD tag 16  +  外层 IPv4/UDP 28  =  64 字节
最大隧道 MTU = path_mtu − 64
```

如果配置的 `local_tun_mtu` 超过该值，规划会打印一条 **告警**——这正是「小包能通、大传输
卡死」（PMTU 黑洞）的经典原因。在标准 1500 字节路径上，`1452` 是安全默认值；在 1420 字节
承载上，你应把 `local_tun_mtu` 调低到 `1356`。

## 应用它

审阅输出的命令，然后执行（多数需要 root）：

```bash
subnetrad --print-network-plan --config config.json | sudo sh   # 审阅之后再执行！
```

> 请先检查输出、再有意识地粘贴命令，而不是直接管道进 shell——规划本就是为了可审计。

## 为什么这样设计

把主机网络配置排除在守护进程之外意味着：

- 二进制保持零依赖且极小，
- 同一个守护进程在 Linux、容器与 macOS 上行为完全一致，
- 运维者保有对主机地址与路由每一次改动的完全控制权与可审计记录。

为规划提供输入的字段（`local_tun_ip`、`local_tun_mtu`、每个对端的 `allowed_src`）见
[配置参考](reference.md)，将其接入服务见 [生产部署](../operations/deployment.md)。
