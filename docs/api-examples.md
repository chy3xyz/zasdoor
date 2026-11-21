# End-to-end curl examples

Every example is a runnable shell snippet against a local server. Source of truth: [openapi.yaml](openapi.yaml); conceptual background: [oauth.md](oauth.md), [mfa.md](mfa.md), [webauthn.md](webauthn.md), [iam.md](iam.md), [orgstruct.md](orgstruct.md), [authz.md](authz.md), [agent.md](agent.md), [eventstore.md](eventstore.md).

```bash
export ZASDOOR_BASE=http://127.0.0.1:8000
export EMAIL=alice@example.com
export PASSWORD='Correct-Horse-9'
# After step 1/2, export the returned JWT:
# export TOKEN='<data.token from login>'
```

> Conventions: admin paths use `$ZASDOOR_BASE/api/v1`; OAuth/OIDC, `/health/live` and `/metrics` are at the **server root**. `jq` is used for readability; `-sS` keeps curl quiet but shows errors. All admin JSON responses use `{code,msg,data}` with `code=0` for success; OAuth protocol responses are raw.

## 1. Register a new account

Public, rate-limited per IP. Returns `201` and a session JWT (also queues a verification email).

```bash
curl -sS -X POST "$ZASDOOR_BASE/api/v1/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Alice\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jq .
# => {"code":0,"msg":"...","data":{"token":"<JWT>","user":{...},"session_id":"..."}}
# 400 = password policy / invalid input; 409 = email taken; 429 = rate limit
```

## 2. Password login (single factor)

```bash
RESP=$(curl -sS -w '\n%{http_code}' -X POST "$ZASDOOR_BASE/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
BODY=$(echo "$RESP" | head -n -1); STATUS=$(echo "$RESP" | tail -n 1)
echo "$STATUS $BODY" | jq -R .
if [ "$STATUS" = 200 ]; then
  export TOKEN=$(echo "$BODY" | jq -r '.data.token')
elif [ "$STATUS" = 403 ] && echo "$BODY" | jq -e '.data.mfa_required == true' >/dev/null; then
  echo "MFA required -> continue at example 3"
fi
# 401 = bad credentials / lockout; 429 = rate limit or account lockout
```

## 3. MFA login flow (`/auth/login` 403 → `/mfa/login/finish`)

When the tenant enforces MFA and the user has TOTP enrolled, step 1 never yields a token. Finish with the same credentials and a 6-digit TOTP code. Recovery codes are single-use alternatives. See [mfa.md](mfa.md).

```bash
# Step 1: login signals step-up (403)
curl -sS -X POST "$ZASDOOR_BASE/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jq .
# => {"code":403,"msg":"需要二次验证","data":{"mfa_required":true,"login_url":"/api/v1/mfa/login/finish"}}

# Step 2: submit password + TOTP code to the public finish endpoint
curl -sS -X POST "$ZASDOOR_BASE/api/v1/mfa/login/finish" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"code\":\"123456\"}" | jq -r '.data.token'
# 401 = wrong credentials or code. Enrollment (JWT required):
#   POST /api/v1/mfa/totp/enroll -> {secret, otpauth_url}
#   POST /api/v1/mfa/totp/verify {"code":"123456"} -> enables the device
```

## 4. OAuth2 authorization code + PKCE (S256)

Create an application first (example 9) to obtain `client_id` / `client_secret` and register `redirect_uri`. New apps require PKCE by default. See [oauth.md](oauth.md).

```bash
export CLIENT_ID=my-web-app
export CLIENT_SECRET='<from application creation>'
export REDIRECT_URI='http://localhost:3000/callback'
export VERIFIER='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'  # use a fresh random 43-128 char string
export CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
export STATE=$(openssl rand -hex 16)
export NONCE=$(openssl rand -hex 16)

# 4a. Browser: GET the authorize URL while signed in (Bearer identifies the resource owner).
printf '%s\n' "$ZASDOOR_BASE/oauth/authorize?client_id=$CLIENT_ID&redirect_uri=$(python3 -c "import urllib.parse,os;print(urllib.parse.quote(os.environ['REDIRECT_URI'],safe=''))")&response_type=code&scope=openid%20profile&state=$STATE&nonce=$NONCE&code_challenge=$CHALLENGE&code_challenge_method=S256"
# If the response is {"msg":"consent_required",...}, replay with consent_granted=true.
# On success: 302 -> $REDIRECT_URI?code=<AUTH_CODE>&state=$STATE

# 4b. Exchange the code (form-encoded; client_secret_post). Copy the code from the redirect:
export AUTH_CODE='<code from redirect>'
curl -sS -X POST "$ZASDOOR_BASE/oauth/token" \
  -d "grant_type=authorization_code" -d "code=$AUTH_CODE" \
  -d "redirect_uri=$REDIRECT_URI" -d "code_verifier=$VERIFIER" \
  -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET" | jq .
# => {access_token, token_type:"Bearer", expires_in, id_token, refresh_token, scope}
# Verify id_token with the public JWKS from /.well-known/jwks.json (EdDSA / Ed25519).
```

