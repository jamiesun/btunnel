# 生产部署

本页浓缩了完整的 Hub + 双 Spoke 生产演练。详尽版本——含流量整形、网卡调优与基准测试——
见仓库中的
[`docs/deployment.md`](https://github.com/jamiesun/subnetra/blob/main/docs/deployment.md)。
可直接编辑的产物位于
[`deploy/`](https://github.com/jamiesun/subnetra/tree/main/deploy)
（`subnetrad.service`、`net.subnetra.subnetrad.plist`、`hub.json`、`spoke-a.json`、
`spoke-b.json`）。

## 0. 组件

一次部署有一个 **Hub**（稳定的公网 UDP 端点）和一个或多个 **Spoke**（仅出站，常位于 NAT
之后）。它们运行相同的 `subnetrad` 守护进程与 `subnetra` 控制工具；区别在配置
（[角色](../configuration/roles.md)）。

## 1. 安装二进制

使用[发布 tar 包或容器镜像](../getting-started/installation.md)。在裸主机上：

```bash
sudo install -m 0755 subnetrad subnetra /usr/local/bin/
```

## 2. 准备配置与密钥

把 `config.json` 放到服务期望的位置（单元使用 `/etc/subnetra/config.json`），属主 root、
权限 `0600`，因为它含有 PSK：

```bash
sudo install -d -m 0750 /etc/subnetra
sudo install -m 0600 hub.json /etc/subnetra/config.json
subnetrad --check --config /etc/subnetra/config.json
# subnetra v… (mtu=…, mode=raw_direct, local_id=…, peers=…) [config ok]
```

用 `openssl rand -hex 32` 为每条链路生成 PSK，并 **每链路使用唯一** 值。见
[安全模型](../concepts/security-model.md)。

## 3. 主机网络

守护进程打印——但绝不应用——主机规划。审阅并执行它（见
[主机网络规划](../configuration/network-plan.md)）：

```bash
subnetrad --print-network-plan --config /etc/subnetra/config.json
```

## 4. 作为服务运行

### Linux —— systemd

```bash
sudo install -m 0644 deploy/subnetrad.service /etc/systemd/system/subnetrad.service
sudo systemctl daemon-reload
sudo systemctl enable --now subnetrad
journalctl -u subnetrad -f
```

该单元只请求 `CAP_NET_ADMIN`，授予 `/dev/net/tun`，以 `ExecStartPre` 运行
`subnetrad --check`，失败时重启，其余均沙箱化（`ProtectSystem=strict`、
`NoNewPrivileges`、受限地址族）。编辑注释掉的 `ExecStartPost` 行以匹配你的
`--print-network-plan` 输出。

### macOS —— launchd

macOS **Spoke** 作为系统守护进程运行（创建 `utun` 需要 root）：

```bash
sudo install -m 0644 deploy/net.subnetra.subnetrad.plist \
    /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl enable system/net.subnetra.subnetrad
sudo tail -f /var/log/subnetrad.log
# subnetra v… (… mode=raw_direct …) tun=utun4 sock=/var/run/subnetra.sock [ready]
```

`utunN` 名字由内核分配——从 `[ready]` 横幅读取它，并在守护进程起来 **之后** 应用规划。见
[macOS Spoke](macos-spoke.md) 指南。

## 5. 安装中继策略（Hub）

> **捷径：** 如果你的配置设置了 `"role": "hub"` / `"spoke"`，守护进程会 **在启动时推导出
> 整套策略**，本节可跳过。见 [角色](../configuration/roles.md)。

对于 `role=manual`，在运行时通过控制套接字安装中继/投递规则（热更新、无需重启）。让
`SUBNETRA_SOCK` 与单元一致：

```bash
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
# Hub：把叠加网流量中继给正确的 Spoke
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.3/32 --action forward --target 3
sudo -E subnetra policy show
sudo -E subnetra save        # 持久化一份可重放的快照

# Spoke：把发往本地叠加地址的隧道流量投递到本地 TUN（target 0）
sudo -E subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0
```

## 6. 运维

`subnetra status` 显示对端、流量与按原因分类的 drop；`--json` 是供监控使用的稳定 schema。
见 [可观测性与排障](observability.md)。

## 7. 防火墙 / NAT

- **Hub** 必须接受来自互联网、发往其 `listen_port`（默认 `51820`）的入站 UDP。
- 每个 **Spoke** 只需要对 Hub 的 **出站** UDP 可达性——无需入站端口转发（由 Spoke 发起）。
- 若某 Spoke 的 NAT 映射变化，Hub 会从下一个已认证数据报重新学习它的新 endpoint。保持
  **Hub** 端点稳定；Spoke 始终发起。

### NAT 保活（内置）

空闲 Spoke 的 NAT 映射会超时（UDP 常约 ~30 秒），之后入站中继会被黑洞。`role=spoke` 默认
运行 **内置保活**（`keepalive_secs = 20`）：每隔一段时间一个极小的已认证数据报保持 NAT 孔
打开，并保持 Hub 学到的 endpoint 新鲜。它零分配，不增加线程或外部进程。用 `keepalive tx` /
`keepalive rx` 计数确认。设 `keepalive_secs = 0` 关闭（例如不在 NAT 后的 Spoke）。

### Hub 使用动态 IP（DDNS）

endpoint 是数字 `IP:port`，且端点学习是单向的——Spoke 无法发现搬了家的 Hub。请优先为 Hub
使用 **稳定公网 IP**。若必须让它位于动态地址之后，在每个 Spoke 上用一个小型 DDNS 监视器解决
：重写 endpoint 并重启（无状态的）守护进程——无需改动守护进程。

## 8. 高可用

v1 按设计 **单 Hub**；故障切换在守护进程 **之外** 完成（数据面保持单路径、无状态、无握手）：

- **方案 A —— 共享 Hub VIP。** 两个 Hub 实例置于一个 VRRP/`keepalived` VIP 或 anycast 前缀
  之后，对 Spoke 不可区分（相同 `local_id`、相同的每 Spoke PSK、相同策略）。注意
  **epoch 警告**：接管的 Hub 不得呈现比 Spoke 上次接受的 *更低* 的 boot epoch——让两者都用
  NTP，并优先 active/standby，其中 standby 在接管时（重新）启动。
- **方案 B —— 静态多 Hub。** 两个完全独立的 Hub，`local_id` 不同、PSK 不同；每个 Spoke 把
  两者都列为对端，由一个 **外部** 机制（路由 metric、拆分前缀、运维脚本）选择路径。

任何切换都由 `subnetra status --json` 中的 **仅观测** 健康信号驱动（`online`、
`last_seen_age_seconds`、一个平直的 `auth_or_invalid`）。守护进程自身不做任何切换决策。

## 9. 流量整形与调优

在跨 ISP 的长链路上，抖动/丢包的主因是 **承载**，而非检测。所有整形都在 OS 层用 `tc` 完成
——不改守护进程或协议。把出站限到链路 *稳定* 吞吐的约 60–80%，平滑突发，并（可选）调优
套接字缓冲与 IRQ/CPU 亲和。内核在明文 `snr0` 设备上看到真实的内层五元组。完整配方与活叠加
基准见
[`docs/deployment.md` §9–§10](https://github.com/jamiesun/subnetra/blob/main/docs/deployment.md)。
