# 线协议

本页是 **Subnetra v1 线协议** 的可读摘要。权威、规范的规格——带 RFC 2119 关键词与已知答案
测试（KAT）向量——是
[`docs/PROTOCOL.md`](https://github.com/jamiesun/subnetra/blob/main/docs/PROTOCOL.md)。
若本文与规格或其向量有出入，以规格/向量为准。

> **为什么要规范规格？** 任何语言、任何实现，只要复现下面的行为，就是一个符合规范的
> Subnetra 端点，可与参考（纯 Zig）实现并肩加入网格。该行为由
> [`tests/protocol-vectors.json`](https://github.com/jamiesun/subnetra/blob/main/tests/protocol-vectors.json)
> 中的 KAT 向量钉死，在 `zig build test` 下对照活代码校验，并用 `zig build vectors` 重新生成。

## 模型

Subnetra 在加密的 UDP 承载之上、以单 Hub 星型拓扑转发裸 IPv4 包。每个节点有一个数字网格
**id**（`0 < id ≤ 65535`），它同时充当线上 `key_id` 选择器。每条方向链路
`(from_id → to_id)` 有自己的密钥。`wire_version` 为 `1`。

## 密码学原语

| 原语 | 选择 | 参数 |
|---|---|---|
| AEAD | ChaCha20-Poly1305（IETF，96-bit nonce） | 密钥 32 B，nonce 12 B，tag 16 B |
| KDF / keyed hash | BLAKE2b-256，**原生 keyed 模式（非 HMAC）** | key = 父密钥，32 B 摘要 |

### 密钥日程

喂进 KDF 的所有整数都是 **大端**；标签是无 NUL 的 ASCII。

```text
link_key(psk, from_id, to_id) =
    BLAKE2b-256(key = psk, msg = "subnetra-v1-link" || u32_be(from_id) || u32_be(to_id))

session_key(link_key, epoch) =
    BLAKE2b-256(key = link_key, msg = "subnetra-v1-session" || u64_be(epoch))
```

发送方使用 `link_key(psk, local_id, peer_id)`；接收方用 `link_key(psk, peer_id, local_id)`
派生匹配密钥。`psk` 是每链路的 32 字节秘密，**绝不得** 在对端间复用。

### Nonce

```text
nonce(seq) = u64_le(seq) || 0x00 0x00 0x00 0x00      // 8 字节 LE + 4 个零字节
```

AEAD 使用 **空 AAD**；16 字节 tag 跟在密文之后。

### 会话 epoch

每个守护进程生命周期采样一次 boot epoch（墙钟 ns，`u64`），它 **必须** ≥
`2024-01-01T00:00:00Z` 的 ns 值且非零。无法满足者 **失败即关闭**（拒绝启动）。epoch 随每个
数据报传输，接收方据此无状态派生匹配会话密钥——**没有握手**。

## 数据报格式

```text
+------------------+---------------------------+----------------+
|   报头 (20 B)    |   密文 (len(inner))       |   tag (16 B)   |
+------------------+---------------------------+----------------+
```

### 报头（20 字节，固定）

| 偏移 | 大小 | 字段 | 编码 | 含义 |
|---:|---:|---|---|---|
| 0 | 1 | `version` | u8 | 必须为 `1` |
| 1 | 1 | `flags` | u8 | bit 0 = `KEEPALIVE`；bit 1–7 保留，必须为 `0` |
| 2 | 2 | `key_id` | u16 **LE** | 发送方网格 id——接收方的对端选择器 |
| 4 | 8 | `epoch` | u64 **LE** | 发送方 boot epoch；绝不为 `0` |
| 12 | 8 | `seq` | u64 **LE** | 每会话单调序号 / nonce 基准 |

> **`key_id` 是未认证的选择器**——它 **不** 被 AEAD 覆盖（AAD 为空）。伪造的 `key_id` 只会
> 选错密钥、认证失败、数据报被丢。它让漫游/NAT 后的发送方按身份而非源端点被识别。

> **大小端陷阱：** 报头的 `epoch` 与 `seq` 是 **小端**，但喂进会话 KDF 的同一个 `epoch` 与
> 喂进链路 KDF 的 `from_id`/`to_id` 是 **大端**。KAT 向量正是为了抓住这个错误而存在。

### 保活（`flags` bit 0）

设置了 `KEEPALIVE = 0x01` 的数据报是单向 spoke→hub NAT 保活，封装在 **空** 内层明文之上，
因此总长为 `20 + 16 = 36` 字节。它复用同一套 `seq` + epoch + 防重放机制，**永不确认**，且
**不是** 握手。早于此 bit 的接收方会直接丢弃保活（严格 `flags == 0` 检查），不影响数据投递。

## 发送方（出口）

向对端 `D` 发送内层 IPv4 包 `P`：

1. `key = session_key(link_key(psk, local_id, D.id), local_epoch)`。
2. `seq = ` 本链路单调计数器的下一个值（从 `1` 起，严格递增，会话/epoch 内绝不重复）。
3. 发出报头 `version=1, flags=0, key_id=local_id, epoch=local_epoch, seq`。
4. 追加 `ChaCha20-Poly1305-Seal(key, nonce(seq), "", P)`。
5. 发往 `D` 的 UDP endpoint。

任何可能重置计数器的事件（如重启）发生时，发送方 **必须** 同时获取新 epoch（从而获得新
会话密钥）。

## 接收方（入口）

对来自源端点 `S` 的数据报，按此 **规范顺序**：

1. **身份选择**：按 `key_id`（而非端点）。无匹配对端 ⇒ 丢弃。
2. **报头校验**——若 `len < 20`、`version != 1`、设置了保留的 `flags` bit，或 `epoch == 0`，
   则丢弃。
3. **epoch 排序（只进不退）。** `epoch < cur` ⇒ 在任何加密之前丢弃；`epoch == cur` ⇒ 用缓存
   密钥；`epoch > cur` ⇒ 派生一个 *候选* 密钥但尚不提交。
4. **认证与解密**：用链路密钥与 `nonce(seq)`。失败 ⇒ 丢弃。（此时尚未改动任何状态——伪造的
   更高 epoch 或错误 `key_id` 无法毒化会话。）
5. **提交更新的 epoch**：仅在此刻（置 `cur = epoch`、缓存密钥、**重置** 防重放窗口）。
6. **防重放**——对 `seq` 施加 64 条目滑动窗口；重放/过旧 ⇒ 丢弃。*（保活在此短路：记录端点 +
   last-seen 后即停止——没有内层包。）*
7. **内层源检查**——解密后的源地址必须落在 `P` 的 `allowed_src` 内；否则丢弃（反伪造）。
8. **端点学习**——仅在第 4–7 步之后，可选地把 `S` 记录为 `P` 的当前 endpoint（漫游/NAT）。
   仅运行时状态；绝不写入配置。
9. **路由**——本地投递或（仅 Hub）中继给另一对端；Hub **绝不得** 反射回源端对端。

第 3–5 步的顺序（在改动接收状态 **之前** 认证）与第 8 步（**仅在** 4–7 之后学习端点）对
安全至关重要。

## 防重放窗口

每个接收会话保存一个 64-bit 滑动窗口（`highest` + 一个 64-bit 位图，bit *i* = 「`highest − i`
见过」）：`seq > highest` 把窗口前移并接受；窗口内未见过的 `seq` 被接受并标记；重放或早于窗口
的 `seq` 被丢弃。

## 接受的残余风险（按设计、无握手）

- **观测前 epoch 重放。** 捕获 epoch `E` 的已认证数据报、并在接收方观测到 `E` *之前* 重放它的
  路径上攻击者，可瞬时迁移该对端学到的 endpoint。它会在对端下一个真实包到来时自愈，且路径外
  攻击者无法伪造它。
- **重启间时钟倒退。** 墙钟倒退的节点发出更低的 epoch，对端会拒绝，直到其时钟越过旧值。通过
  运维（NTP/RTC）缓解，绝不通过协议内交换。

两者都直接源自[无状态、无握手设计](../concepts/design-principles.md#8-无状态无握手传输)。