## 5. OAuth2 client credentials (machine-to-machine)

```bash
curl -sS -X POST "$ZASDOOR_BASE/oauth/token" \
  -d 'grant_type=client_credentials' \
  -d 'scope=openid profile' \
  -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET" | jq .
# curl sends application/x-www-form-urlencoded by default with -d.
# Note: this handler reads credentials from the form; client_secret_basic is NOT parsed.
```

## 6. Device authorization flow (RFC 8628)

No-browser device obtains a `user_code`, the signed-in user approves it, then the device polls the token endpoint. Pending polls answer `400 {"error":"authorization_pending"}`; poll no faster than `interval` seconds (`slow_down` otherwise). See [oauth.md](oauth.md).

```bash
# 6a. Device: start authorization (public)
AUTH=$(curl -sS -X POST "$ZASDOOR_BASE/oauth/device_authorization" \
  -d "client_id=$CLIENT_ID" -d 'scope=openid profile' | jq .)
echo "$AUTH"
export USER_CODE=$(echo "$AUTH" | jq -r '.user_code')
export DEVICE_CODE=$(echo "$AUTH" | jq -r '.device_code')

# 6b. User: on a signed-in browser/client, approve the displayed user_code
curl -sS -X POST "$ZASDOOR_BASE/oauth/device" \
  -H "Authorization: Bearer $TOKEN" \
  -d "user_code=$USER_CODE" -d 'approve=true' | jq .
# => {"code":0,"msg":"approved","data":null}  (deny=true rejects)

# 6c. Device: poll for the token
curl -sS -X POST "$ZASDOOR_BASE/oauth/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  -d "device_code=$DEVICE_CODE" -d "client_id=$CLIENT_ID" | jq .
```

## 7. Token exchange (RFC 8693) and refresh token

Exchange a JWT/access token for a new token, optionally narrowed to an audience, with a delegated `act` claim. Refresh tokens are single-use with rotation; replay of a rotated token revokes the whole family. See [oauth.md](oauth.md).

```bash
# 7a. Token exchange (subject_token_type must be a JWT-style URN)
curl -sS -X POST "$ZASDOOR_BASE/oauth/token" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d "subject_token=$ACCESS_TOKEN" \
  -d 'audience=my-downstream-api' -d 'scope=profile' | jq .
# => {access_token, ..., issued_token_type:"urn:ietf:params:oauth:token-type:access_token"}

# 7b. Refresh an OAuth access token (rotates the refresh token)
curl -sS -X POST "$ZASDOOR_BASE/oauth/token" \
  -d 'grant_type=refresh_token' -d "refresh_token=$REFRESH_TOKEN" \
  -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET" | jq .

# 7c. Introspect and revoke (no client authentication — keep on a trusted network)
curl -sS -X POST "$ZASDOOR_BASE/oauth/introspect" -d "token=$ACCESS_TOKEN" | jq .
curl -sS -X POST "$ZASDOOR_BASE/oauth/revoke" -d "token=$REFRESH_TOKEN" -i
# OIDC userinfo / discovery / JWKS:
curl -sS "$ZASDOOR_BASE/oauth/userinfo" -H "Authorization: Bearer $ACCESS_TOKEN" | jq .
curl -sS "$ZASDOOR_BASE/.well-known/openid-configuration" | jq .issuer
curl -sS "$ZASDOOR_BASE/.well-known/jwks.json" | jq '.keys[0] | {kty,crv,x,kid}'
```

## 8. Passkey (WebAuthn) registration and login

Browser ceremonies produce the base64url fields below. The `begin` responses are **raw** WebAuthn option objects (not enveloped); pass them straight to `navigator.credentials.create/get`. Only ES256 / attestation `fmt=none` is accepted. See [webauthn.md](webauthn.md).

