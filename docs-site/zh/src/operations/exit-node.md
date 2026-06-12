# 出口节点与 outbound

Subnetra 是一条 **三层加密通道**，不是代理、也不是规则引擎。它不解析域名、不做
DNS、不匹配 GeoIP —— 按[设计](../concepts/design-principles.md)，这些都属于专门的
工具。Subnetra 擅长的是：把流量全程加密、穿透 NAT 地送到一个拥有你想要的互联网出口
的 spoke。那个 spoke 就是**出口（exit）**。

本页介绍两种把某节点的互联网流量从另一个 spoke 送出去的方法，以及「路由大脑」（域名/
GeoIP 规则、DNS）应该放在哪一层。

> **为什么不把规则做进 Subnetra？** 内置 DNS、L7 路由、路径管理器都是明确的
> [非目标](../reference/roadmap.md#明确的非目标)。按域名分流本质是 DNS + L7 问题；把
> 那一层交给成熟工具，让 Subnetra 在底下专心当传输通道。

## 拓扑

```
客户端 spoke A ──► hub ──► 出口 spoke B ──► 互联网
  (10.0.0.2)      (中继)    (10.0.0.3，         (B 的干净
  想访问 x.com               干净上行)           公网 IP)
```

hub 负责**中继** A ↔ B（spoke 之间从不直接互相中继）。只有 B 需要不受限的互联网；A 通过
B 访问互联网。

## 选哪种方案？

| | 方案 B —— 代理 outbound *(推荐)* | 方案 A —— L3 出口（masquerade） |
|---|---|---|
| 按**域名/GeoIP**分流 | ✅ 可以（规则引擎） | ❌ 仅 IP/CIDR |
| 应对 DNS 污染 | ✅ 可以（fake-ip / DoH） | ❌ 需另行治理 DNS |
| B 上的额外软件 | 一个小型 SOCKS/HTTP 代理 | 无（纯内核） |
| hub 上的反伪造 | ✅ 保持不变 | ⚠️ 须把 B 的 `allowed_src` 放宽到 `0.0.0.0/0` |
| 回程路径 | 简单（代理重新发起连接） | 需源地址为 overlay IP |
| 适用 | 真正的「按站点」分流 | 全量隧道 / 粗粒度 CIDR 出口 |

## 方案 B —— 按规则分流的 outbound（推荐）

在出口 spoke 上跑一个代理，**绑定到它的 overlay IP**，然后让客户端上的规则引擎
（mihomo / sing-box / Clash）指向它。Subnetra *只*充当抵达该代理的安全通道；域名与 DNS
由规则引擎负责。

**在出口 spoke B 上** —— 跑任意小型 SOCKS5/HTTP 代理（如 `microsocks`、`gost`、
`3proxy`，或把 sing-box/mihomo 作为 `socks` inbound），监听在 **B 的 overlay 地址**上，
使其*仅*能通过 mesh 访问，绝不暴露在 B 的公网网卡上：

```bash
# 示例：microsocks 仅绑定到 overlay IP
microsocks -i 10.0.0.3 -p 1080
# 防火墙：确保 1080 端口没有暴露在公网上行（eth0）上。
```

**在客户端 A 上** —— mihomo（`config.yaml`），用 overlay 地址作为代理：

```yaml
proxies:
  - name: via-exit
    type: socks5
    server: 10.0.0.3        # 出口 spoke B 的 overlay IP —— 只能经 Subnetra 抵达
    port: 1080

rules:
  - DOMAIN-SUFFIX,x.com,via-exit
  - GEOIP,CN,DIRECT
  - MATCH,DIRECT            # 其余一律直连（分流隧道）

dns:
  enable: true
  enhanced-mode: fake-ip    # 命中的域名解析为 fake IP，按规则路由
  nameserver:
    - https://1.1.1.1/dns-query   # 干净的解析器，本身也经代理抵达
```

sing-box 等价：一个指向 `10.0.0.3:1080` 的 `socks` outbound、按域名/GeoIP 的 `route`
规则，以及一个 `fake-ip` DNS server。

**为什么这是干净的组合**

- 所有 overlay 报文都带着正常的 **overlay** 源/目的 IP，因此 hub 的逐对端
  `allowed_src` 反伪造保持收紧 —— 无需放宽任何东西。
- B 上的代理向互联网**重新发起**连接，所以不需要 `ip_forward`、不需要 masquerade，
  回程路径就是代理自己的 socket。
- 规则引擎负责最难的部分 —— 域名、**DNS 污染**（fake-ip / DoH）、规则集刷新 ——
  而这正是 Subnetra 不该去重新实现的那一层。

## 方案 A —— L3 出口节点（内核 masquerade）

零依赖：把某个 CIDR（或全部）路由进 overlay，让 B 的内核把它 masquerade 到互联网。
适合全量隧道或粗粒度 IP/CIDR 出口。**不感知域名**，且需要放松一项安全控制（见下）。

**在出口 spoke B 上** —— 开启转发并把 overlay masquerade 到上行：

```bash
sudo sysctl -w net.ipv4.ip_forward=1          # 持久化到 /etc/sysctl.d/
UPLINK=eth0; OVERLAY=10.0.0.0/24; TUN=snr0     # TUN = [ready] 横幅里的 tun=…
sudo iptables -t nat -A POSTROUTING -s "$OVERLAY" -o "$UPLINK" -j MASQUERADE
sudo iptables -A FORWARD -i "$TUN"  -s "$OVERLAY" -j ACCEPT
sudo iptables -A FORWARD -o "$TUN"  -d "$OVERLAY" -j ACCEPT
```

B 的回程报文带着**互联网**源 IP（如 `1.2.3.4`），因此 hub 的内层源检查会丢弃它们，除非
允许 B 使用任意源地址。在 **hub** 的配置里，把对应 B 的 peer 条目设为：

```json
{ "id": 3, "allowed_src": "0.0.0.0/0", "...": "..." }
```

> ⚠️ 这会**关闭对 B 的内层源反伪造**。只对你完全信任、作为出口的节点这样做；此后 B 可以
> 注入声称任意源地址的报文。

**在 hub 上** —— 把所有非 overlay 流量送往 B。最长前缀匹配意味着已有的 overlay `/32`
投递规则仍然优先，所以只有去往互联网的流量才会命中这条兜底规则：

```bash
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 0.0.0.0/0 --action forward --target 3
sudo -E subnetra save        # 持久化可重放的快照
```

**在客户端 A 上** —— 把你想出口的流量路由进 TUN。对于特定目的集合：

```bash
sudo ip route add 198.51.100.0/24 dev snr0     # 该 CIDR 经 B 出口
```

要做**全量隧道**，用两条 `/1` 路由覆盖默认路由，并把 hub 的公网 IP 钉到物理网关上，
让隧道本身保持可达：

```bash
sudo ip route add 0.0.0.0/1   dev snr0
sudo ip route add 128.0.0.0/1 dev snr0
sudo ip route add <HUB_PUBLIC_IP>/32 via <PHYSICAL_GATEWAY>
```

如果 A 是为其他主机转发的 **LAN 网关**，要把 LAN → overlay 做 masquerade，使源地址变成
A 的 overlay IP（否则 B 回给某个私网 LAN 地址的报文无法经 mesh 路由回来）：

```bash
sudo iptables -t nat -A POSTROUTING -o snr0 -j MASQUERADE
```

**回程路径：** `A(10.0.0.2)→hub→B`；B masquerade 成自己的公网 IP 发往互联网；回包到达
B，conntrack 反 NAT 回 `10.0.0.2`，B 把它送进 overlay，hub 按 `dst 10.0.0.2/32 → A`
中继。之所以成立，是因为流量进入 mesh 时的源地址就是 A 的 overlay IP。

## DNS —— 三层解决不了的那部分

按 IP 路由对被污染的解析器视而不见：如果 A 把 `x.com` 解析成被审查 DNS 返回的假 IP，
再怎么按 IP 路由都没用。

- **方案 B** 替你解决了 —— 规则引擎做 `fake-ip`，并把 DNS *经代理*发往干净解析器。
- **方案 A** 不行。你必须额外把 DNS 发往一个经 B 可达的干净解析器（把客户端解析器指向
  一个经隧道路由的解析器，或用 DoH），否则你仍会解析到被污染的地址。

## 注意事项（两种方案通用）

- **B 是你的出口。** 它的公网 IP 承载 A 的流量 —— 对运行 B 的人是实打实的滥用/法律风险。
  B 还能看到 A 的目的元数据（SNI、DNS）；TLS *载荷*仍是端到端加密的，但*访问了谁*在 B
  处可见。
- **双跳。** 流量走 `A → hub → B → 互联网`再返回。会增加延迟，且 hub 现在要承载这部分
  带宽 —— 给它做整形（见
  [生产部署 → 流量整形与调优](deployment.md#9-流量整形与调优)）。
- **MTU 叠加。** 你是在隧道里再套隧道；按[主机网络规划](../configuration/network-plan.md)
  的指引设置内层 MTU。
- **保持小规模。** 一种翻墙模式只在用的人少时才一直有效；一个流行、统一的配置正是会被
  指纹识别和封锁的东西。保持部署小而多样。

## 验证

```bash
# 在客户端 A 上 —— 你对外呈现的公网 IP 应该是 B 的：
curl -s https://api.ipify.org ; echo

# 在 hub 上 —— A 的流量流经时，中继计数会增长：
subnetra status --json | grep relay_
```
