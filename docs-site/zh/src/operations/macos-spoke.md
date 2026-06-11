# macOS Spoke

macOS 作为拨向既有 Linux/RouterOS **Hub** 的 **Spoke** 受支持。数据通路在 `utun` +
`poll(2)` 上原生运行，由 comptime 在 `src/os/` 之后选择。macOS **Hub**、`kqueue` 与自动路由
变更明确不在范围内。

由于 macOS 没有网络命名空间，且托管的 mac CI runner 无法在无提权下创建 `utun`，所以 macOS
Spoke 是 **Runbook 验收** 而非 CI 门禁。权威流程见
[`docs/macos-spoke-acceptance.md`](https://github.com/jamiesun/subnetra/blob/main/docs/macos-spoke-acceptance.md)。

## 前置条件

- 一台有 `sudo` 权限的真实 Mac（Apple Silicon 或 Intel）——创建 `utun` 需要 root。
- 一个发布的 macOS 二进制，或 **Zig 0.16.0+** 以从源码构建。
- 一个可达、已正常工作的 Linux/RouterOS Hub，具备稳定承载端点，并为这台 Mac 签发了每对端
  **PSK**。
- 至少一个可跨隧道 ping 的远端叠加目标。

> macOS 二进制是 **最小动态** 的——它只链接 `libSystem`（仍零第三方依赖），因此 *不是* 静态
> 可执行文件。**不要** 对它运行仅 Linux 的 `ldd → not a dynamic executable` 检查。

## 安装

从发布 tar 包（`subnetra-<version>-macos-arm64.tar.gz` 或 `-amd64`）：

```bash
tar -xzf subnetra-<version>-macos-arm64.tar.gz
cd subnetra-<version>-macos-arm64
# Gatekeeper 会隔离下载的二进制——清除隔离属性（或从源码构建）：
xattr -d com.apple.quarantine subnetrad subnetra 2>/dev/null || true
```

或用 `zig build` 本地构建（见 [安装](../getting-started/installation.md)）。

## 配置

写一个 Spoke `config.json`（见 [角色](../configuration/roles.md)），以 Hub 作为唯一对端，并
填入这台 Mac 的叠加地址：

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 4,
  "local_tun_ip": "10.0.0.4/24",
  "local_routes": ["10.0.0.4/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:18020", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

## 预览主机规划

在 macOS 上规划输出 `ifconfig` / `route` 命令（守护进程绝不应用它们）：

```bash
./subnetra --print-network-plan --config config.json
```

## 运行

```bash
sudo ./subnetrad --config config.json
# subnetra v… (… mode=raw_direct …) tun=utun4 sock=/var/run/subnetra.sock [ready]
```

`utunN` 网卡名由 **内核分配**——从 `[ready]` 横幅读取它，然后用真实名字应用规划：

```bash
sudo ifconfig utun4 inet 10.0.0.4 10.0.0.4 mtu 1400 up
sudo route add -net 10.0.0.0/24 -interface utun4
```

## 在 launchd 下运行

为持久化 Spoke，安装系统守护进程 plist（以 root 运行、异常退出时重启、记录到
`/var/log/subnetrad.log`）：

```bash
sudo install -m 0644 deploy/net.subnetra.subnetrad.plist \
    /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.subnetra.subnetrad.plist
sudo launchctl enable system/net.subnetra.subnetrad
```

用 `sudo launchctl kickstart -k system/net.subnetra.subnetrad`（重启）与
`sudo launchctl bootout system/net.subnetra.subnetrad`（停止）管理它。

> `KeepAlive` 可能把守护进程重启到 **不同** 的 `utunN`；重读横幅并重新应用规划。Subnetra
> 刻意把路由留给你（无自动路由变更）。

## 验证

```bash
sudo ./subnetra status      # 对端在线、计数在涨
ping 10.0.0.3               # 跨隧道的一个远端叠加目标
```