```bash
# 8a. Register a passkey (requires JWT). Browser calls navigator.credentials.create(options):
BEGIN=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/mfa/webauthn/register/begin" \
  -H "Authorization: Bearer $TOKEN")
echo "$BEGIN" | jq .challenge
# From the browser's PublicKeyCredential response (all binary fields base64url, no padding):
curl -sS -X POST "$ZASDOOR_BASE/api/v1/mfa/webauthn/register/finish" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"credential_id":"<base64url>","client_data_json":"<base64url>","attestation_object":"<base64url>","name":"My laptop"}' | jq .
curl -sS "$ZASDOOR_BASE/api/v1/mfa/webauthn/credentials" -H "Authorization: Bearer $TOKEN" | jq .

# 8b. Log in with the passkey (public, rate-limited). Browser calls navigator.credentials.get(options):
LOGIN_BEGIN=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/mfa/webauthn/login/begin" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\"}")
echo "$LOGIN_BEGIN" | jq .challenge
curl -sS -X POST "$ZASDOOR_BASE/api/v1/mfa/webauthn/login/finish" \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","credential_id":"<base64url>","client_data_json":"<base64url>","authenticator_data":"<base64url>","signature":"<base64url>"}' \
  | jq -r '.data.token'
# 401 is uniform for all authentication failures (no user/credential oracle).
```

## 9. IAM: organization → project → application → role assignment

All IAM routes require a JWT; mutations additionally require the `admin` flag. The application create response is the **only** time `client_secret` is returned — save it. See [iam.md](iam.md).

```bash
# 9a. Create organization
ORG=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/organizations" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"acme","description":"Acme Inc","domain":"acme.example.com"}')
export ORG_ID=$(echo "$ORG" | jq -r '.data.id')

# 9b. Create project inside the organization
PROJ=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/projects" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"portal\",\"org_id\":$ORG_ID}")
export PROJECT_ID=$(echo "$PROJ" | jq -r '.data.id')

# 9c. Create an OAuth application (returns client_id + client_secret ONCE)
APP=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/projects/$PROJECT_ID/applications" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"my-web-app","redirect_uris":["http://localhost:3000/callback"],"grant_types":["authorization_code","refresh_token"],"pkce_required":true}')
echo "$APP" | jq .  # record client_id / client_secret

# 9d. Create a role and assign it to a user
ROLE=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/projects/$PROJECT_ID/roles" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"key":"auditor","name":"Auditor","permissions":"["proposal.read"]"}')
export ROLE_ID=$(echo "$ROLE" | jq -r '.data.id')
curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/roles/$ROLE_ID/assign" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"user_id\":2,\"project_id\":$PROJECT_ID}" | jq .

# 9e. Inspect / revoke sessions
curl -sS "$ZASDOOR_BASE/api/v1/iam/users/2/sessions?page=1&page_size=20" \
  -H "Authorization: Bearer $TOKEN" | jq '.data.list'
```

## 10. Policy create + authorization check

Policies use explicit allow/deny with deny-overrides, then fall back to IAM roles; a no-match is UNKNOWN (deny by default). See [authz.md](authz.md).

```bash
# 10a. Admin creates a deny policy (name/subject/resource/action must be non-empty)
curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/authz/policies" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"no-delete","effect":"deny","subject":"*","resource":"proposal","action":"delete","priority":10,"enabled":true}' | jq .

# 10b. Any authenticated user checks a decision
curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/authz/check" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"subject_id\":2,\"resource\":\"proposal\",\"action\":\"delete\",\"project_id\":$PROJECT_ID}" | jq .
# => {"code":0,"data":{"allowed":false,"decision":"deny","source":"policy","policy_id":1}}
curl -sS "$ZASDOOR_BASE/api/v1/iam/authz/decisions" -H "Authorization: Bearer $TOKEN" | jq .
```

## 11. Orgstruct: group membership + domain verification

Admin only. The domain verification token is returned **once** at creation (only its hash is stored); publish it as a TXT record, then verify. See [orgstruct.md](orgstruct.md).

```bash
# 11a. Group and member
GROUP=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/groups" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"engineering\",\"org_id\":$ORG_ID,\"description\":\"Eng team\"}")
export GROUP_ID=$(echo "$GROUP" | jq -r '.data.id')
curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/groups/$GROUP_ID/members" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"user_id":2}' | jq .
curl -sS "$ZASDOOR_BASE/api/v1/iam/groups/$GROUP_ID/members" -H "Authorization: Bearer $TOKEN" | jq .

# 11b. Domain verification (token shown exactly once)
DOMAIN=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/domains" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"name\":\"acme.example.com\",\"org_id\":$ORG_ID}")
export DOMAIN_ID=$(echo "$DOMAIN" | jq -r '.data.id')
export VERIFY_TOKEN=$(echo "$DOMAIN" | jq -r '.data.verification_token')
echo "Publish TXT: acme.example.com = $VERIFY_TOKEN"
curl -sS -X POST "$ZASDOOR_BASE/api/v1/iam/domains/$DOMAIN_ID/verify" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$VERIFY_TOKEN\"}" | jq .
```

## 12. Agent create → token → verify → invoke

Agent tokens embed `sub=agent_<id>`, `actor=<owner>` and optional `budget_remaining`. Invocation enforces the capability allow-list and atomically charges the per-period budget. See [agent.md](agent.md).

