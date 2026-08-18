# OAuth2 / OIDC 模块

> OAuth2 / OIDC 协议表面:discovery、JWKS、authorize、token、introspect、revoke、userinfo。
> 对应代码:`src/modules/oauth/`(service.zig 协议逻辑、jwt.zig 令牌、api.zig 路由)。

## 1. 支持的流程

| 流程 | 说明 |
| --- | --- |
| `authorization_code` | 授权码 + 回调,支持 **PKCE**(`plain` / `S256`,应用可强制 `pkce_required`) |
| `client_credentials` | 客户端凭证(机器对机器),以 `client_id`/`client_secret` 换 token |
| `refresh_token` | 刷新令牌续期 |

- 签名算法:**HS256**(对称),与主 JWT 共用 HMAC secret(`kid=null`)。
- Scope:`openid`、`profile`、`email`、`offline_access`。
- ID Token 由授权码兑换时签发,`sub` 为用户 ID,含 `iss`(issuer)、`aud`(client_id)、`exp`。

## 2. 端点(注册在 server 根路径,协议面公开)

| Method | Path | 说明 |
| --- | --- | --- |
| GET | `/.well-known/openid-configuration` | OIDC Discovery 文档 |
| GET | `/.well-known/jwks.json` | JWKS(HS256 对称签名,返回空 keys) |
| GET/POST | `/oauth/authorize` | 授权端点:校验 client、redirect_uri、scope、PKCE challenge,登录态下直接发 code |
| POST | `/oauth/token` | 令牌端点:`authorization_code` + verifier / `client_credentials` / `refresh_token` |
| POST | `/oauth/introspect` | 令牌 introspection(active / client / scope / exp) |
| POST | `/oauth/revoke` | 令牌吊销 |
| GET | `/oauth/userinfo` | 用户信息(要求 access token) |

## 3. 典型授权码 + PKCE 流程

1. **创建应用**(IAM 管理端)→ 得到 `client_id` / `client_secret` / `redirect_uri`。
2. 前端生成 `code_verifier`(随机串)与 `code_challenge`(S256:base64url(sha256(verifier)),或 plain)。
3. 跳转 `/oauth/authorize?client_id=...&redirect_uri=...&response_type=code&scope=openid%20profile&code_challenge=...&code_challenge_method=S256`。
4. 用户已登录 → 302 回 `redirect_uri?code=xxx`;未登录 → 302 到登录页,成功后继续。
5. 后端 `POST /oauth/token`(form):`grant_type=authorization_code&code=xxx&redirect_uri=...&code_verifier=...` + `client_id` / `client_secret`(Basic 或 form)。
6. 响应:`{ access_token, token_type: "Bearer", expires_in, id_token?, refresh_token? }`。

## 4. 安全要点

- PKCE challenge 在兑换时用 verifier 重算比对,防授权码拦截。
- `redirect_uri` 必须精确匹配应用白名单(精确字符串比较)。
- `authorization_code` 单次使用,兑换后即失效;过期时间短(默认数分钟)。
- refresh token 支持吊销(`/oauth/revoke`);轮换策略可在 service 层扩展。
- HS256 需要 `ZASDOOR_JWT_SECRET` 显式配置(生产强制),否则启动失败。