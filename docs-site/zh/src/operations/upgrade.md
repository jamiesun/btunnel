# 升级与发布

Subnetra 是单个静态二进制，**没有持久化的磁盘上数据面状态**，因此节点升级机械上就是「换掉
二进制并重启」。真正的风险是整个网格上的 **线兼容性**，下面的流程管理它。

## 升级与回滚 Runbook

由于传输是 **失败即关闭** 的——AEAD 认证失败的数据报被静默丢弃——一个跨越破坏线格式边界的
半升级网格会 **静默分区**：没有错误，只有两端不断上涨的 `auth_or_invalid` drop 计数。

安全流程：

1. **阅读发布说明** 中的任何破坏线格式变更。若线格式不变，节点在升级期间互通，先后顺序无关
   紧要。
2. **灰度金丝雀。** 先升级一个 Spoke，并在它与 Hub 两端观察 `subnetra status`——`online` 保持
   true，`auth_or_invalid` 保持平直。
3. **滚动升级** 其余节点。二进制替换是原子的；重启无状态（每个生命周期派生全新会话 epoch）。
4. **回滚** 就是反向的二进制替换 + 重启。不涉及任何状态迁移。

```bash
# 每个节点
sudo install -m 0755 subnetrad subnetra /usr/local/bin/
subnetrad --check --config /etc/subnetra/config.json
sudo systemctl restart subnetrad     # 无状态重启；派生新 epoch
subnetra status                      # 确认对端在线、auth_or_invalid 平直
```

> 留着上一个二进制以便即时回滚，并在发布过程中把 `auth_or_invalid` 当作你的分区告警。

## 密钥轮换 Runbook

PSK 是每链路的。要在不停机日的情况下轮换某条链路的密钥，可利用每个方向/epoch 独立 keyed
这一点：

1. 生成新 PSK（`openssl rand -hex 32`）。
2. 把该链路 **两端** 都更新为新 PSK。
3. 重启两端守护进程（或重启一端、接受短暂的 `auth_or_invalid` 抖动直到另一端跟上）。因为没有
   共享网格密钥，只有这一条链路受影响。

变更期间观察 `auth_or_invalid`：两端切换交叉时的瞬时上升是预期的；*持续* 上升意味着两端在密钥
上不一致。

完整分步在
[`docs/deployment.zh-CN.md` §6「Key rotation runbook」](https://github.com/jamiesun/subnetra/blob/main/docs/deployment.zh-CN.md)。

## 切发布（维护者）

发布版本只存在于 **唯一一处**：
[`build.zig.zon`](https://github.com/jamiesun/subnetra/blob/main/build.zig.zon) 的 `.version`
字段。它在构建时经 `build_options` 模块注入守护进程横幅——**绝不在 `src/` 里硬编码版本串**。

发布 `vX.Y.Z`：

1. 把 `build.zig.zon` 的 `.version` 提升到新的 `X.Y.Z`（语义化版本）。
2. 通过正常 PR 流程在 `main` 上提交该提升。
3. 给该提交打 `vX.Y.Z` 标签——标签 **必须** 等于 `v` + `build.zig.zon` 版本。一个守卫作业会在
   两者不一致时让发布失败，因此不匹配的标签绝不会发出去。
4. 推送 `v*` 标签触发
   [`.github/workflows/release.yml`](https://github.com/jamiesun/subnetra/blob/main/.github/workflows/release.yml)，
   它构建四架构静态二进制、GHCR 多架构镜像、离线可 `docker load` 的按架构镜像 tar 包，以及
   macOS Spoke 二进制，并把它们全部连同合并的 `SHA256SUMS.txt` 发布到 GitHub Release。

在未先提升 `build.zig.zon` 匹配之前，**不要** 创建 `v*` 标签。发布流程文档见
[`docs/release.md`](https://github.com/jamiesun/subnetra/blob/main/docs/release.md)。

## 校验下载

每个发布都附带 `SHA256SUMS.txt`。安装或 `docker load` 任何产物前先校验：

```bash
sha256sum -c SHA256SUMS.txt 2>/dev/null | grep subnetra-<version>-linux-amd64.tar.gz
```
