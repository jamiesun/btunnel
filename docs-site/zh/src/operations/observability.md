# 可观测性与排障

数据面会 **按设计静默丢弃**（隐蔽性）格式错误、未认证、被重放、伪造、无路由或超长的包。
`subnetra status` 让这些静默丢弃 **可计数**，于是你能在不削弱隐蔽性的前提下判断流量 *为何*
不通。

## `subnetra status`

```text
subnetrad v0.6.0 [running]
mode=raw_direct local_id=1 udp_port=51820 tun=snr0 peers=2
peers:
  id=2 endpoint=203.0.113.2:51820 allowed_src=10.0.0.2/32
  id=3 endpoint=203.0.113.3:51820 allowed_src=10.0.0.3/32
traffic:
  tun_rx packets=... bytes=...
  udp_tx packets=... bytes=...
  udp_rx packets=... bytes=...
  tun_tx packets=... bytes=...
  relay  packets=... bytes=...
  endpoint_learned=..
  keepalive rx=.. tx=..
drops:
  tun: not_ipv4=.. no_route=.. drop_rule=.. local_loop=.. unknown_target=.. oversized=.. egress_err=.. send_err=..
  udp: unknown_peer=.. auth_or_invalid=.. not_ipv4=.. spoof=.. no_route=.. drop_rule=.. unknown_target=.. no_reflect=.. oversized=.. send_err=..
```

守护进程未运行时，`subnetra status` **以非零退出**，便于脚本检测。PSK 与派生密钥
**绝不** 打印。

## 解读 drop 分类

| 计数器 | 含义 | 可能原因 |
|---|---|---|
| `udp: unknown_peer` | 数据报报头的 `key_id` 匹配不到任何已配置对端 | 发送方网格 id 错误，或非请求流量 |
| `udp: auth_or_invalid` | PSK/epoch 或线格式不匹配 | PSK 不一致、密钥轮换时间偏差、时钟/epoch 问题，或破坏线格式的版本差 |
| `udp: spoof` | 对端发送的内层源 **超出** 其 `allowed_src` | `allowed_src` 配错，或确有伪造 |
| `udp: no_route` / `tun: no_route` | 没有策略规则匹配目的地 | 缺少转发规则 / 角色推导 |
| `udp: no_reflect` | Hub 避免把包回送源端 | 正常保护；非错误 |
| `tun: not_ipv4` | TUN 上出现非 IPv4 帧 | IPv6 或其他流量打到三层设备 |
| `*: oversized` | 包超过安全 MTU | 调低 `local_tun_mtu` / 增加 MSS clamp |

良性信号：上升的 `endpoint_learned` 只是统计在新 UDP endpoint 上见到的已认证对端（漫游 /
NAT 重映射）。`keepalive rx` / `tx` 行统计内置 spoke→hub NAT 保活：发出端 Spoke 计 `tx`，
接收端 Hub 计 `rx`。

## 机器可读状态（`--json`）

为监控与自动化，`subnetra status --json` 以稳定的、**带版本** 的 JSON 对象输出相同数据——
于是健康状态可被抓取而无需解析自由文本（且仍绝不序列化秘密）：

```bash
subnetra status --json | jq .
```

```jsonc
{
  "schema_version": 1,                 // 仅在 schema 破坏性变更时递增
  "version": "0.5.1",
  "mode": "raw_direct",
  "local_id": 1,
  "listen_port": 51820,
  "tun": "snr0",
  "peers": [
    {
      "id": 2,
      "endpoint": "203.0.113.7:51822",
      "name": "bj-office-gw",            // 可选运维标签（未设时为 ""）
      "allowed_src": "10.66.0.2/32",
      "last_seen_age_seconds": 5,        // 对端从未认证过则为 null
      "online": true                     // last_seen 在新鲜窗口（~90s）内
    }
  ],
  "counters": { "tun_rx_packets": 3, "udp_tx_packets": 0 /* …每个数据面计数器… */ }
}
```

- `online` / `last_seen_age_seconds` 给出每对端心跳（新鲜窗口约 ~90 秒——长到能容忍偶尔丢失
  几个保活而不抖动）。
- `counters` 携带人类视图中的 **每个** 计数器，抓取绝不漏字段。
- 在你的监控里钉住 `schema_version`；它仅在破坏性变更时递增。

## Prometheus textfile 导出器

守护进程里刻意 **没有 HTTP 服务器**（多余的攻击面，违背单二进制理念）。取而代之，
[`deploy/subnetra-textfile-exporter.sh`](https://github.com/jamiesun/subnetra/blob/main/deploy/subnetra-textfile-exporter.sh)
把 `subnetra status --json` 转成 node_exporter 的 **textfile collector** 指标（唯一前置依赖
是 `jq`）：

```bash
sudo install -m 0755 deploy/subnetra-textfile-exporter.sh /usr/local/bin/
sudo install -m 0644 deploy/subnetra-textfile-exporter.service /etc/systemd/system/
sudo install -m 0644 deploy/subnetra-textfile-exporter.timer   /etc/systemd/system/
sudo systemctl enable --now subnetra-textfile-exporter.timer
```

它（原子地）输出：

| 指标 | 类型 | 备注 |
|---|---|---|
| `subnetra_up` | gauge | 读到状态为 `1`，宕机/未绑定为 `0` |
| `subnetra_build_info{version,mode,tun,local_id,listen_port}` | gauge | 常量 `1`；身份在标签里 |
| `subnetra_peer_online{id,allowed_src}` | gauge | 在新鲜窗口内为 `1` |
| `subnetra_peer_last_seen_age_seconds{id,allowed_src}` | gauge | 从未认证则省略 |
| `subnetra_<counter>_total` | counter | **每个** `counters` 字段，防漂移 |

有用的告警表达式：`subnetra_up == 0`、`subnetra_peer_online == 0`、
`subnetra_peer_last_seen_age_seconds > 120`，以及上升的
`rate(subnetra_drop_udp_auth_or_invalid_total[5m]) > 0`（PSK/epoch/线偏差）或
`rate(subnetra_drop_udp_spoof_total[5m]) > 0`。

## 排障清单

1. **守护进程在跑？** `subnetra status`（非零退出 ⇒ 宕机）。检查
   `journalctl -u subnetrad`。
2. **配置有效？** `subnetrad --check`。
3. **对端在线？** 看 `online` / `last_seen_age_seconds`。
4. **大传输卡死但 ping 正常？** MTU/PMTU——重查
   [主机网络规划](../configuration/network-plan.md) 并增加 MSS clamp。
5. **`auth_or_invalid` 在涨？** PSK 不一致、密钥轮换偏差、时钟/epoch 倒退，或部分升级期间
   破坏线格式的版本差（见 [升级与发布](upgrade.md)）。
6. **`spoof` 在涨？** 某对端的内层源超出其 `allowed_src`。
7. **`no_route`？** 缺少策略规则——检查 [角色](../configuration/roles.md) 或用
   `subnetra policy add` 注入一条。
