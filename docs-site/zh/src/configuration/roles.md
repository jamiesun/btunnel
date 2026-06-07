# 角色

与其手工注入 `subnetra policy add` 规则，不如设置一个 **`role`**，让守护进程在启动时推导
转发表。共有三种角色；`role` 默认为 `"manual"`。

| 角色 | 推导策略？ | 典型节点 |
|---|---|---|
| `manual` | 否（初始策略为空——自行注入规则） | 自定义场景、向后兼容 |
| `spoke` | 是——本地目标 + 其余一切经 Hub | 分支办公室、RouterOS 容器、Mac |
| `hub` | 是——为每个 Spoke 的 `allowed_src` 生成一条转发规则 | 中心中继 |

你随时可以在运行时把额外的 `subnetra policy` 规则叠加到推导出的表之上。

## `manual`（默认）

保持原有行为：初始策略为空，你通过控制套接字自行注入每条规则。早于角色特性的既有配置
不受影响。

## `spoke`

一个暴露自身叠加 IP、其余一切经中继的家庭/办公 Spoke，只需要：

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:51820", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

这会自动推导出：

- `10.0.0.2/32 → LOCAL`（投递到本节点自身的 TUN）
- `10.0.0.0/24 → hub(id 1)`（其余一切经中继）

要发布 Spoke 背后的局域网（Site-to-Site），把它加入 `local_routes`
（例如 `["10.0.0.2/32", "192.168.2.0/24"]`），使推导表把该前缀本地投递。

### 内置 NAT 保活

`spoke` 默认开启 **NAT 保活**（`keepalive_secs = 20`）。它每隔一段时间向其 Hub 发送一个
极小的已认证数据报，使空闲 Spoke 的 NAT 孔保持打开、Hub 保持新鲜回程路由——无需外部
pinger、无需 cron。显式设置 `keepalive_secs` 调节，或设为 `0` 关闭。

### `spoke` 的校验规则

`subnetrad --check` 强制：

- 恰好 **一个** Hub 对端，
- 至少一个本地目标（`local_routes` **或** `local_tun_ip`），
- 没有 `0.0.0.0/0` 本地路由（那会把主机默认路由绑到隧道并将其黑洞）。

## `hub`

对应的 Hub 只需列出它的 Spoke；每个对端的 `allowed_src` 成为指向该对端的一条转发规则：

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:51820", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:51820", "allowed_src": "10.0.0.3/32", "psk": "…64 hex…" }
  ]
}
```

这会推导出 `10.0.0.2/32 → peer 2` 与 `10.0.0.3/32 → peer 3`。Hub 按最长前缀匹配在 Spoke
之间中继，且绝不把包反射回源端。

### `hub` 的校验规则

`subnetrad --check` 拒绝：

- `allowed_src` **缺失**（或宽松的 `0.0.0.0/0`）的对端，因为 Hub 无法判断一个包属于哪个
  Spoke；
- 两个 `allowed_src` 前缀 **重叠** 的对端，那会使转发产生歧义。

Hub 的保活默认为 `0`（它不向 Spoke 发起保活）。

## 可直接编辑的示例

仓库的 [`deploy/`](https://github.com/jamiesun/subnetra/tree/main/deploy) 目录提供可编辑的
`hub.json`、`spoke-a.json`、`spoke-b.json` 以及服务单元。完整的 Hub + 双 Spoke 演练在
[生产部署](../operations/deployment.md)。
