# MFA 模块(多因素认证)

> TOTP + 恢复码 + 租户级 MFA 策略 + 联合登录(IdP)。
> 对应代码:`src/modules/mfa/`(model → persistence → service → api;社交登录见 `idp.zig` / `idp_api.zig`)。

## 1. 能力

- **TOTP**:RFC 6238 时间一次性密码(HmacSHA1、6 位、30 秒窗口),注册返回 **base32 secret** 与 otpauth URL。
- **验证**:`totp/verify` 校验当前码(带 ±1 窗口容差),成功后标记设备已启用。
- **恢复码**:启用 TOTP 时生成一次性恢复码(哈希存储),用于丢失设备时重新登录。
- **策略**:租户级 `mfa/policy`,`enforce` 为 true 时该租户登录强制要求第二因子。

## 2. HTTP API(全部要求已登录 JWT)

| Method | Path | 说明 |
| --- | --- | --- |
| POST | `/api/v1/mfa/totp/enroll` | 开始注册,返回 `{ secret, otpauth_url }`(base32) |
| POST | `/api/v1/mfa/totp/verify` | 提交 6 位码完成注册/校验 |
| POST | `/api/v1/mfa/verify` | 通用第二因子验证(登录流程第二步) |
| GET | `/api/v1/mfa/recovery` | 列出未使用的恢复码 |
| POST | `/api/v1/mfa/recovery` | 生成新恢复码(需二次确认) |
| GET | `/api/v1/mfa/policy` | 读取租户 MFA 策略 |
| PUT | `/api/v1/mfa/policy` | 设置租户 MFA 策略(`enforce`) |

## 3. 登录流程接入

1. 用户密码登录成功 → 若策略 `enforce` 且用户已启用 TOTP,响应标记 `mfa_required: true`。
2. 前端引导输入 6 位码 → `POST /mfa/verify`(携带临时会话标识 + code)。
3. 校验通过后签发正式 JWT。

## 4. 安全要点

- secret 只在 enroll 响应中出现一次;后续仅存 TOTP 共享密钥的校验配置,不落明文。
- 恢复码以单向哈希存储,列表展示脱敏,使用一次即失效。
- 验证带时间窗口容差(±1 步),防时钟漂移;连续失败可叠加限速(复用登录限流设施)。
## 5. 联合登录 / 社交登录(IdP)

后端同时提供 OAuth2/OIDC 身份提供方(IdP)联合登录,见 `idp.zig` / `idp_api.zig`。

| Method | Path | 访问 | 说明 |
| --- | --- | --- | --- |
| GET/POST | `/api/v1/mfa/idps` | 管理员 | 列出 / 新建提供方(name、type、config JSON) |
| POST | `/api/v1/mfa/idps/{id}/link` | 管理员 | 用 config + state 生成授权链接(不落库) |
| POST | `/api/v1/mfa/idps/{id}/start` | 公开 | 生成一次性 `state`(TTL 600s)并返回 `{ authorize_url, state }` |
| GET | `/api/v1/mfa/idps/{id}/callback?code=&state=` | 公开 | 消费 state → 兑换 code → 取 userinfo/id_token → 绑定或创建本地用户 → 返回 JWT |

流程:

1. 前端调 `start` 拿到 `authorize_url` + `state`,跳转到提供方。
2. 提供方回调 `callback?code=&state=`;服务端先校验 state(**未知 / 过期 / 重放**都拒绝并消费),再在服务端用 `client_id`/`client_secret` 兑换令牌(form 编码 POST)。
3. 用 access token 拉 `userinfo`(无该端点时解析 `id_token`)取出 `sub`、`email`、`name`、`email_verified`。
4. 按 `(provider, sub)` 复用已有绑定;否则决定是否创建本地账号。

### 账号关联安全规则(重要)

- 已有绑定 → 直接复用。
- 存在同邮箱本地账号:仅当提供方声明 `email_verified = true` 时**才允许自动关联**;否则返回 `409`,要求用户先登录后在个人资料中显式绑定 —— 防止任意提供方用他人(未验证)邮箱接管账号。
- 新建的联邦账号 `verified` 直接取提供方的 `email_verified`,不再无条件置真。
- 邮箱查找**按租户隔离**,杜绝跨租户关联。
- 联邦账号使用不可登录的密码占位标记,只能走 IdP 登录。

回调成功以 JSON 信封返回 `{ code, msg, data: { token, user } }`(而非重定向),前端读取并保存 token。