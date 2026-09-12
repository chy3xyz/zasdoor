# OAuth2 / OIDC 模块

> OAuth2 / OIDC 协议表面:discovery、JWKS、authorize、token、introspect、revoke、userinfo。
> 对应代码:`src/modules/oauth/`(service.zig 协议逻辑、jwt.zig 令牌、api.zig 路由)。

## 1. 支持的流程

| 流程 | 说明 |
| --- | --- |
| `authorization_code` | 授权码 + 回调,支持 **PKCE**(`plain` / `S256`,应用可强制 `pkce_required`) |
| `client_credentials` | 客户端凭证(机器对机器),以 `client_id`/`client_secret` 换 token |
| `refresh_token` | 刷新令牌续期 |

- 签名算法:**EdDSA(Ed25519)**,非对称 —— ID Token 可由第三方客户端拿公开 JWKS 验签。
  - 签名密钥从平台 `ZASDOOR_JWT_SECRET` 经 **HKDF-SHA256** 确定性派生(`src/modules/oauth/keys.zig`),因此重启后密钥不变,无需新增配置。
  - `kid` = SHA-256(公钥)的前 8 字节(hex);JWK 只含公开字段(私钥永不输出)。
  - 仍接受旧的 **HS256** 令牌(用于 introspection 兼容)。ES256(P-256)实现已就位(jwt.zig / keys.zig),接入为后续工作。
- Scope:`openid`、`profile`、`email`、`offline_access`。
- ID Token 由授权码兑换时签发,`sub` 为用户 ID,含 `iss`(issuer)、`aud`(client_id)、`exp`。
- **用户同意(consent)**:请求的 scope 未获授权前不发放授权码。

## 2. 端点(注册在 server 根路径,协议面公开)

| Method | Path | 说明 |
| --- | --- | --- |
| GET | `/.well-known/openid-configuration` | OIDC Discovery 文档 |
| GET | `/.well-known/jwks.json` | JWKS:返回 EdDSA 公钥(`{"keys":[...]}`),供第三方验签 |
| GET/POST | `/oauth/authorize` | 授权端点:校验 client、redirect_uri、scope、PKCE challenge;scope 未授权时返回同意请求 |
| POST | `/oauth/token` | 令牌端点:`authorization_code` + verifier / `client_credentials` / `refresh_token` |
| POST | `/oauth/introspect` | 令牌 introspection(active / client / scope / exp) |
| POST | `/oauth/revoke` | 令牌吊销 |
| GET | `/oauth/userinfo` | 用户信息(要求 access token) |

## 3. 典型授权码 + PKCE 流程

1. **创建应用**(IAM 管理端)→ 得到 `client_id` / `client_secret` / `redirect_uri`。
2. 前端生成 `code_verifier`(随机串)与 `code_challenge`(S256:base64url(sha256(verifier)),或 plain)。
3. 跳转 `/oauth/authorize?client_id=...&redirect_uri=...&response_type=code&scope=openid%20profile&code_challenge=...&code_challenge_method=S256`。
4. 若该用户尚未同意这些 scope,服务端返回同意请求而非授权码:
   `200 {"code":0,"msg":"consent_required","data":{"consent_required":true,"scopes":[...]}}`;
   用户确认后重放同一请求并带 `consent_granted=true`(query 或 form),服务端记录同意再发 code。
5. 同意已覆盖(或刚授予)→ 302 回 `redirect_uri?code=xxx`;未登录 → 302 到登录页,成功后继续。
6. 后端 `POST /oauth/token`(form):`grant_type=authorization_code&code=xxx&redirect_uri=...&code_verifier=...` + `client_id` / `client_secret`(Basic 或 form)。
7. 响应:`{ access_token, token_type: "Bearer", expires_in, id_token?, refresh_token? }`;
   `id_token` 头部带 `alg=EdDSA`、`kid`,可用 discovery 的 `jwks_uri` 验签。

## 4. 安全要点

- PKCE challenge 在兑换时用 verifier 重算比对,防授权码拦截。
- `redirect_uri` 必须精确匹配应用白名单(精确字符串比较)。
- `authorization_code` 单次使用,兑换后即失效;过期时间短(默认数分钟)。
- refresh token 支持吊销(`/oauth/revoke`);轮换策略可在 service 层扩展。
- 签名密钥由 `ZASDOOR_JWT_SECRET` 派生(生产强制显式配置),否则启动失败;轮换该 secret 即轮换全部 OIDC 签名密钥与 `kid`。
- 同意记录按 (application, user) 存储,精确到 scope token;请求范围超出已授予范围时会再次要求同意。
- 客户端只能拿到公钥 JWKS,私钥永不出服务端。