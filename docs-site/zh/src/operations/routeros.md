# RouterOS Spoke

本指南讲解在 MikroTik 设备上的 **RouterOS Container** 内，把 Subnetra 作为 **Spoke** 运行，
拨向一个公网 Linux **Hub**。完整参考（含脚本化 `.rsc` 的拉起/拆除）见
[`docs/routeros-container.md`](https://github.com/jamiesun/subnetra/blob/main/docs/routeros-container.md)；
脚本位于
[`deploy/routeros/`](https://github.com/jamiesun/subnetra/tree/main/deploy/routeros)。

## RouterOS 为何不同

RouterOS Container 不是普通的 Linux 主机：

- RouterOS 通过 **`veth`** 管理容器的以太网侧。
- Subnetra 在容器 *内部* 创建自己的 Linux **`snr0` TUN** 设备。
- RouterOS 无法直接管理那个 `snr0`——它通过 `veth` 网关把流量路由 **到** 容器。
- RouterOS 镜像导入可能需要 legacy Docker 归档布局。

## 推荐拓扑

把 Hub 放在有稳定 UDP 端点的公网 Linux 服务器上；把 NAT 后的 RouterOS 设备作为 Spoke 置于
其后。

```text
公网 Linux Hub
  承载: 203.0.113.10:51820
  叠加: 10.66.0.1/24

RouterOS 办公 Spoke
  容器 veth:               172.30.66.2/30
  RouterOS veth 侧:        172.30.66.1/30
  容器内 subnetra TUN:      10.66.0.3/24
  发布的 LAN:              192.168.88.0/24
```

> **不要** 把 NAT 后的 RouterOS 设备当作公网 Hub，除非它的 UDP 端点稳定且对每个 Spoke 可达。
> 此处 LAN 地址为示例——把 `192.168.88.0/24` 换成你真实的 LAN。

## 前置条件

- 装有 **`container`** 包的 RouterOS v7。
- 设备模式允许容器（`/system/device-mode/print`）。
- 容器根目录与镜像归档可写的存储路径。
- RouterOS 容器内可见 **`/dev/net/tun`**。
- RouterOS 设备到公网 Hub 的出站 UDP。

```routeros
/system/package/print
/system/device-mode/print
/container/print
```

## 拉起步骤概览

1. **配置 veth** 对与地址（容器侧 `172.30.66.2/30`，RouterOS 侧 `172.30.66.1/30`）。
2. **导入镜像**（来自发布的可 `docker load` tar 包，或在设备可达时从 GHCR 拉取），并创建挂载
   了 `config.json`、`NET_ADMIN` 与 `/dev/net/tun` 的容器。
3. **设置 Spoke 配置**（`role: spoke`，Hub 作为唯一对端，发布的 LAN 放进 `local_routes`）——
   见 [角色](../configuration/roles.md)。
4. **在 RouterOS 上应用路由**，使发往叠加/远端前缀的 LAN 流量路由到容器的 `veth` 网关，且发布
   的 LAN 在隧道对端可达。
5. **验证**：在容器内 `subnetra status`，并跨叠加网 ping。

`deploy/routeros/` 中脚本化的 `.rsc` 文件自动化第 1–4 步（以及配套的拆除）。精确命令（含 LAN
发布与 NAT 后 Spoke 的 NAT/endpoint 注意事项）请遵循完整指南。

## Endpoint 漫游说明

协议级的端点学习意味着 Hub 会从 NAT 后 Spoke 的下一个已认证数据报重新学习其 endpoint，且
内置 NAT 保活（`role=spoke` 默认）保持 NAT 孔打开——因此处于变化 NAT 映射之后的 RouterOS
Spoke，无需手工修正 endpoint 即可保持可达。
