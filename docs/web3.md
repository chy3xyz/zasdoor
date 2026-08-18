# Web3 / SIWE 模块(Sign-In With Ethereum)

> EIP-4361 签名登录 + 钱包绑定,签发标准 JWT。
> 对应代码:`src/modules/web3/`(siwe_message.zig 解析器、service.zig 验证、api.zig 路由)。

## 1. 流程

```
前端 (wallet 签名 EIP-191 personal_sign)         后端
   │  POST /web3/siwe/nonce {address, domain}      保留 nonce(绑定 domain+address,TTL 600s)│
   │◄────────────────────── { nonce, ttl } ──────────┤
   │  构造 EIP-4361 消息 + 钱包签名 r‖s‖v           │
   │  POST /web3/siwe/verify {message, signature, domain}│
   │──── EIP-4361 解析 → ECDSA 恢复地址 → nonce 单次消费 →│
   │◄── 已绑定: { token, user_id } / 未绑定: { needs_bind } ──┤
```

## 2. 验证细节

- **EIP-4361 解析**:domain、address、statement、URI、Version、Chain ID、Nonce、Issued At、Expiration Time、Not Before、Resources。
- **签名**:`keccak256("\x19Ethereum Signed Message:\n" + len + message)` 摘要,Secp256k1 公钥恢复 → Ethereum 地址(keccak256(x‖y) 末 20 字节,不区分大小写比较)。
- **Nonce**:单次使用,消费即删;必须与预留的 (domain, address) 精确匹配。
- **Domain 校验**:消息中的 domain 必须等于请求 `domain` 字段,防跨站钓鱼。

## 3. HTTP API

| Method | Path | 说明 |
| --- | --- | --- |
| POST | `/api/v1/web3/siwe/nonce` | 公开。请求 `{address, domain}` → `{nonce, ttl}` |
| POST | `/api/v1/web3/siwe/verify` | 公开。请求 `{message, signature(130 hex), domain}` → `{token, user_id}` 或 `{needs_bind:true}` |
| POST | `/api/v1/web3/wallet/bind` | 已登录。请求 `{chain, address}` 绑定钱包到当前用户 |

## 4. 与登录的关系

- 钱包已绑定用户 → verify 直接返回 JWT(`sub` = 用户 ID)。
- 未绑定 → 返回 `needs_bind`,前端引导走账号绑定(先登录或注册,再 `wallet/bind`)。
- 同一钱包可被多个用户查询(`GET /web3/wallet/{address}` 供管理端),但绑定唯一。

## 5. 安全要点

- nonce 必须来自服务端(防重放),且单次使用。
- 签名长度/格式严格校验(130 hex = r 32 ‖ s 32 ‖ v 1 字节)。
- recovery id 归一化:`v >= 27 ? v - 27 : v & 1`。
- 消息过期时间(Expiration Time)强制校验,防长期重放。