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

`manual` 是原始的显式模式，也是默认值。守护进程在启动时**不推导任何**策略——转发表从
**空**开始，你通过控制套接字自行安装每一条规则。早于角色特性的既有配置照常工作、不受影响。

**`manual` 相对推导角色改变了什么：**

- **不推导策略。** 你用 `subnetra policy add` 自行构建转发表。
- **没有角色专属的 `--check`。** `subnetrad --check` 仍会跑通用合理性检查（MTU 范围、
  16 位 id、与主机子网重叠），但**不会**施加 `hub`/`spoke` 的结构性规则（每对端的
  `allowed_src`、恰好一个 Hub、一个本地目标、无 `0.0.0.0/0` 本地路由）。配错的转发意图
  要你自己发现。
- **保活默认为 `0`。** 若一个 `manual` 节点位于 NAT 之后，请自行设置 `keepalive_secs`
  （`spoke` 会替你处理）。

**`manual` _没有_ 改变什么——安全性完全一致。** 角色只选择**启动期**策略，绝不触及数据面。
每链路加密、会话 epoch 排序、抗重放，以及——关键的——**每对端 `allowed_src` 内层源校验**
全都照旧运行。策略仅按目的地匹配（最长前缀）；每个对端的 `allowed_src` 独立地约束该对端
可声称的内层源地址。因此手工构建的 `manual` 表**无法**被诱骗去接受伪造的内层源——你放弃的
是*推导出来的便捷表*与*角色专属护栏*，**而非**密码学保证。

### 何时使用 `manual`

- `hub`/`spoke` 形态在单个节点上无法表达的拓扑——例如一个节点同时是**对上的 Spoke、对下的
  中继**（`hub`/`spoke` 各自只校验一种姿态；`manual` 让一个节点兼具两者）。这超出了推导
  角色所验证的单层模型，因此转发表——以及上游 Hub 的 `allowed_src` 聚合——由你负责。
- 逐字复现一张手调的策略表，或与早于角色的配置向后兼容。

### 手工构建转发表

规则按目的地最长前缀匹配；`src` 取宽松值（`0.0.0.0/0`）。`--target 0` 投递到本地 TUN，
其它任何 target 则中继给该对端 id：

```bash
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
# 把本节点自身的叠加地址本地投递。
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.9/32  --action forward --target 0
# 把一个下游前缀中继给 peer 5；其余一切上送 Hub（peer 1）。
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.32/27 --action forward --target 5
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.0/24  --action forward --target 1
sudo -E subnetra policy show      # 核对顺序
sudo -E subnetra save             # 跨重启持久化
```

每个对端仍必须带上正确的 `allowed_src`，以匹配它被允许声称的内层源——该绑定无论这些规则
如何都会被强制执行。

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
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
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
    { "id": 2, "endpoint": "203.0.113.2:18020", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:18020", "allowed_src": "10.0.0.3/32", "psk": "…64 hex…" }
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
