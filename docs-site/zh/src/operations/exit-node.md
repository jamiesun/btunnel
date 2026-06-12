# 出口节点与 outbound

Subnetra 是一条 **三层加密通道**，不是代理、也不是规则引擎。它不解析域名、不做
DNS、不匹配 GeoIP —— 按[设计](../concepts/design-principles.md)，这些都属于专门的
工具。它擅长的是：把流量全程加密、穿透 NAT 地送到一个拥有你想要的网络访问能力的
spoke。那个 spoke 就是**出口**，在它上面跑一个小代理，就把 mesh 变成了一个干净的
outbound。

做法刻意保持简单：在出口 spoke 上跑一个 SOCKS5 代理，绑定到它的 overlay IP，然后让一个
支持规则的客户端（Shadowrocket、mihomo、sing-box）指向它。Subnetra *只*充当抵达该代理
的安全通道；由客户端决定哪些目的地走出口。

> **为什么不把规则做进 Subnetra？** 内置 DNS、L7 路由、路径管理器都是明确的
> [非目标](../reference/roadmap.md#明确的非目标)。按域名选择目的地是 DNS + L7 的活儿；把
> 那一层交给成熟客户端，让 Subnetra 在底下专心当传输通道。

## 拓扑

```
规则引擎客户端 ─► spoke A ─► hub ─► 出口 spoke B ─► 互联网
 (如 Shadowrocket) (10.0.0.2) (中继)  (10.0.0.3)      (B 的上行)
```

hub 负责**中继** A ↔ B（spoke 之间从不直接互相中继）。只有 B 需要目标网络的访问能力；
客户端通过 B 访问。运行客户端的设备通过它本地的 spoke A 抵达 B 的 overlay IP
（`10.0.0.3`）—— A 本身，或者把 overlay 路由进来的、位于 A 局域网内的某台主机。

## 1. 在出口 spoke 上跑一个 SOCKS5 代理

在 B 上跑一个小型 SOCKS5 服务，**绑定到 B 的 overlay IP**，使其*仅*能通过 mesh 访问，
绝不暴露在 B 的公网网卡上。[zsocks](https://github.com/jamiesun/zsocks) 是一个微型、零依赖
的 SOCKS5 服务（同样用 Zig 写、与 Subnetra 同源同理念 —— 单静态二进制、内存有上界、
支持 TCP `CONNECT` 与 UDP `ASSOCIATE`、可选鉴权）：

```bash
# 仅绑定 overlay IP，并要求用户名/密码鉴权。
zsocks --listen 10.0.0.3 --port 1080 --user alice --pass <secret>
```

常用参数（详见 `zsocks --help`）：

| 参数 | 用途 |
|---|---|
| `-l, --listen <host>` | 绑定地址 —— 设为 B 的 overlay IP（`10.0.0.3`） |
| `-p, --port <port>` | 监听端口（默认 `1080`） |
| `-u/-P, --user/--pass` | 启用 RFC1929 鉴权（建议开启） |
| `--max-conns <n>` | 并发连接上限（默认 256） |
| `--no-udp` | 仅 TCP；不需要时关闭 UDP `ASSOCIATE` |
| `--udp-advertise <h>` | UDP 中继地址 —— 保持默认即可，overlay IP 本身可直达 |

支持 UDP `ASSOCIATE`，因此 QUIC / HTTP-3 应用也能正常工作；对客户端通告的 UDP 中继地址
默认就是 listen host（`10.0.0.3`），它在 overlay 上可直达，所以这里**不需要**设置
`--udp-advertise`。

由于代理绑定在 overlay 地址上，去往它的全部流量都留在加密 mesh 内部，且每个 overlay 报文
都带着正常的 overlay 源/目的 IP —— 因此 hub 的逐对端 `allowed_src` 反伪造保持收紧。这里
没有 `ip_forward`、没有 masquerade：代理在 B 上**重新发起**连接，回程路径就是它自己的
socket。

## 2. 让客户端的规则引擎指向它

在客户端上，只把你选定的目的地送出口。下面是 Shadowrocket / Surge 配置格式；mihomo 与
sing-box 等价。示例把一个国外知名音乐流媒体服务（Spotify）走出口，其余一律直连：

```
[Proxy]
via-exit = socks5, 10.0.0.3, 1080, alice, <secret>

[Rule]
DOMAIN-SUFFIX,spotify.com,via-exit
DOMAIN-SUFFIX,scdn.co,via-exit
FINAL,DIRECT
```

mihomo 等价：

```yaml
proxies:
  - name: via-exit
    type: socks5
    server: 10.0.0.3        # 出口 spoke B 的 overlay IP —— 只能经 Subnetra 抵达
    port: 1080
    username: alice
    password: <secret>
rules:
  - DOMAIN-SUFFIX,spotify.com,via-exit
  - DOMAIN-SUFFIX,scdn.co,via-exit
  - MATCH,DIRECT
```

未命中的一律直连（分流隧道），所以只有选定的目的地才走 `A → hub → B` 这条路径。

## DNS

域名规则仍然需要名字从正确的位置去解析：如果客户端在本地解析，可能拿到 A 所在地区的
端点。让客户端把 DNS 经出口解析（Shadowrocket 的代理 DNS，或 mihomo 的 `fake-ip` 配合
经代理可达的解析器），这样命中的域名就会从 B 的位置解析。

## 注意事项

- **B 是出口。** 它的 IP 承载客户端的流量 —— 对运行 B 的人是实打实的责任；B 能看到目的地
  元数据（SNI、DNS），尽管 TLS *载荷*仍是端到端加密的。务必开启代理鉴权，并只绑定
  overlay IP。
- **双跳。** 流量走 `客户端 → A → hub → B → 目标`再返回：增加延迟，且 hub 现在要承载这
  部分带宽 —— 给它做整形（见
  [生产部署 → 流量整形与调优](deployment.md#9-流量整形与调优)）。
- **MTU 叠加。** 你是在隧道里再套隧道；按[主机网络规划](../configuration/network-plan.md)
  的指引设置内层 MTU。

## 验证

```bash
# 经出口代理 —— 返回的公网 IP 应该是 B 的：
curl -s --socks5-hostname alice:<secret>@10.0.0.3:1080 https://api.ipify.org ; echo

# 在 hub 上 —— 流量流经时中继计数会增长：
subnetra status --json | grep relay_
```
