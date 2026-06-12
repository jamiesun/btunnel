# 命令行参考

Subnetra 提供两个二进制：

- **`subnetrad`**——守护进程（数据面 + 控制套接字）。
- **`subnetra`**——控制工具（通过控制 Unix 域套接字与运行中的守护进程通信）。

## `subnetrad`（守护进程）

```text
subnetrad [--config <path>] [--check] [--print-network-plan] [--path-mtu <n>]
          [--version | -V] [--help | -h]
```

| 标志 | 参数 | 说明 |
|---|---|---|
| `--config` | path | `config.json` 路径。默认为工作目录下的 `config.json`；缺失时回退到编译进的默认值。 |
| `--check` | — | 解析配置、运行全部防呆规则、打印解析后的横幅并退出，**不** 触碰网络。用作预检（以及 systemd 的 `ExecStartPre`）。 |
| `--print-network-plan` | — | 为加载的配置打印确定的主机网络规划（`ip`/`ifconfig`/`route` 命令）并退出。主机上无任何改动。见 [主机网络规划](../configuration/network-plan.md)。 |
| `--path-mtu` | 整数 | 打印规划时覆盖假定的承载路径 MTU（默认 1500）。安全隧道 MTU 为 `path_mtu − 64`。 |
| `--version`、`-V` | — | 打印版本横幅并退出。 |
| `--help`、`-h` | — | 打印用法并退出。 |

不带动作标志时，`subnetrad` 运行守护进程：创建 TUN 设备、绑定 UDP 承载与控制套接字，并进入
反应堆循环。创建 TUN 设备需要 `CAP_NET_ADMIN`（Linux）或 root（macOS `utun`）。

```bash
# 校验、预览主机规划，然后运行
subnetrad --check --config /etc/subnetra/config.json
subnetrad --print-network-plan --config /etc/subnetra/config.json
sudo subnetrad --config /etc/subnetra/config.json
```

## `subnetra`（控制工具）

```text
subnetra status [--json]
subnetra policy show
subnetra policy add --src <CIDR> --dst <CIDR> --action forward --target <id>
subnetra save
subnetra --version | --help
```

| 命令 | 说明 |
|---|---|
| `status` | 显示守护进程健康、对端、流量计数与按原因分类的 drop 计数。守护进程未运行时 **非零** 退出。 |
| `status --json` | 以稳定的、**带版本** 的 JSON 对象输出同样数据，供监控使用。绝不序列化秘密。见 [可观测性](../operations/observability.md)。 |
| `policy show` | 打印生效的策略树（等待守护进程回复）。 |
| `policy add` | 注入一条规则，经 RCU 热更新、无需重启（fire-and-forget）。 |
| `save` | 把生效策略快照回写磁盘（等待守护进程回复）。 |
| `--version` / `--help` | 打印版本 / 用法。 |

### `policy add` 参数

| 标志 | 参数 | 说明 |
|---|---|---|
| `--src` | CIDR | 匹配内层 **源** 前缀（例如 `192.168.1.0/24`，或 `0.0.0.0/0` 表示任意）。 |
| `--dst` | CIDR | 匹配内层 **目的** 前缀（最长前缀优先）。 |
| `--action` | `forward` | 动作。（v1 通过转发到目标来路由；未路由流量被丢弃。） |
| `--target` | 网格 id | 命中后发往何处：某对端的网格 **id**，或 **`0`** 表示 *本地投递* 到本节点自身的 TUN。 |

示例：

```bash
# Site-to-Site：访问 id 为 3 的 Spoke 背后的 LAN 192.168.2.0/24
subnetra policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3

# Hub：把叠加网流量中继给正确的 Spoke
subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2

# Spoke：把发往本地叠加地址的隧道流量投递到本地 TUN
subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0

subnetra policy show
subnetra save
```

> 运行时注入的规则叠加在由 [`role`](../configuration/roles.md) 推导出的任何策略之上。用
> `subnetra save` 持久化生效的树，使其在重启后存续。

## 环境变量

| 变量 | 说明 |
|---|---|
| `SUBNETRA_SOCK` | 控制 Unix 域套接字路径。**默认 `/run/subnetra/subnetra.sock`（Linux）/ `/var/run/subnetra.sock`（macOS）**——与守护进程绑定及 systemd 单元使用的路径一致，因此 `subnetra` 与 `subnetrad` 开箱即一致。仅当需要使用非默认路径时才设置（两个进程必须保持一致）。 |

```bash
# 通常无需设置——默认值已与守护进程一致。仅当守护进程使用自定义套接字路径时才设置：
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
sudo -E subnetra status
```

## 退出码

- 守护进程宕机时 `subnetra status` 返回 **非零**——便于健康检查与 Docker `HEALTHCHECK`。
- 配置无效时 `subnetrad --check` 返回非零，因此可用于门控服务启动。

## 树外工具

这些辅助工具位于
[`tools/`](https://github.com/jamiesun/subnetra/tree/main/tools)，**绝不** 打进守护进程：

| 构建步骤 | 工具 | 用途 |
|---|---|---|
| `zig build tool:keygen` | `keygen` | 生成每链路的 64 位十六进制 PSK |
| `zig build tool:config-lint` | `config-lint` | 离线 `config.json` 校验（不依赖时钟） |
| `zig build tool:wire-decode` | `wire-decode` | 离线只读数据报解码器 |
| — | `tools/doctor.sh` | 环境预检：`/dev/net/tun`、`CAP_NET_ADMIN`、`ip`、时钟 |