```bash
# 12a. Create an agent with a capability allow-list and a daily budget
AGENT=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/agents" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"report-bot","capabilities":"["wallet.balance"]","scopes":"["profile"]","budget":100,"period_seconds":86400}')
export AGENT_ID=$(echo "$AGENT" | jq -r '.data.id')

# 12b. Issue a token (default TTL 3600s)
AGENT_TOKEN=$(curl -sS -X POST "$ZASDOOR_BASE/api/v1/agents/$AGENT_ID/token" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"ttl":3600}' | jq -r '.data.access_token')

# 12c. Verify the token
curl -sS -X POST "$ZASDOOR_BASE/api/v1/agents/token/verify" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$AGENT_TOKEN\"}" | jq .

# 12d. Invoke a capability (cost defaults to 1; returns remaining budget)
curl -sS -X POST "$ZASDOOR_BASE/api/v1/agents/$AGENT_ID/invoke" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"capability":"wallet.balance","cost":1}' | jq .
# => {"code":0,"data":{"remaining_budget":99}}
# 403 = missing capability / deactivated agent; 429 = budget exhausted
curl -sS -X POST "$ZASDOOR_BASE/api/v1/agents/$AGENT_ID/deactivate" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

## 13. Audit logs, health and metrics

Audit logs are admin-only and paginated (`page_size` up to 200; filters `actor`, `action`, `keyword`). `/health/live`, `/api/v1/health/ready` and `/metrics` are public by default; `/metrics` can be IP-restricted with `ZASDOOR_METRICS_ALLOW_IPS`. Recent authorization decisions are also queryable via `/api/v1/iam/authz/decisions` (example 10). See [eventstore.md](eventstore.md) for the append-only event layer.

```bash
# Audit trail
curl -sS "$ZASDOOR_BASE/api/v1/audit-logs?action=auth.login&page=1&page_size=20" \
  -H "Authorization: Bearer $TOKEN" | jq '.data | {total, rows: .list[0:3]}'
curl -sS "$ZASDOOR_BASE/api/v1/audit-logs/export?action=auth.login" \
  -H "Authorization: Bearer $TOKEN" -o audit-logs.csv   # CSV export (raw)

# Health
curl -sS "$ZASDOOR_BASE/health/live" | jq .             # {"code":0,"data":{"status":"UP"}}
curl -sS "$ZASDOOR_BASE/api/v1/health/ready" | jq .     # 503 if datastore unavailable
curl -sS "$ZASDOOR_BASE/api/v1/system/info" -H "Authorization: Bearer $TOKEN" | jq .

# Prometheus metrics (text/plain, root level)
curl -sS "$ZASDOOR_BASE/metrics" | head -20
```

## Quick index of covered endpoints

| # | Flow | Endpoints |
| --- | --- | --- |
| 1 | Register | `POST /api/v1/auth/register` |
| 2 | Login | `POST /api/v1/auth/login` |
| 3 | MFA step-up | `POST /mfa/login/finish`, `/mfa/totp/enroll`, `/mfa/totp/verify` |
| 4 | Auth code + PKCE | `GET /oauth/authorize`, `POST /oauth/token` |
| 5 | Client credentials | `POST /oauth/token` |
| 6 | Device flow | `POST /oauth/device_authorization`, `/oauth/device`, `/oauth/token` |
| 7 | Exchange / refresh | `POST /oauth/token`, `/oauth/introspect`, `/oauth/revoke`, `/oauth/userinfo`, discovery, JWKS |
| 8 | Passkeys | `/mfa/webauthn/register/{begin,finish}`, `/mfa/webauthn/login/{begin,finish}`, `/mfa/webauthn/credentials` |
| 9 | IAM | `/iam/organizations`, `/iam/projects`, `/iam/projects/{id}/applications`, `/iam/projects/{id}/roles`, `/iam/roles/{id}/assign`, `/iam/users/{id}/sessions` |
| 10 | Policy / authz | `/iam/authz/policies`, `/iam/authz/check`, `/iam/authz/decisions` |
| 11 | Orgstruct | `/iam/groups`, `/iam/groups/{id}/members`, `/iam/domains`, `/iam/domains/{id}/verify` |
| 12 | Agent | `/agents`, `/agents/{id}/token`, `/agents/token/verify`, `/agents/{id}/invoke`, `/agents/{id}/deactivate` |
| 13 | Ops | `/audit-logs`, `/audit-logs/export`, `/health/live`, `/health/ready`, `/metrics`, `/system/info` |

For consumer code patterns (TypeScript `fetch`, Python `requests`, Zig `std.http`, envelope handling, pagination, SDK regeneration commands) see [sdk.md](sdk.md).
