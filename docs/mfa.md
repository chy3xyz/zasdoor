# MFA 模块(多因素认证)

> TOTP + 恢复码 + 租户级 MFA 策略。
> 对应代码:`src/modules/mfa/`(model → persistence → service → api)。

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