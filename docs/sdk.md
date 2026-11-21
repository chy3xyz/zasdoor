# SDK & HTTP API consumer guide

> Machine-readable source of truth: [openapi.yaml](openapi.yaml) (OpenAPI 3.1, 113 paths, API version 0.5.0).
> This page explains **how to consume** the API. It deliberately does not commit generated client code — regenerate a client from the spec instead (see [Regenerating clients](#5-regenerating-clients-from-the-spec)).

## 1. Base URL and path layout

Default server root: `http://127.0.0.1:8000` (configure with `ZASDOOR_HTTP_PORT`; the advertised OIDC issuer uses `ZASDOOR_APP_HOST`).

| Surface | Prefix | Example |
| --- | --- | --- |
| Admin / application JSON API | `/api/v1` | `POST /api/v1/auth/login` |
| OAuth2 / OIDC protocol endpoints | server root, no prefix | `POST /oauth/token` |
| Discovery / JWKS | server root | `GET /.well-known/openid-configuration` |
| Health & metrics | both `/health/live` and `/api/v1/health/live`, `/metrics` at root | `GET /api/v1/health/ready` |

Set the base once in your client, e.g. `ZASDOOR_BASE=http://127.0.0.1:8000`, and use `"$ZASDOOR_BASE/api/v1/..."` for admin calls.

## 2. Authentication (bearer JWT)

Routes documented with `bearerAuth` require:

```http
Authorization: Bearer <JWT>
```

- Obtain a JWT from `POST /api/v1/auth/login`, `POST /api/v1/auth/register`, `POST /api/v1/mfa/login/finish`, `POST /api/v1/mfa/webauthn/login/finish`, `POST /api/v1/web3/siwe/verify`, or an IdP callback. Agent tokens come from `POST /api/v1/agents/{id}/token`; OAuth access tokens come from `POST /oauth/token`.
- The JWT carries `sub` (user id), `roles`, `aud` (tenant id) and `ver` (token version). The server checks `ver` against the database, so a password change or session revocation invalidates older tokens immediately.
- Admin-only routes additionally check the user's `admin` flag in the database; a non-admin gets `403`.
- Public `/api/v1/auth/*` routes and WebAuthn passkey login are rate limited per client IP (token bucket) → `429` when exhausted.
- OAuth2 protocol endpoints return **raw RFC-shaped JSON / errors**, not the envelope (see [oauth.md](oauth.md)).

Send the token on every admin call:

```bash
curl -sS "$ZASDOOR_BASE/api/v1/auth/me" \
  -H "Authorization: Bearer $ZASDOOR_TOKEN"
```

## 3. Response envelope, pagination and errors

Most admin endpoints return the "ruoyi" envelope:

```json
{ "code": 0, "msg": "ok", "data": { } }
```

- `code = 0` means success; **always check both the HTTP status and `code`**.
- Errors use the same shape with `data: null` and a numeric `code` that normally equals the HTTP status:

| HTTP / `code` | Meaning | Typical cause |
| --- | --- | --- |
| `400` | Bad request | invalid JSON, missing field, password-policy violation |
| `401` | Unauthorized | missing/expired JWT, bad credentials, wrong MFA code |
| `403` | Forbidden | non-admin on admin route, missing capability, no consent, MFA required |
| `404` | Not found | unknown resource id |
| `409` | Conflict | e-mail already registered, duplicate credential |
| `429` | Too many requests | per-IP rate limit, account lockout, exhausted agent budget |
| `500` | Internal error | unexpected server-side failure |
| `503` | Service unavailable | readiness probe: datastore unreachable |

**Pagination**: most lists use `page`/`page_size` and return
`{list,total,page,pageSize}`. Audit logs additionally support keyset
pagination at `GET /audit-logs/cursor?after=<next_cursor>&limit=50`, returning
`{list,next_cursor,has_more}`; this is the preferred pattern for large tables.

**Rate limiting / HA**: the in-process token bucket is per node. In a
multi-replica deployment, enforce the same limits at the gateway/Ingress until
a shared backend is wired (zmodu 0.43.8 does not yet export a Redis limiter
consumable API).

**Tracing / observability**: `zmodu.http.tracingMiddleware()` propagates
`x-trace-id`, sets the request trace scope and logs method/path/status/elapsed
μs. `/metrics` is Prometheus text (IP-allowlisted when configured). OTLP
export is not built in — bridge the structured trace logs with a collector.

Special cases you must branch on:

- **MFA step-up**: `POST /api/v1/auth/login` can answer `403` with `{"code":403,"msg":"需要二次验证","data":{"mfa_required":true,"login_url":"/api/v1/mfa/login/finish"}}`. Finish at `/api/v1/mfa/login/finish` with the same credentials plus `code`.
- **Consent**: `/oauth/authorize` can answer `200` with `{"code":0,"msg":"consent_required","data":{"consent_required":true,"scopes":[...]}}`; retry with `consent_granted=true`.
- **OAuth errors** are raw: `{"error":"invalid_grant","error_description":"..."}` (RFC 6749/8628/8693). Device polling returns `authorization_pending` / `slow_down`.

Paginated endpoints accept `page` (1-based, default 1) and `page_size` (default 20; clamped per endpoint — often 1..100, audit logs 1..200). Response `data`:

```json
{ "list": [], "total": 0, "page": 1, "pageSize": 20 }
```

```bash
curl -sS "$ZASDOOR_BASE/api/v1/users?page=1&page_size=20" \
  -H "Authorization: Bearer $ZASDOOR_TOKEN" | jq '.data.list, .data.total'
```

**Raw (non-enveloped) responses**: OAuth2/OIDC endpoints, WebAuthn `login/begin` and `register/begin` option objects, `/metrics`, CSV exports, file downloads and AI SSE streams. Do not look for `code`/`data` in those bodies.

## 4. Minimal clients (no generated SDK required)

### TypeScript / browser or Node 18+ (`fetch`)

```ts
const BASE = process.env.ZASDOOR_BASE ?? "http://127.0.0.1:8000";
type Envelope<T> = { code: number; msg: string; data: T };

export async function api<T>(path: string, opts: RequestInit = {}, token?: string): Promise<T> {
  const res = await fetch(`${BASE}/api/v1${path}`, {
    ...opts,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...opts.headers,
    },
  });
  const body = await res.json() as Envelope<T>;
  if (!res.ok || body.code !== 0) throw new Error(`${res.status} ${body.code}: ${body.msg}`);
  return body.data;
}

const session = await api<{ token: string }>("/auth/login", {
  method: "POST",
  body: JSON.stringify({ email: "alice@example.com", password: "Correct-Horse-9" }),
});
const me = await api<{ id: number; name: string }>("/auth/me", {}, session.token);
```

For the OAuth/protocol surface call the **root** path and send form data (`new URLSearchParams({...})`) — those endpoints do not use the envelope.

### Python (`requests`)

```python
import os, requests

BASE = os.getenv("ZASDOOR_BASE", "http://127.0.0.1:8000")

def api(method: str, path: str, *, token: str | None = None, **kwargs):
    headers = kwargs.pop("headers", {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = requests.request(method, f"{BASE}/api/v1{path}", headers=headers, timeout=10, **kwargs)
    r.raise_for_status()
    body = r.json()
    if body.get("code") != 0:
        raise RuntimeError(f"{body.get('code')}: {body.get('msg')}")
    return body["data"]

session = api("POST", "/auth/login", json={"email": "alice@example.com", "password": "Correct-Horse-9"})
token = session["token"]
users = api("GET", "/users", token=token, params={"page": 1, "page_size": 20})
print(users["total"], len(users["list"]))
```

### Zig (`std.http.Client`)

Zig has no bundled OpenAPI generator in this repo; use a thin wrapper around `std.http.Client` (the project already depends on `zmodu` for server-side HTTP, but a client needs only the standard library). Sketch for Zig 0.14/0.15-era APIs:

```zig
const std = @import("std");

fn apiGet(allocator: std.mem.Allocator, token: []const u8, path: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:8000/api/v1{s}", .{path});
    defer allocator.free(url);
    var request = try client.open(.GET, try std.Uri.parse(url), .{});
    defer request.deinit();
    try request.headers.append("Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}));
    try request.send(.{});
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();
    try request.receive(.{ .response_storage = .{ .dynamic = &body } });
    return body.toOwnedSlice(); // parse envelopes with std.json; check code == 0 and data
}
```

Parse with `std.json.parseFromSlice` against a struct matching `{ code: i64, msg: []const u8, data: ... }`, or use `std.json.Value` when `data` shape varies. Keep bearer tokens out of logs and shell history (use environment variables, as in the curl examples in [api-examples.md](api-examples.md)).

## 5. Regenerating clients from the spec

Do **not** hand-edit generated files — regenerate them. The spec is self-contained (all $refs are internal), so no bundling step is needed.

**OpenAPI Generator** (Java 11+; TypeScript, Python, and many other targets):

```bash
# TypeScript / Node client
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi.yaml -g typescript-fetch -o generated/ts-client \
  --additional-properties=supportsES6=true

# Python client
npx @openapitools/openapi-generator-cli generate \
  -i docs/openapi.yaml -g python -o generated/python-client \
  --additional-properties=packageName=zasdoor
```

Install once instead of via npx if preferred: `pip install openapi-generator-cli` then `openapi-generator-cli generate ...` with the same flags. Validate the spec first:

```bash
npx @redocly/cli lint docs/openapi.yaml
```

**Orval** (React Query / TypeScript clients, when adding a web SDK):

```bash
# orval.config.ts:
# export default { zasdoor: { input: './docs/openapi.yaml',
#   output: { target: './generated/orval.ts', client: 'fetch', mode: 'tags-split' } } };
pnpm dlx orval --config orval.config.ts
```

Generated directories (`generated/`) should stay gitignored; consumers check out the spec and regenerate. For endpoint-by-endpoint semantics see [openapi.yaml](openapi.yaml), [oauth.md](oauth.md), [iam.md](iam.md), [mfa.md](mfa.md), [webauthn.md](webauthn.md), [authz.md](authz.md) and [agent.md](agent.md). Run-through curl recipes for nearly every flow live in [api-examples.md](api-examples.md).
