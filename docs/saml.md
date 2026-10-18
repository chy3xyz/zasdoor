# SAML 2.0 Service Provider (SP) — implementation design

| | |
| --- | --- |
| Status | Draft — ready for implementation review |
| Owner | saml-design |
| Module home | `src/modules/saml/` (new), sharing the zent client with `src/modules/mfa/` |
| Deliverable | `docs/saml.md` (this file). Code, migrations, OpenAPI and README are separate tasks |
| Zig | 0.17.0 (`build.zig.zon` `minimum_zig_version = "0.17.0"`) |
| Related docs | [oauth.md](oauth.md), [iam.md](iam.md), [mfa.md](mfa.md), [development-guide.md](development-guide.md) |
| Related code | `src/modules/mfa/idp.zig`, `idp_api.zig`, `persistence.zig`, `model.zig`, `src/modules/user/service.zig`, `src/modules/oauth/api.zig`, `src/main.zig`, `src/schema.zig`, `src/config.zig` |

This document is deliberately concrete: struct names, field names, endpoint
paths, error names and storage tables are the contract the implementation
should follow. Where a recommendation depends on verification, it says so.

---

## 0. Executive summary and decisions

zasdoor already has a federated-login foundation for OAuth2/OIDC
(`IdentityProvider` + `IdentityLink` + `FederatedState`, JIT provisioning with
the `!federated` password marker, JWT minting through
`generateTokenWithTenantAndVersion`). SAML 2.0 SP support should reuse that
foundation wholesale and add only the protocol-specific pieces: a hardened XML
parser, **exclusive XML canonicalization (the hard part)**, XML-DSig
verification, assertion validation, an assertion-replay cache, and a browser
session hand-off.

Decisions locked by this design:

| # | Decision | Rationale |
| --- | --- | --- |
| D1 | Reuse `IdentityProvider` (`provider_type = "saml"`) and store the SAML config in its existing `config` JSON column | Same lifecycle/tenant/enabled semantics as OIDC; `IdentityLink.provider_id` already points at it; the config-JSON pattern is established (`idp.zig:124`). No new provider table. |
| D2 | SP-initiated SSO only in v1: HTTP-Redirect `AuthnRequest`, HTTP-POST `Response`. IdP-initiated SSO is a small, explicit opt-in (P6); SLO is out of scope | The 80% enterprise case; SLO is a separate state machine with its own replay/validation risks. |
| D3 | No SP signing and no XML encryption in v1 | Zig 0.17 std has **no RSA private-key signing** and no XML encryption. Both are optional in SAML; every target IdP can be configured to accept unsigned AuthnRequests and unencrypted assertions. |
| D4 | Build the XML parser, exclusive c14n and DSig layer in pure Zig; validate against W3C c14n vectors and captured IdP responses before committing | No XML/c14n in `std`; a purpose-built, fail-closed subset is smaller than embedding libxml2. P0 is a hard go/no-go gate with libxml2 as fallback. |
| D5 | Session hand-off uses a **one-time login ticket**: ACS → `303` to the SPA with `?ticket=…`, SPA exchanges it at `POST /api/v1/auth/saml/exchange` for a normal JWT | ACS is a cross-site browser POST; it cannot return JSON to the SPA and a JWT in a URL is not acceptable. |
| D6 | `RelayState` is the AuthnRequest ID (128-bit random). The post-login destination is stored **server-side** in `FederatedState.redirect_to`, never trusted from the browser | Eliminates open redirect and RelayState tampering in one move. |
| D7 | Verify the signature **before** consuming single-use state; consume state with a compare-and-set update (`WHERE used = 0`), then insert the assertion ID into a replay table | Existing `markFederatedStateUsed` (`persistence.zig:304`) is check-then-update (TOCTOU). The CAS pattern is what `web3` intended with `consumeNonce` (`web3/persistence.zig:156`). |
| D8 | Verify **every** signature present (Response and/or Assertion); `want_assertions_signed` defaults to `true` | Okta/Auth0/Keycloak/Azure differ in which element they sign; accepting an unsigned assertion by default would be a downgrade. |
| D9 | Certificate trust is **exact DER pinning** against configured PEM certs (1–4, for rotation). No CA-chain, CN or expiry-based trust decisions | IdPs rotate certs; pinning is the SAML norm and is straightforward to audit. |
| D10 | One new module `src/modules/saml/`; admin CRUD remains in `mfa/idp_api.zig`, which must gain admin-role enforcement | Files must stay under the 1800-line lint gate (`build.zig` `lint-size`); protocol code is large. `idp_api` admin routes currently only require a valid JWT, not an admin role. |

**Minimum viable path (MVP):** D1 + D2 + P0/P1/P2/P3 + D5/D6/D7/D8/D9. That is
a complete SP-initiated SSO flow with JIT provisioning, replay protection and
negative tests — roughly 4 engineer-weeks, dominated by c14n.

**The single highest-risk item is exclusive XML canonicalization.** A c14n
bug normally fails closed (interop failure, not compromise), but a parser/DOM
mismatch combined with a signature-wrapping bug is a critical vulnerability.
Section 5.7 defines the fallback and the P0 go/no-go.

---

## 1. Scope and interop targets

### 1.1 In scope (v1)

- **SP-initiated SSO**, HTTP-Redirect AuthnRequest, HTTP-POST Response
  (SAML 2.0 Web Browser SSO Profile, `urn:oasis:names:tc:SAML:2.0:profiles:SSO:browser`).
- SP metadata document served per provider.
- Per-IdP configuration: entity ID, SSO URL, ACS URL, signing certificate(s),
  NameID format, attribute mapping, signature requirements, clock skew.
- Assertion validation: XML-DSig (enveloped, exclusive c14n), Issuer,
  Audience, Recipient, Destination, InResponseTo, NotBefore/NotOnOrAfter,
  bearer SubjectConfirmation, replay cache, certificate pinning.
- Identity linking / JIT provisioning against the existing user table.
- Login ticket session hand-off and JWT issuance consistent with the existing
  federated (OIDC) login.
- Content-type, method, size and rate limits on the public endpoints.

### 1.2 Optional, explicitly negotiated (v1.1 / P6)

- **IdP-initiated SSO** (Response posted with no `InResponseTo`/`RelayState`).
  Off by default (`allow_idp_initiated = false`) because it is inherently
  login-CSRF-shaped; requires the assertion replay cache and
  `Destination`/`Recipient` checks.
- `require_mfa_authn_context`: reject assertions whose
  `AuthnContextClassRef` is not an MFA class when the tenant
  `MfaPolicy.require_mfa` is set (`mfa/persistence.zig:359`).
- Optional `ForceAuthn` / requested `AuthnContext` / `ProviderName` on the
  AuthnRequest.
- Fetching IdP metadata from a URL (`metadata_url`) instead of pasting certs.

### 1.3 Out of scope (not implemented)

- **Single Logout (SLO)** — logout stays local (`/oauth/end-session`).
- **SP-signed AuthnRequests** (requires RSA signing; see `5.2`).
- **Encrypted assertions / encrypted NameID** (XMLEnc).
- **Artifact binding**, **Attribute Query**, **Assertion Query**.
- **SAML 1.1**, WS-Federation, WS-Trust.
- **IdP-initiated with unsolicited response** by default (opt-in only).
- Multiple assertions per Response (protocol allows one in the browser
  profile; we reject >1 — fail closed).
- `AuthnContext` policy enforcement in v1 (only parsed and logged).

### 1.4 Interop targets

The implementation must accept the shapes produced by these products when
configured for "one SP, HTTP-POST response". Exact tenant settings must be
recorded in the provider config; the table is a design target, not a promise
about defaults.

| IdP | Typical signature placement | Typical NameID | Quirks the parser/validator must tolerate |
| --- | --- | --- | --- |
| **Okta** | Response signed and/or Assertion signed (admin choice; commonly both or assertion only) | `emailAddress` or `persistent` | `ds` prefix normally; echoes `RelayState`; may include `InResponseTo`; exclusive c14n; cert in `KeyInfo/X509Data`. |
| **Auth0** | Assertion signed by default; optional response signing | `emailAddress` or `unspecified` | Often `Destination` on Response; attributes under `AttributeStatement`; may omit Response signature. |
| **Azure AD / Entra ID** | Assertion signed; Response usually unsigned | `persistent` (object ID) or `emailAddress` | Issuer is tenant-specific (`https://sts.windows.net/<tenant>/`); attributes use `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/*` and `http://schemas.microsoft.com/identity/claims/*`; `NotOnOrAfter` required; may include `AuthnContextClassRef`. |
| **Keycloak** | Assertion signed by default; "Sign Documents" controls the Response | `persistent` / `emailAddress` / `transient` | `transient` NameID is unstable — reject for linking (`6.6`); can include `SessionIndex`; `NameIDPolicy` enforced. |

### 1.5 Bindings

| Binding | Direction | Used |
| --- | --- | --- |
| HTTP-Redirect | SP → IdP (AuthnRequest) | yes, `SAMLRequest` = raw-DEFLATE + base64 + URL-encode |
| HTTP-POST | IdP → SP (Response) | yes, `SAMLResponse` = base64, `RelayState` optional |
| HTTP-Artifact | IdP → SP | no |
| HTTP-POST (AuthnRequest), HTTP-Redirect (Response) | — | no (metadata advertises only POST ACS) |

---

## 2. Repository baseline and endpoints

### 2.1 What already exists (verified)

- **Provider storage**: `IdentityProvider` has `tenant_id`, `name`,
  `provider_type` (`oidc|oauth|github|google` today), `config` (Text JSON),
  `enabled` (`mfa/model.zig:37`).
- **Identity links**: `IdentityLink(provider_id, user_id, subject, email)`
  (`mfa/model.zig:62`) with `findIdentityLink` (`persistence.zig:217`) and
  `createIdentityLink` (`persistence.zig:193`).
- **Single-use login state**: `FederatedState(provider_id, state, redirect_to, expires_at, used)` (`mfa/model.zig:110`), created/consumed by
  `createFederatedState` / `findFederatedState` / `markFederatedStateUsed`
  (`persistence.zig:262-312`), with expired-row purge
  (`persistence.zig:315`).
- **JIT provisioning**: `IdpService.resolveLocalUser` (`idp.zig:316`) uses
  `findUserIdByEmail` (tenant-scoped, `persistence.zig:328`),
  `createFederatedUser` (writes `FEDERATED_PASSWORD_MARKER = "!federated"`,
  `persistence.zig:35,340`), and `decideProvision` (`idp.zig:89`).
- **Session minting**: `user_svc.getUserById` + `users.sec.module.generateTokenWithTenantAndVersion(uid, roles, tenant, token_version)`
  (`idp_api.zig:186`; canonical path `user/service.zig:424`).
- **Route patterns**: root-level public protocol routes are registered
  directly on the server with paths **without** a leading slash
  (`oauth/api.zig:28-56`, called from `main.zig:448`); `/api/v1` uses
  `server.group("/api/v1")` (`main.zig:428`). Path params use
  `ctx.paramInt(i64, "id")` (`idp_api.zig:100`). Redirects are
  `ctx.setHeader("Location", url)` + `ctx.text(302, "")` (`oauth/api.zig:239`).
- **HTTP helpers**: `ctx.formValue` (`zigmodu Server.zig:592`),
  `ctx.formValues` (`:1160`, needed to reject duplicate fields),
  `ctx.bindForm` (`:1204`), body cap `Server.Config.max_body_size`
  (`:2496`, set to `upload_max_bytes + 64 KiB` in `main.zig:407`).
- **Config**: `Config.fromEnv` / `Config.isProdLike` (`config.zig`),
  production preflight in `main.zig:132`. `app_host` is the SPA base URL
  (`config.zig:25`).
- **Tests**: module test files wired via `_ = @import("modules/<mod>/tests.zig")`
  (`src/tests.zig:2142`), HTTP dispatch through
  `zigmodu.http.Testkit.dispatch/dispatchOpts` (`src/tests.zig:416,943`),
  in-memory zent store helpers (`mfa/tests.zig:16`).

### 2.2 Gaps in the current code that SAML must fix

1. `getIdpConfig` (`persistence.zig:185`) returns only the JSON — the SAML
   path needs `tenant_id`, `enabled` and `provider_type`. Add
   `getIdpRow(provider_id) !?IdentityProviderRow`.
2. `createIdp` forces `enabled = true` (`persistence.zig:156`) and there is no
   update/delete API, so a certificate cannot be rotated. Add
   `PUT/DELETE /api/v1/mfa/idps/{id}`.
3. `startLogin` never checks `enabled` (`idp.zig:229`) and `idp_api`
   admin routes only require a valid JWT (`idp_api.zig:28`), not an admin
   role. Copy the `requireAdmin` pattern from `iam/api.zig:60`.
4. `markFederatedStateUsed` is unconditional (`persistence.zig:304`); use a
   `WHERE id = ? AND used = 0` update and treat `error.NotFound` from
   `UpdateBuilder.SaveOne` (`zent codegen/update_delete.zig:263,663`) as
   `ReusedState`.
5. OIDC `resolveLocalUser` passes the provider email to
   `findUserIdByEmail`/`createFederatedUser` without lowercasing
   (`idp.zig:321-338`), while `user/service.zig:312` normalizes email with
   `std.ascii.allocLowerString`. The SAML path must trim + lowercase before
   lookup/create.

### 2.3 Endpoints

All paths are at the **server root** (not `/api/v1`) because a browser
navigates to them; the exchange endpoint is under `/api/v1` so the SPA's fetch
wrapper can use it. `{idp}` is the numeric `IdentityProvider.id`.

| Method | Path | Auth | Content type | Behavior |
| --- | --- | --- | --- | --- |
| `GET` | `/saml/{idp}/metadata` | public | `application/samlmetadata+xml; charset=utf-8` | 200 SP metadata for this provider. `Cache-Control: public, max-age=300`. |
| `GET` | `/saml/{idp}/login` | public, per-IP rate-limited | `text/html` (empty 302 body) | Validates `redirect_to`, creates a `FederatedState` row (state = request ID, TTL 600 s), responds `302` to `sso_url?SAMLRequest=…&RelayState=…`. `Cache-Control: no-store`. |
| `POST` | `/saml/{idp}/acs` | public, per-IP rate-limited | request `application/x-www-form-urlencoded`; response `text/html` | Assertion Consumer Service. On success `303` to `{app_host}/saml/complete?ticket=…`. On failure a minimal HTML error page (400/404/500) + request id. `Cache-Control: no-store`. |
| `GET` | `/saml/{idp}/acs` | — | `text/html` | `405` (some IdPs are misconfigured to GET; surface it clearly). |
| `GET/POST` | `/saml/{idp}/slo` | — | `text/html` | Reserved; `501` in v1. Metadata does **not** advertise SLO. |
| `POST` | `/api/v1/auth/saml/exchange` | public, per-IP rate-limited | JSON `{ "ticket": "..." }` | Consumes the one-time ticket (single use, 60 s), returns the same envelope shape as the OIDC callback: `{code,msg,data:{token,user,redirect_to}}`. |
| `GET/POST/PUT/DELETE` | `/api/v1/mfa/idps[/{id}]` | admin JWT (`requireAdmin`) | JSON | Existing list/create; add update/delete. `provider_type = "saml"` triggers strict `SamlConfig` validation. |

Notes:

- `{idp}` is numeric on purpose: it is the stable primary key and avoids a
  slug column/migration. The SP entity ID (metadata `entityID`) is the
  configured `sp_entity_id`, not the URL path.
- `Content-Type` on ACS is enforced exactly
  (`application/x-www-form-urlencoded`, optional `; charset=utf-8`).
  Anything else → 415 (logged as `WrongContentType`).
- ACS body limits: reject `Content-Length > 1 MiB` before reading, and after
  base64 decode reject XML `> max_assertion_bytes` (default 256 KiB).
  `Server.Config.max_body_size` is 10 MiB globally (`main.zig:407`), which is
  far too large for this endpoint; the handler enforces the tighter limit.
- Never render validation details in the browser response. The body is a
  static page: `<title>SAML 登录失败</title><p>登录失败,请重新发起登录。</p>`
  with `X-Request-Id` echoed for support. Reason codes go to logs/metrics
  only (`10`).
- Route registration in `main.zig` (after `oauth_api`):

```zig
var saml_api = saml.api.SamlApi(@TypeOf(saml_svc), @TypeOf(user_svc))
    .init(&saml_svc, &user_svc, &saml_registry, cfg.app_host, cfg.isProdLike());
try saml_api.registerRoutes(&server, &v1); // root routes + /api/v1/auth/saml/exchange
```

`registerRoutes(self, root: *http.Server, v1: *http.RouteGroup)` registers the
root endpoints with `root.addRoute(.{ .path = "saml/{idp}/acs", … })` (same
style as `oauth/api.zig:32`) and the exchange route on `v1`.

### 2.4 Responses and status codes

| Situation | Status | Body |
| --- | --- | --- |
| Login redirect | 302 | empty; `Location` |
| ACS success | 303 | empty; `Location: {app_host}/saml/complete?ticket=<hex>` |
| Bad/missing form fields, bad base64, malformed or hostile XML, signature/assertion validation failure | 400 | static HTML page |
| Unknown/disabled provider or bad `provider_type` | 404 | static HTML page (do not distinguish disabled vs unknown) |
| Wrong method / wrong content type | 405 / 415 | static HTML page |
| Body too large | 413 | static HTML page |
| Exchange: valid ticket | 200 | `{code:0,msg:"登录成功",data:{token,user,redirect_to}}` |
| Exchange: invalid/expired/used ticket | 400 | `{code:400,msg:"登录凭证无效或已过期",data:null}` |
| Internal (DB/OOM) | 500 | static HTML / JSON envelope |

The ACS always answers `Cache-Control: no-store`, `Pragma: no-cache`,
`Referrer-Policy: no-referrer` (the global security-header middleware already
sets the last one; the handler sets the cache headers).

### 2.5 Session hand-off (login ticket)

The ACS is reached by a cross-site browser POST, so it cannot hand JSON back
to the SPA, and appending a JWT to a URL would leak it into history/proxies.
The flow is:

1. ACS validates the Response — no user/session state is written before the
   signature and assertion checks pass.
2. ACS creates a `SamlLoginTicket` row: 32 random bytes hex (`/dev/urandom`
   via the same helper pattern as `idp.zig:450`), `user_id`, `provider_id`,
   `tenant_id`, `redirect_to` (copied from the consumed `FederatedState`, or
   the provider's default), `expires_at = now + 60`, `used = false`.
3. `303 Location: {app_host}/saml/complete?ticket=<hex>`.
4. The SPA route calls `POST /api/v1/auth/saml/exchange`; the server CAS-
   consumes the ticket, loads the user (`getUserById`), checks tenant and
   `token_version`, mints the JWT exactly like the OIDC callback
   (`idp_api.zig:181-199`), and returns `{token, user, redirect_to}`.
5. The SPA navigates to `redirect_to` (already validated server-side at login
   time: relative path starting with `/` and not `//`, or an absolute URL on
   a configured allowlist; max 1024 bytes; ASCII control characters
   rejected).

A ticket is bound to one user/provider and expires after 60 s; after use the
row is left in place (`used = true`) for audit and purged by the cleanup job.
This is the **only** new browser-facing API outside the root endpoints, and it
matches the existing SPA token-storage model (Bearer token, no cookies).

### 2.6 Module layout

```
src/modules/saml/
  model.zig        # zent schemas: SamlAssertionReplay, SamlLoginTicket
  persistence.zig  # SamlStore (replay, tickets) + provider-row/CAS helpers
  config.zig       # SamlConfig: strict parse + validation (pure)
  xml.zig          # hardened namespace-aware XML parser (tree with offsets)
  c14n.zig         # exclusive XML canonicalization 1.0
  dsig.zig         # Signature location, digest + RSA verification
  assertion.zig    # typed Response/Assertion extraction + time parsing
  pem.zig          # PEM -> DER (certs), fingerprint
  service.zig      # startLogin, finishAcs, exchangeTicket, metadata
  api.zig          # SamlApi (root routes + exchange route)
  tests.zig        # wired into src/tests.zig
  testdata/        # signed fixtures, test certs, c14n golden vectors
```

Admin CRUD stays in `mfa/idp_api.zig` (same table); protocol code stays in
`saml/`. Each file must remain below the repo's 1800-line gate
(`build.zig` `lint-size`), which is why parser/c14n/dsig are separate.
Register the new schemas in `src/schema.zig`'s `graph` and in
`main.zig`'s `StoreEnv(...)` info list (`main.zig:168-187`).

---

## 3. Configuration model

### 3.1 Decision: reuse `IdentityProvider.config`

Store SAML settings as typed JSON in the existing `config` Text column with
`provider_type = "saml"`. This keeps one provider lifecycle, one tenant
column, one `enabled` flag and one `IdentityLink.provider_id` namespace.
`docs/iam.md` `3/`4 already establishes JSON config for providers, and
`idp.zig:124` shows the parse/validate pattern to mirror.

Rejected alternatives:

- **New `SamlProvider` table**: duplicates tenant/enabled/link lifecycle, adds
  a second way to configure federated login, and needs its own admin API.
- **New columns on `IdentityProvider`**: protocol-specific columns for a
  single table used by OIDC too; config JSON is strictly typed at the parser
  boundary anyway.
- **Flat env vars** (`ZASDOOR_SAML_*`): providers are per-tenant rows edited
  at runtime; env vars cannot express certificate rotation.

Trade-off: JSON is not queryable/typed at the DB layer. Mitigation: strict,
versioned parser that rejects unknown keys, is run on every write **and** on
every read, and fail-closes the provider on invalid config.

### 3.2 Config struct (authoritative)

```zig
// src/modules/saml/config.zig
pub const NameIdFormat = enum {
    email_address,  // urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress
    persistent,     // urn:oasis:names:tc:SAML:2.0:nameid-format:persistent
    unspecified,    // urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified
    any,            // accept the IdP's format verbatim (transient rejected)
};

pub const AttributeMapping = struct {
    /// Candidate `Attribute@Name` values, first match wins. Exact match.
    email: []const []const u8 = &.{ "mail", "email",
        "urn:oid:1.2.840.113549.1.9.1",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" },
    name: []const []const u8 = &.{ "displayName", "name", "cn",
        "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name" },
    /// Optional attribute that asserts email verification ("true"/"1"/"yes").
    email_verified: ?[]const u8 = null,
    /// Reserved for role mapping (v2); stored but unused in v1.
    groups: ?[]const u8 = null,
};

pub const SamlConfig = struct {
    version: u8 = 1,
    entity_id: []const u8,          // IdP Issuer, exact match
    sso_url: []const u8,            // IdP SingleSignOnService (Redirect binding)
    acs_url: []const u8,            // our /saml/{idp}/acs, absolute
    sp_entity_id: []const u8,       // our metadata entityID / expected Audience
    signing_certs_pem: []const []const u8, // 1..4 PEM CERTIFICATE blocks
    want_assertions_signed: bool = true,
    allow_idp_initiated: bool = false,
    trust_email_as_verified: bool = false, // auto-link policy, see `6`.3
    name_id_format: NameIdFormat = .email_address,
    clock_skew_seconds: i64 = 120,          // clamped to 0..300
    relay_state_ttl_seconds: i64 = 600,     // login state TTL
    max_assertion_bytes: usize = 256 * 1024,
    max_assertion_lifetime_seconds: i64 = 12 * 3600,
    allow_sha1_signatures: bool = false,
    post_login_redirect: []const u8 = "",   // default "/" after success
    attribute_mapping: AttributeMapping = .{},
};
```

Example stored `config` value (the admin UI pastes this; the server also
stores `signing_certs_pem` as an array):

```json
{
  "version": 1,
  "entity_id": "https://idp.example.com/app/zasdoor/sso/saml",
  "sso_url": "https://idp.example.com/app/zasdoor/sso/saml",
  "acs_url": "https://id.example.com/saml/7/acs",
  "sp_entity_id": "https://id.example.com/saml/7/metadata",
  "signing_certs_pem": [
    "-----BEGIN CERTIFICATE-----\nMIID...\n-----END CERTIFICATE-----"
  ],
  "want_assertions_signed": true,
  "allow_idp_initiated": false,
  "trust_email_as_verified": false,
  "name_id_format": "emailAddress",
  "clock_skew_seconds": 120,
  "max_assertion_bytes": 262144,
  "attribute_mapping": {
    "email": ["mail", "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"],
    "name": ["displayName", "cn"],
    "email_verified": "emailVerified"
  }
}
```

### 3.3 Validation rules (strict, fail closed)

Reject at admin write time (`400` with field names) and treat as
`error.InvalidConfig` at ACS/login time (500 + operator log / metric):

| Field | Rule |
| --- | --- |
| `version` | `1`; unknown → reject. |
| `entity_id` | non-empty, ≤ 1024, absolute URI with `https` (or `http` only in non-prod/localhost). Exact comparison at login — no normalization. |
| `sso_url` / `acs_url` / `sp_entity_id` | absolute `https` URLs (same dev exception); `acs_url` must end with `/saml/{idp}/acs` for this provider to catch copy-paste errors (warning, not hard reject). |
| `signing_certs_pem` | 1–4 entries; each exactly one PEM `CERTIFICATE` block; DER ≤ 8 KiB; parses via `std.crypto.Certificate.parse`; RSA key; modulus 2048–4096 bits; duplicate DER rejected. Expired/not-yet-valid cert → reject with a message (rotation must overlap before expiry); `< 30 days` remaining → admin warning. Admin response includes SHA-256 fingerprint. |
| `want_assertions_signed` | bool; default true. |
| `allow_idp_initiated` | bool; default false; requires `want_assertions_signed`. |
| `trust_email_as_verified` | bool; default false (see `6`.3). |
| `name_id_format` | enum above; `transient` is not representable; `any` accepts anything except transient. |
| `clock_skew_seconds` | 0–300, default 120. |
| `relay_state_ttl_seconds` | 60–1800, default 600. |
| `max_assertion_bytes` | 16 KiB–1 MiB, default 256 KiB; must be ≤ server `max_body_size` (10 MiB). |
| `max_assertion_lifetime_seconds` | 60 s–24 h, default 12 h. |
| `allow_sha1_signatures` | bool, default false; enabling logs a warning. |
| `attribute_mapping.*` | ≤ 8 candidate names per field, each ≤ 256 bytes, non-empty, no control characters; `email_verified`/`groups` optional. |
| Unknown JSON keys | rejected (`std.json.ParseOptions{ .ignore_unknown_fields = false }`). |

Config is parsed **per request** in v1 (provider rows are few and small); add
a bounded in-memory cache later if profiling shows it matters.

### 3.4 Admin API changes

- `POST /api/v1/mfa/idps`: validate `provider_type ∈ {oidc,oauth,github,google,saml}`;
  when `"saml"`, run `SamlConfig.parse` and return `400` on invalid input.
  Respect the submitted `enabled` too (today `createIdp` forces true).
- `PUT /api/v1/mfa/idps/{id}` (new): `{name?, config?, enabled?}`. Re-validate
  on every write. Certificate rotation = replace `signing_certs_pem` with the
  new cert first (both old and new accepted) then the old one.
- `DELETE /api/v1/mfa/idps/{id}` (new): `409` when `IdentityLink` rows exist
  (force explicit cleanup), otherwise delete the provider and its transient
  rows (states/tickets/replay) in one transaction.
- All admin routes must use `requireAdmin` (copy from `iam/api.zig:60`), and
  write an audit event if `AuditService` is available.

---

## 4. Validation algorithm

### 4.1 Ordering

The order is security-relevant: nothing derived from the assertion may be
trusted (user lookup, tenant, redirect) until the signature over the element
it came from has verified, and single-use state must only be consumed after
signature verification.

```
POST /saml/{idp}/acs
 1  provider = getIdpRow(idp)                    -> 404 / Disabled / InvalidConfig
 2  transport checks (method, content-type, size, exactly one SAMLResponse)
 3  base64 decode -> xml_bytes                   -> MalformedBase64 / AssertionTooLarge
 4  xml.parse(xml_bytes, limits)                 -> MalformedXml / XmlLimitExceeded / ForbiddenXmlConstruct
 5  root Response + Status + single Assertion   -> WrongNamespace / StatusNotSuccess / MultipleAssertions
 6  for signed element in [Response if signed, Assertion if signed]:
       xml-dsig structure checks                -> missing/extra signature, bad algorithms, bad transforms
       digest check (c14n of element minus Signature)
       RSA verify (pinned cert)
 7  if want_assertions_signed and Assertion unsigned -> MissingSignature; if neither signed -> MissingSignature
 8  extract typed Response/Assertion fields from the SAME nodes that passed step 6
 9  Response-level: Issuer, Destination, IssueInstant
10  Assertion-level: Issuer, Conditions/Audience, SubjectConfirmation/Recipient,
       NotBefore/NotOnOrAfter, NameID format, AuthnContext (log)
11  state correlation: RelayState + InResponseTo  -> MissingRelayState / UnknownState /
       ExpiredState / InResponseToMismatch
12  CAS-consume FederatedState                    -> ReusedState   (SP-initiated only)
13  replay cache insert assertion ID              -> ReplayedAssertion
14  resolve local user (link/email/provision)     -> EmailConflict / MissingEmail / TenantMismatch
15  mint ticket, 303
```

Signature verification (step 6) happens before state consumption (step 12) so
unauthenticated garbage cannot burn a legitimate login state. `RelayState` is
unguessable (128-bit), and the state CAS plus assertion replay cache cover
duplicate delivery after step 12.

### 4.2 Step details

**Step 2 — transport**

- Method must be `POST` (else 405). Content-Type must be
  `application/x-www-form-urlencoded` (else 415).
- `SAMLResponse` must appear exactly once (`ctx.formValues("SAMLResponse").len == 1`)
  and be non-empty; `SAMLEncoding=deflate` is invalid for POST binding → reject.
- `RelayState` optional; if present ≤ 2048 bytes and may only contain
  printable ASCII at login time (we generate it ourselves as the request ID;
  anything else from the browser means tampering → `InvalidRelayState`).
- XML byte size after base64 decode ≤ `max_assertion_bytes`.

**Step 3 — base64 decode**

`std.base64.standard.Decoder.calcSizeForSlice` / `.decode` (pattern already
used in `idp.zig:409`), with ASCII whitespace stripped first. Reject invalid
characters, wrong padding, decoded length mismatch.

**Step 4 — XML parse**

Only UTF-8 (SAML requires UTF-8 for the Web SSO profile). Reject a UTF-16 BOM,
`DOCTYPE`, `ENTITY`, external references, XInclude, and processing
instructions other than the leading XML declaration. Limits: depth ≤ 32,
elements ≤ 4096, attributes/element ≤ 64, namespace decls/element ≤ 128,
text total ≤ 1 MiB. Collect element offsets and the value of every `ID`, `Id`
and `id` attribute; duplicates are fatal (`DuplicateId`). Namespaces are
matched by URI, never by prefix. Details in `5.3`.

**Step 5 — structure**

- Root must be `{urn:oasis:names:tc:SAML:2.0:protocol}Response`.
- `Status/StatusCode@Value` exactly `urn:oasis:names:tc:SAML:2.0:status:Success`;
  any `StatusCode` child (nested status) → reject. No `StatusMessage` is
  trusted (never rendered).
- Exactly one direct `Assertion` child; no `EncryptedAssertion`;
  `Extensions` may be present but is ignored (and must not contain a
  `Signature` — see step 6).
- Reject a second `Response`/`Assertion` at root level.

### 4.3 Step 6 — XML-DSig (each present signature)

For an element `E ∈ {Response, Assertion}` with a direct-child `Signature`:

1. Exactly one direct-child `{http://www.w3.org/2000/09/xmldsig#}Signature`.
   A `Signature` under `Extensions`/`Object` is not a valid signature location
   → `UnexpectedSignature`.
2. `SignedInfo` exactly one; `CanonicalizationMethod@Algorithm` must be
   `http://www.w3.org/2001/10/xml-exc-c14n#` (optionally with
   `InclusiveNamespaces@PrefixList`); `...WithComments` is rejected.
   `SignatureMethod@Algorithm` must be
   `http://www.w3.org/2001/04/xmldsig-more#rsa-sha256` (allow rsa-sha384/512
   via an allowlist; `rsa-sha1` only with `allow_sha1_signatures`; reject
   HMAC/DSA/ECDSA for v1).
3. Exactly one `Reference`; `URI` must be `"#" + E.id` and `E` must have an
   `ID` attribute (SAML's `ID`, not `Id`); any other URI → `ReferenceMismatch`.
   `Transforms` must contain at most the enveloped-signature transform
   (`http://www.w3.org/2000/09/xmldsig#enveloped-signature`) followed by an
   exclusive-c14n transform; XPath/XSLT/other transforms → reject.
4. `DigestMethod@Algorithm` must be `http://www.w3.org/2001/04/xmlenc#sha256`
   (allow sha384/sha512; sha1 only with the flag).
5. Canonicalize `SignedInfo` (exclusive c14n, using the in-scope namespaces at
   `SignedInfo` and the `InclusiveNamespaces@PrefixList`, if any) and verify
   the signature over those bytes with the pinned RSA key.
6. Canonicalize `E` with the enveloped `Signature` removed and compare
   SHA-256(canonical) with the decoded `DigestValue`.
   Compute the digest **before** trusting anything parsed from `E`.
7. `KeyInfo` handling: if `X509Data/X509Certificate` is present, exactly one,
   base64-decoded DER must be byte-equal to one of the configured pinned certs
   (`CertificateMismatch` otherwise). If absent, try every pinned cert.
   No chain building, no CA trust, no CN/SAN matching. Reject more than one
   `X509Certificate` or `KeyValue` alternatives.
8. Only after 1–7 pass is `E` marked "verified"; the typed extraction in
   step 8 reads from this same parsed node (no re-parse, no re-serialize).

Requirement summary: if the Assertion has no Signature and
want_assertions_signed is true, reject (MissingSignature). If the
Response has no Signature and the Assertion is unsigned, reject
(MissingSignature). If both are signed, verify both; a valid outer
signature never excuses a broken inner one.

### 4.4 Steps 8–15 — claims, state, replay, user, ticket

**Steps 8–10 — typed extraction and claims**

- `Response@ID` present; `Response/Issuer` text == `config.entity_id`
  (exact, byte-for-byte after XML text decoding; no trimming).
- `Assertion/Issuer` == `Response/Issuer` == `config.entity_id`.
- `Response@Destination` if present must == `config.acs_url` exactly.
  `Response@IssueInstant` ≤ now + skew; if older than
  `max_assertion_lifetime_seconds + skew` → reject.
- `Conditions`: if present, `@NotBefore` (optional) and `@NotOnOrAfter`
  (optional in schema, but required by policy) are checked with
  `skew = clamp(config.clock_skew_seconds, 0, 300)`:
  `now + skew < NotBefore` → `AssertionNotYetValid`;
  `now - skew >= NotOnOrAfter` → `AssertionExpired`.
- `Conditions/AudienceRestriction/Audience` must contain exactly
  `config.sp_entity_id` (at least one restriction, each must match; multiple
  restrictions are ANDed per spec — reject unless all match).
- Exactly one `Subject/SubjectConfirmation[@Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"]`
  (more than one bearer is allowed by spec but is a wrapping smell; reject).
- `SubjectConfirmationData@Recipient` == `config.acs_url`;
  `@NotOnOrAfter` **required** for bearer → `MissingExpiry` if absent; must be
  `> now - skew`; `@InResponseTo` must equal the request ID for SP-initiated
  flows (checked with the state in step 11).
- NameID: non-empty, ≤ 255 bytes (portable with `IdentityLink.subject`),
  no control characters. Format check per `name_id_format` (`3.2`); transient
  always rejected. Missing NameID → `MissingNameId`.
- `AttributeStatement` attributes are collected as
  `{ name, name_format, values }`; mapping in `6.1`.
- `AuthnStatement/AuthnContext/AuthnContextClassRef` is parsed and logged
  (not enforced in v1; see `1.2`).

**Step 11 — state correlation (SP-initiated)**

`RelayState` is required unless `allow_idp_initiated` is true.
`findFederatedState(RelayState)` must return a row where
`provider_id == {idp}`, `used == false`, `now < expires_at`. Then:

- `InResponseTo` (from the bearer SubjectConfirmationData and/or
  `Response@InResponseTo`) must equal `row.state` (the AuthnRequest ID we
  generated). If only one is present, that one must match; if both are
  present, both must match; absent → `InResponseToMismatch`.
- If `allow_idp_initiated` and no RelayState: skip state, require
  `Destination`/`Recipient`, and rely on the replay cache (documented risk).

**Step 12 — single-use state (CAS)**

```zig
// persistence.zig — returns false when already used (or vanished)
pub fn consumeFederatedState(self: *MfaStore, id: i64, now: i64) !bool {
    const preds = self.client.federated_state.predicates;
    var u = self.client.federated_state.Update();
    defer u.deinit();
    _ = try u.setFieldValue("used", true);
    _ = try u.setFieldValue("updated_at", now);
    _ = try u.Where(.{ preds.idEQ(.{ .int = id }), preds.usedEQ(.{ .bool = false }) });
    u.SaveOne() catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    return true;
}
```

`SaveOne` (`zent codegen/update_delete.zig:263-663`) maps zero rows to
`error.NotFound` and refuses a driver that cannot report counts, which is
exactly the semantics needed. This fixes the existing check-then-update in
`markFederatedStateUsed`.

**Step 13 — replay cache**

`INSERT INTO saml_assertion_replay (provider_id, assertion_id, expires_at, …)`;
a `UniqueViolation` means the assertion was already accepted →
`ReplayedAssertion`. `expires_at = max(SCD.NotOnOrAfter, Conditions.NotOnOrAfter, now) + skew` (so the row outlives the assertion). Key on the **assertion ID**
(not `InResponseTo`) so IdP-initiated responses and re-signed responses are
covered. `crud.create` surfaces `error.UniqueViolation` (`zent crud_helpers.zig:928`).

**Step 14 — user resolution** — see `6`.

**Step 15 — ticket** — see `2.5`.

### 4.5 Fail-closed checklist

Any of these must abort with no session and no state mutation beyond the
ticket (and, for step 12+, the deliberate consumption):

- missing/multiple `SAMLResponse`; wrong content type/method; oversized body;
- non-UTF-8, DOCTYPE/entity/PI/XInclude, duplicate IDs, depth/count/size limit;
- wrong root namespace; non-Success status; >1 Assertion; EncryptedAssertion;
- missing signature (when required); signature not a direct child; multiple
  signatures; unsupported c14n/signature/digest/transform algorithms;
- `Reference URI` not bound to the signed element's `ID`;
- digest mismatch; signature mismatch; cert not pinned; cert parse failure;
- key not RSA / modulus outside 2048–4096 bits;
- Issuer mismatch; Audience mismatch; Recipient/Destination mismatch;
- `NotBefore`/`NotOnOrAfter` violated or missing where required;
- subject confirmation not bearer; NameID missing/transient/oversized;
- missing `RelayState` (when IdP-initiated off); unknown/expired/replayed
  state; `InResponseTo` mismatch; replayed assertion ID;
- unknown user/tenant mismatch/email conflict; disabled provider;
- any parse/IO/DB error not explicitly mapped as recoverable.

Errors are mapped to a small public set (`MalformedRequest` 400,
`ProviderNotFound` 404, `UnsupportedBinding` 415, `TooLarge` 413,
`AuthFailed` 400, `Internal` 500). The internal `SamlError` name is logged and
counted, never returned.

### 4.6 Error taxonomy (internal)

```zig
pub const SamlError = error{
    // provider / transport
    ProviderNotFound, ProviderDisabled, InvalidProviderType, InvalidConfig,
    WrongMethod, WrongContentType, TooLarge, MalformedRequest,
    MissingSamlResponse, DuplicateSamlResponse, InvalidRelayState,
    MalformedBase64, MalformedXml, XmlLimitExceeded, ForbiddenXmlConstruct,
    RelativeNamespaceUri, DuplicateId,
    // structure
    WrongNamespace, StatusNotSuccess, MissingAssertion, MultipleAssertions,
    EncryptedAssertionUnsupported, MissingSignature, UnexpectedSignature,
    // signature
    UnsupportedCanonicalization, UnsupportedSignatureAlgorithm,
    UnsupportedDigestAlgorithm, UnsupportedTransform, ReferenceMismatch,
    DigestMismatch, SignatureInvalid, CertificateMismatch,
    CertificateParseFailed, UnsupportedKeyType, UnsupportedKeySize,
    // claims
    IssuerMismatch, AudienceMismatch, RecipientMismatch, DestinationMismatch,
    AssertionExpired, AssertionNotYetValid, MissingExpiry,
    MissingNameId, NameIdFormatMismatch, TransientNameId, InvalidNameId,
    // replay / state
    MissingRelayState, UnknownState, ExpiredState, ReusedState,
    InResponseToMismatch, ReplayedAssertion,
    // identity
    MissingEmail, EmailConflict, UserNotFound, TenantMismatch,
    // hand-off
    TicketInvalid, TicketExpired, TicketReused,
    // operational
    Unexpected, OutOfMemory,
};
```

---

## 5. XML and crypto plan: what Zig 0.17 std provides, what must be built

The std library was inspected at
`/Users/n0x/.local/share/zigup/0.17.0/files/lib/std` (`zig version` → 0.17.0).
Findings below are verified against that tree, not assumed.

### 5.1 Coverage table

| Need | Zig 0.17 std | Verdict |
| --- | --- | --- |
| XML parsing | **none** — no `std.xml`; no XML parser file in `lib/std` (grep for `xml` finds only incidental mentions in `Uri.zig` and a macOS sysctl file) | **custom** (`xml.zig`) |
| Exclusive XML canonicalization | **none** | **custom** (`c14n.zig`) — the hard part |
| XML-DSig structure/validation | none | **custom** (`dsig.zig`) |
| SHA-256 / 384 / 512 | `std.crypto.hash.sha2.Sha256` etc. | std |
| RSA PKCS#1 v1.5 **verification** | **yes** — `std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify` (RFC 3447 `8.2`); also `PSSSignature`; `PublicKey.parseDer` / `fromBytes`; modulus ≤ 4096 bits, exponent < 2^32, min 512 bits | std (internal API), thin wrapper |
| X.509 parsing (cert → SPKI) | `std.crypto.Certificate.parse(.{ .buffer = der, .index = 0 })` → `Parsed.pubKey()` returns the DER `RSAPublicKey` (bit-string content), exactly what `rsa.PublicKey.parseDer` expects; `Parsed.validity` available | std (internal API) |
| ASN.1 DER | `std.crypto.codecs.asn1` (`der.Element.parse`, `Oid`, `Index`) | std (internal API); fallback = ~80-line DER walker |
| RSA **signing** (private key) | **none** (no private-key ops anywhere in `std.crypto`) | not in v1 (D3) |
| XML encryption | none | out of scope |
| PEM → DER for certs | no public helper; `Certificate.Bundle` scans PEM internally (`Bundle.zig:271`) | **custom**, ~40 LOC (`pem.zig`) |
| base64 | `std.base64.standard.Decoder.calcSizeForSlice/decode` | std |
| raw DEFLATE (AuthnRequest) | `std.compress.flate.Compress.init(writer, window, .raw, .default)` + `finish()`; `Container.raw` = RFC 1951, no zlib header | std |
| ISO-8601 / SAML DateTime | **none** (`std.time` has no ISO parser) | **custom**, ~60 LOC |
| JSON config | `std.json` | std |
| Constant-time compare | `std.crypto.timing_safe.eql` | available; not required for cert pinning (public data), use for any future secret comparisons |
| HTTP server/redirect/form | zigmodu (not std) — `ctx.formValue(s)`, `setHeader`, `text(302, "")` | reuse |
| JWT/session | zigmodu `AppSecurity` / `generateTokenWithTenantAndVersion` | reuse |

The RSA "custom code" assumption is worth correcting: **verification does not
need a hand-written big-integer implementation** — Zig 0.17 ships the RSA
verify primitives inside `std.crypto.Certificate.rsa`, and its own
`verifyRsa` (`Certificate.zig:834-858`) is the template:

```zig
// dsig.zig — mirror of std.crypto.Certificate.verifyRsa (Certificate.zig:834)
fn verifyPkcs1(comptime Hash: type, sig: []const u8, msg: []const u8,
               modulus: []const u8, exponent: []const u8) !void
{
    const key = try std.crypto.Certificate.rsa.PublicKey.fromBytes(exponent, modulus);
    switch (modulus.len) {
        inline 128, 256, 384, 512 => |n| { // 1024/2048/3072/4096-bit
            if (sig.len != n) return error.SignatureLengthMismatch;
            try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(
                n, sig[0..n], msg, key, Hash);
        },
        else => return error.UnsupportedKeySize,
    }
}
```

Caveats to record: `std.crypto.Certificate` and `std.crypto.codecs.asn1` are
internal (`Certificate.zig:923` declares the type privately), not a documented
stable API. Pin Zig to 0.17.0 (already the project's minimum), wrap all uses
in `pem.zig`/`dsig.zig`, and keep a test that fails loudly on upgrade.

### 5.2 What must be custom, and how big

| Component | Est. LOC | Risk |
| --- | --- | --- |
| Hardened namespace-aware XML parser | 600–900 | medium (DoS, edge cases) |
| Exclusive c14n 1.0 (+ InclusiveNamespaces) | 500–700 | **high** (interop) |
| XML-DSig locate/verify | 300–450 | high (wrapping) |
| Assertion/claims extraction + ISO-8601 | 300–450 | low |
| PEM/DER cert + fingerprint | 80–120 | low |
| Config parse/validate | 250–350 | low |
| Service/API/persistence | 700–900 | medium |

All sizes fit the 1800-line file gate only if split as in `2.6`.

### 5.3 XML parser design (`xml.zig`)

```zig
pub const Attr = struct { ns: []const u8, local: []const u8, value: []const u8 };
pub const NsDecl = struct { prefix: []const u8, uri: []const u8 }; // "" = default ns

pub const Node = struct {
    ns: []const u8,             // resolved namespace URI
    local: []const u8,          // local name
    prefix: []const u8,         // for diagnostics/c14n bookkeeping
    attrs: []Attr,
    ns_decls: []NsDecl,         // declarations on this element
    parent: ?*Node,
    children: []Child,          // element or text, in document order
    id: ?[]const u8,            // ID/Id/id attribute value (unique)
    raw_start: usize, raw_end: usize, // diagnostics only; NEVER used for crypto
};

pub const Limits = struct {
    max_bytes: usize = 1024 * 1024,
    max_depth: usize = 32,
    max_elements: usize = 4096,
    max_attrs_per_element: usize = 64,
    max_ns_decls_per_element: usize = 128,
    max_text_bytes: usize = 1024 * 1024,
};

pub fn parse(a: std.mem.Allocator, bytes: []const u8, limits: Limits) !*Node;
```

Rules:

- UTF-8 only; BOM allowed only as UTF-8 BOM; reject UTF-16/UTF-32 BOM and
  `encoding="..."` other than UTF-8.
- **Reject `<!DOCTYPE` outright** (case-insensitive) before tokenizing; also
  reject `<!ENTITY`, conditional sections, and external identifiers. This
  removes XXE and entity-expansion by construction; the limits are defense in
  depth, not the primary control.
- Processing instructions allowed only for the leading `<?xml ...?>`; every
  other PI is `ForbiddenXmlConstruct` (c14n would drop it, but DSig over a
  document with PIs is a wrapping smell).
- Comments are parsed and discarded (c14n excludes them); if a `Signature`
  or `Assertion` appears inside a comment the parser never sees it, so it
  cannot be confused with real markup.
- CDATA sections are converted to text (c14n behavior), with the same limits.
- Entity references: only `&amp; &lt; &gt; &quot; &apos;` and numeric
  character references; anything else is malformed (no DTD, so no custom
  entities exist).
- Namespaces: resolve every prefix; undeclared prefix is an error; `xml` and
  `xmlns` are reserved; relative namespace URIs rejected
  (`RelativeNamespaceUri`) because c14n forbids them.
- Attribute uniqueness is by `(namespace URI, local name)`; duplicates are an
  error.
- `ID`, `Id`, `id` attribute values are collected into a document-wide map;
  duplicates are `DuplicateId`. (`xml:id` is not used by SAML; accept and
  treat as ID for safety.)
- `xml:base` anywhere → `ForbiddenXmlConstruct` (SAML assertions do not need
  it; supporting it in c14n is a large extra surface).
- Text and attribute values are decoded (entity/char refs) but **not**
  whitespace-normalized beyond XML's line-ending normalization (`CRLF`/`CR`
  to `LF`); c14n then decides what to escape. This distinction is critical for
  signatures.
- The tree owns all strings in an arena; `deinit` is one call.

### 5.4 Exclusive canonicalization (`c14n.zig`)

Signature and digest are computed over canonical bytes, never over the
original byte range: attribute order, inherited namespace declarations,
character escaping, line endings and empty-element syntax all differ between
producers. `Reference URI="#id"` selects the element; the enveloped-signature
transform removes the direct-child `Signature`; then **exclusive c14n 1.0**
(`http://www.w3.org/2001/10/xml-exc-c14n#`) serializes the subset.

```zig
pub const Options = struct {
    /// InclusiveNamespaces/@PrefixList from the CanonicalizationMethod.
    inclusive_prefixes: []const []const u8 = &.{},
};

/// Canonicalize `root` (and its subtree) using the namespace context inherited
/// from its ancestors (`inherited` maps prefix -> URI, "" for default).
pub fn canonicalize(a: std.mem.Allocator, root: *const xml.Node,
                    inherited: []const xml.NsDecl, opts: Options) ![]u8;
```

Rules to implement (each is a test vector):

1. UTF-8 output, no XML declaration, no trailing newline.
2. Empty elements are written `<a></a>`, never `<a/>`.
3. Namespace declarations are emitted only when *visibly utilized*: the
   element's own prefix, prefixes of its attributes, and (for the apex of a
   subtree) prefixes declared on ancestors and used within the subset. Sort
   them by prefix with the default namespace (`xmlns`) first.
   `InclusiveNamespaces@PrefixList` forces those prefixes to be rendered even
   when not visibly utilized (e.g. `xs` used only in `xsi:type` values).
4. Attributes: namespace declarations first, then attributes sorted by
   `(namespace URI, local name)`; an unqualified attribute has namespace `""`
   and sorts before namespaced ones with the same local name.
5. Text escaping: ampersand becomes `&amp;`, less-than becomes `&lt;`,
   greater-than becomes `&gt;`, and a carriage return becomes `&#xD;`.
6. Attribute escaping: ampersand becomes `&amp;`, less-than becomes `&lt;`,
   double quote becomes `&quot;`, and tab / line feed / carriage return
   become `&#x9;` / `&#xA;` / `&#xD;` respectively.
7. `xml:lang` / `xml:space` (and any `xml:*` attribute) are rendered with the
   `xml:` prefix; the `xml` namespace is implicit and never declared.
8. Comments, PIs, CDATA markers, DOCTYPE never appear.
9. `xml:base` is rejected (`5.3`).
10. Prefixes are not rewritten; the declaration where a prefix was bound may
    move to the first element in the subset that uses it, but the URI must be
    preserved.

Danger zones that fixtures must cover: namespace declared on a grandparent
and used on an attribute; default namespace inheritance; `xsi:type="xs:string"`
with `InclusiveNamespaces PrefixList="xs"`; CRLF in text; attribute values
with tabs or newlines; adjacent text/entity boundaries; `SignedInfo` whose
`ds` prefix is declared on an ancestor (extremely common: `xmlns:ds` on
`Response`).

Verification approach: build a golden-vector test suite generated with an
independent implementation (Python `lxml`/`signxml`, dev-only) and the W3C
XML C14N 1.0 test cases whose inputs fit the SAML subset. Byte-for-byte
comparison is the acceptance criterion. This harness is P0.

### 5.5 XML-DSig verification (`dsig.zig`)

```zig
pub const SignedElement = struct {
    node: *xml.Node,          // the Response or Assertion that was verified
    signature: *const xml.Node,
};

pub fn verifyAll(a: std.mem.Allocator, doc: *xml.Node,
                 certs: []const []const u8, // pinned DER
                 cfg: *const config.SamlConfig, now: i64)
    ![]const SignedElement;
```

- Locate `Signature` as a direct child of `Response` and of the single
  `Assertion`; ignore signatures elsewhere but count them and fail if they
  appear in security-relevant places.
- Validate `SignedInfo` / `Reference` / `Transforms` / algorithm URIs per
  `4.3` step 6 before touching cryptography.
- `SignedInfo` c14n must receive the namespace context that was in scope at
  `SignedInfo` (walk `parent` and merge `ns_decls` from root; later
  declarations shadow earlier ones).
- Compute the digest first, then verify the signature; `std.crypto.Certificate.rsa`
  is used for RSA.
- Return the verified nodes so the caller extracts attributes from them, not
  from a separately re-parsed document.

### 5.6 Certificate handling and pinning (`pem.zig`)

- Strip PEM armor, remove whitespace, `base64.standard.Decoder.decode`, cap
  DER at 8 KiB. Reject `PRIVATE KEY`, `RSA PRIVATE KEY`, multiple blocks.
- Compute SHA-256 of DER; this is the admin-visible fingerprint and the
  config duplicate key.
- At ACS time, an embedded `X509Certificate` DER is compared byte-for-byte
  (exact match) against the pinned set; the matched key verifies the signature. No `Certificate.verify`, no bundle, no hostname checks.
- Parse the pinned cert with `std.crypto.Certificate.parse` once per request
  (or cache parsed pins per provider version). If parsing rejects an unusual
  extension, fall back to a minimal DER walker that extracts
  `SubjectPublicKeyInfo` only (`std.crypto.codecs.asn1`), since only the key
  matters.
- Validate at config time that the cert is RSA and the modulus is 2048–4096
  bits (`rsa.PublicKey.parseDer` result), so ACS failures are config errors
  caught early.

### 5.7 Risks and fallback

| Risk | Severity | Mitigation |
| --- | --- | --- |
| c14n byte mismatch with an IdP | high (interop) | Golden vectors + captured real responses in P0; fail closed; fix iteratively against a matrix |
| Parser/DOM confusion enables signature wrapping | critical | Single assertion, direct-child signature only, unique IDs, reference binding, `verify-then-use-same-node`, independent review of `dsig.zig` |
| Zig std internal crypto API changes | medium | Wrapper + upgrade test; pin Zig 0.17.0 |
| IdP cert uses an X.509 shape `Certificate.parse` rejects | medium | SPKI-only fallback walker |
| SHA-1-only legacy IdP | low | `allow_sha1_signatures` flag, default off, warning log |
| 4096-bit keys / unusual exponent | low | std supports ≤4096 bits; exponent < 2^32 |

**Fallback (go/no-go at end of P0):** if the pure-Zig c14n cannot reproduce
golden vectors and three captured IdP responses within the P0 budget, switch
to **libxml2** for parsing + c14n only:

- `build.zig`: `exe_mod.linkSystemLibrary("xml2", .{})` (and Dockerfile
  `apt-get install libxml2-dev`; CI `brew install libxml2` / `apt`);
- `xmlReadMemory` with `XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING`
  (do **not** set `XML_PARSE_NOENT`/`DTDLOAD`), then
  `xmlC14NDocDumpMemory(doc, node_set, XML_C14N_EXCLUSIVE_1_0, prefix_list, 0, &out)`;
- RSA verification stays in std (no libxml2 dependency for crypto);
- gate behind `-Dsaml-libxml2=true` so the default build stays pure Zig.

Rejected fallbacks: vendored third-party Zig XML libraries (immature / must
be audited for 0.17), xmlsec1 (huge C surface for a feature this narrow),
sidecar verification service (operational complexity, breaks single-binary
deployment).

### 5.8 Login request (SP → IdP) details

- Build AuthnRequest in memory (no template injection):
  `ID = "_" + 32 hex random`, `Version="2.0"`, `IssueInstant` = now RFC 3339
  UTC (custom formatter), `Destination = sso_url`,
  `AssertionConsumerServiceURL = acs_url`,
  `ProtocolBinding = urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST`,
  `Issuer = sp_entity_id`, optional `NameIDPolicy` from config
  (`AllowCreate=true` for JIT provisioning).
- Escape XML in text/attributes; the URLs are config-derived but still
  escaped.
- `SAMLRequest = base64_standard(raw_deflate(xml))`, then URL-encode with the
  existing `idp.appendFormValue` (`idp.zig:435`).
- `RelayState = request ID` (same value as `FederatedState.state`), also
  URL-encoded.
- Append to `sso_url` with `?`/`&` handling; reject `sso_url` containing a
  fragment; cap total URL at 8 KiB (log a warning above 4 KiB).
- Signing: not implemented (D3). Metadata advertises
  `AuthnRequestsSigned="false"`.

---

## 6. Identity linking, provisioning and tenancy

### 6.1 Inputs extracted from the assertion

| Logical field | Source (first match wins) | Rules |
| --- | --- | --- |
| subject (NameID) | `Subject/NameID` text | Non-empty, ≤ 255 bytes, no control chars. Stored in `IdentityLink.subject`. |
| name_id_format | `NameID@Format` | If present and config is not `any`: must equal config's format; `transient` always rejected. |
| email | `AttributeStatement` attribute names in `attribute_mapping.email`, then NameID if its format is `emailAddress` | Trim ASCII whitespace, lowercase ASCII (match `user/service.zig:312`), ≤ 320 bytes, must contain `@`. |
| name | `attribute_mapping.name` candidates, then NameID | Trim, ≤ 255 bytes, no control chars; fallback to email. |
| email_verified | `attribute_mapping.email_verified` (truthy: `true`/`1`/`yes`, case-insensitive), else `config.trust_email_as_verified` | Drives auto-link policy below. Never inferred from the IdP being "enterprise". |
| groups | `attribute_mapping.groups` (reserved) | Parsed, stored later in v2 for role mapping. |

Attribute matching is by `Attribute@Name` exact string (SAML is
case-sensitive). Values are the concatenated text of all
`AttributeValue` children; multi-valued attributes yield multiple values and
the first non-empty value is used for scalar fields. `xsi:type` is ignored.
Attribute values are never rendered back to the browser.

### 6.2 Find-or-create decision

Reuse the OIDC decision logic (`idp.zig:89`) with SAML inputs:

```
link = findIdentityLink(provider_id, NameID)
if link exists:
    user = getUserById(link.user_id) or UserNotFound
    if user.tenant_id != provider.tenant_id -> TenantMismatch (fail closed)
    -> reuse_link
else if email is present and findUserIdByEmail(email, provider.tenant_id) returns a user:
    if email_verified -> link_existing (create IdentityLink, reuse user)
    else -> EmailConflict (409 public page: sign in with password, link later)
else:
    -> create_user (email required; MissingEmail otherwise)
```

- **create_user** uses the existing `createFederatedUser`
  (`mfa/persistence.zig:340`): inserts into the shared `User` table with
  `password = FEDERATED_PASSWORD_MARKER ("!federated")`, `verified = email_verified`, `admin = false`, `tenant_id = provider.tenant_id`,
  `token_version = 0`. Then `createIdentityLink(tenant, provider_id, uid, NameID, email)`. The account is SSO-only: `verifyPassword` always fails on
  the marker (`persistence.zig:33-35`). Password reset for such accounts must
  be blocked (check the marker before issuing a reset token) — a small
  follow-up in the auth module, flagged here because it is an account-takeover
  vector otherwise.
- **link_existing** is the only auto-link path; it requires an explicit
  assertion that the email is verified. Default is **off**
  (`trust_email_as_verified = false`) because SAML has no standard
  `email_verified` and an IdP that asserts an email without verification
  could otherwise take over a local account.
- **reuse_link** always wins; a NameID change (e.g. IdP re-provisioning)
  creates a new local account rather than silently re-binding by email —
  correct fail-closed behavior; admins can link manually via an admin action
  (out of scope v1, noted in `11`).

### 6.3 Email normalization and case

SAML attribute values are untrusted strings. Normalize before any lookup or
insert: trim ASCII whitespace, lowercase ASCII, reject control characters and
length > 320. This mirrors `normalizeEmail` (`user/service.zig:312`, currently
private — either export it or replicate the two-line implementation in
`saml/service.zig`). The OIDC path does not normalize (`idp.zig:321`), which
is a latent inconsistency; do not copy it.

### 6.4 Tenant handling

- The provider row's `tenant_id` is authoritative. Never take the tenant from
  RelayState, query parameters or assertion attributes.
- User lookup (`findUserIdByEmail`) and creation are tenant-scoped
  (`persistence.zig:328`), so a SAML identity in tenant A can never bind to a
  user in tenant B.
- The `IdentityLink` row is written with the provider's tenant, and login
  re-checks `user.tenant_id == provider.tenant_id` (`6.2`).
- Admin-created providers currently land in `default_tenant_id`
  (`main.zig:228`); a future multi-tenant admin UI needs the tenant in the
  request and an admin-of-that-tenant check. v1 inherits the existing
  single-tenant-admin behavior; note it in the admin docs.

### 6.5 Session issuance

On success (`2.5 step 4`), mint the JWT exactly like the OIDC callback
(`idp_api.zig:181-199`):

```zig
const row = (try self.users.getUserById(user_id)) orelse return error.UserNotFound;
const uid_str = try std.fmt.bufPrint(&buf, "{d}", .{row.id});
const tenant_str = try std.fmt.bufPrint(&tbuf, "{d}", .{row.tenant_id});
const roles: []const []const u8 = if (row.admin) &.{"admin"} else &.{"user"};
const token = try self.users.sec.module.generateTokenWithTenantAndVersion(
    uid_str, roles, tenant_str, row.token_version);
```

Do not bypass `token_version`: it is the revocation handle used by
`tokenVersionGuard` (`middleware/auth.zig:33`). Do not issue a token before
the ticket is consumed (the exchange endpoint is the only place a JWT is
created).

### 6.6 NameID formats and stability

- `persistent` is the best linking key; store it as
  `IdentityLink.subject`.
- `emailAddress` works, but the local email and the NameID can drift. Link on
  NameID; use the mapped email only for provisioning/auto-link.
- `transient` is unusable for linking (new value each login). Reject it at
  config time and at assertion time (`NameIdFormatMismatch` /
  `TransientNameId`). Operators who need transient SSO should use
  `trust_email_as_verified = true` and accept email-based identity, which is
  explicitly not the default.
- `unspecified` is accepted only when config is `unspecified` or `any`; treat
  the observed format as opaque and store the NameID.

---

## 7. Data model changes and migrations

### 7.1 Reused tables (no schema change)

| Table | Use |
| --- | --- |
| `IdentityProvider` | Provider row; `provider_type = "saml"`; `config` holds `SamlConfig` JSON; `enabled` enforced. |
| `IdentityLink` | `(provider_id, subject=NameID) -> user_id`; `email` cached for diagnostics. |
| `FederatedState` | Login state: `state` = AuthnRequest ID = RelayState, `redirect_to` = validated post-login target, `expires_at`, `used`; consumed via CAS (`4.4 step 12`). |
| `User` | Local account; federated accounts carry `password = "!federated"`. |

Small additive methods on `MfaStore` (`mfa/persistence.zig`) or a new
`SamlStore` sharing the same `zent` client:

```zig
pub fn getIdpRow(self: *MfaStore, provider_id: i64) !?IdentityProviderRow; // id,tenant_id,name,provider_type,enabled,config
pub fn consumeFederatedState(self: *MfaStore, id: i64, now: i64) !bool;   // CAS, see 4.4
pub fn createSamlLoginTicket(self: *SamlStore, tenant_id: i64, provider_id: i64,
    user_id: i64, redirect_to: []const u8, now: i64) ![]const u8;          // returns ticket hex
pub fn consumeSamlLoginTicket(self: *SamlStore, ticket: []const u8, now: i64) !?SamlLoginTicketRow;
pub fn claimAssertion(self: *SamlStore, tenant_id: i64, provider_id: i64,
    assertion_id: []const u8, expires_at: i64, now: i64) !bool;            // false = replay
```

### 7.2 New tables (zent schemas)

```zig
// src/modules/saml/model.zig
const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

/// Global single-use cache for assertion IDs. Assertion IDs are unique per
/// IdP by spec; provider_id scopes the key so two IdPs cannot collide.
pub const SamlAssertionReplay = Schema("SamlAssertionReplay", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("provider_id"),
        field.String("assertion_id").Unique(),
        field.Int("expires_at"),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// One-time browser session hand-off after a successful ACS.
pub const SamlLoginTicket = Schema("SamlLoginTicket", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("provider_id"),
        field.String("ticket").Unique(),     // 32 random bytes, hex encoded
        field.Int("user_id"),
        field.String("redirect_to").Default(""),
        field.Int("expires_at"),
        field.Bool("used").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
```

Registration: add both to `src/schema.zig` `graph` (next to the mfa models,
`schema.zig:58-65`) and create `src/modules/saml/persistence.zig` with its own
`buildGraph` (like `mfa/persistence.zig:10-20`), using the shared
`schema.Client` so cross-table access stays typed. Add `saml.persistence.infos`
to the `StoreEnv` info list in `main.zig:168-187` and to the in-memory test
helpers (`mfa/tests.zig:16`, `src/tests.zig` store setup).

Index notes:

- `assertion_id` unique; queries are insert-only plus
  `expires_at < now` purge. On SQLite/Postgres `field.String` is `TEXT`; if the
  MySQL driver is ever enabled, zent renders `VARCHAR(255)` (`zent field.zig:365`) — assertion IDs are typically ~40 chars, but cap at 255.
- `ticket` unique; `used` + `expires_at` are read on every exchange; the
  unique index is the CAS authority.
- Consider a `(provider_id, expires_at)` composite index on replay if purge
  latency matters; zent index syntax is in the module docs, and a plain
  `expires_at` scan is acceptable at expected volume.

### 7.3 Migration notes

- zent migrates on startup (`docs/development-guide.md` `2.2`; log line
  `"[zent] migrated schema via ..."`, `main.zig:189`). Both new tables are
  purely additive `CREATE TABLE` — safe for rolling deploys: old binaries
  ignore them, new binaries create them; no backfill, no ALTER on existing
  tables.
- The config JSON lives in an existing `TEXT` column: **no DB migration** for
  the SAML config itself. Invalid/legacy configs are rejected at read time
  (fail closed, `3.3`); the fix is an admin update, not a migration.
- Rollback: drop the two tables (replay/ticket data is ephemeral). Keep
  `FederatedState` rows; they expire on their own.
- Cleanup: extend `CleanupCtx` and the scheduled jobs list (`main.zig:58-121`)
  to delete `saml_assertion_replay.expires_at < now` and
  `saml_login_ticket.expires_at < now - 1h`. The existing
  `deleteExpiredFederatedStates` (`persistence.zig:315`) can be called from the
  same job.
- Data retention: replay rows are security state; keep for the assertion
  lifetime plus skew, then delete. Tickets: delete 1 h after expiry. Never
  store the assertion XML, NameID beyond `IdentityLink`, or tokens in these
  tables.

### 7.4 Migration/rollout ordering

1. Land schema + persistence + config parser + admin update endpoint (no
   protocol routes yet): additive, revertible.
2. Land metadata/login/ACS behind a config gate (`enabled` providers only;
   no provider is enabled by default).
3. Land ticket exchange + SPA route before enabling any provider.
4. Enable one pilot IdP per environment; watch
   `saml_acs_failures_total{reason}`.

---

## 8. Test strategy

### 8.1 Layers and tooling

| Layer | Location | Tooling |
| --- | --- | --- |
| Pure units (config, PEM, ISO-8601, escaping, limits) | `saml/tests.zig` | `std.testing` |
| Parser + c14n golden vectors | `saml/tests.zig` + `testdata/c14n/` | byte-for-byte comparison |
| DSig + assertion validation (positive/negative) | `saml/tests.zig` + `testdata/` | canned signed XML |
| Persistence/CAS/replay | in-memory `StoreEnv` (pattern `mfa/tests.zig:16`) | `db_mod.StoreEnv(..., .sqlite, ":memory:")` |
| HTTP layer (routes, status, headers, redirects) | `saml/tests.zig` | `zigmodu.http.Testkit.dispatchOpts` (`src/tests.zig:943`) |
| Full flow (login → ACS → exchange) | `saml/tests.zig` | Testkit + canned fixture |
| fuzz/robustness | `saml/tests.zig` | `std.testing.checkAllAllocationFailures` |

Wire `_ = @import("modules/saml/tests.zig");` into `src/tests.zig`
(`src/tests.zig:2142`). Keep each test file small and use the existing
in-memory store helper style.

### 8.2 Test fixtures and PKI

Directory `src/modules/saml/testdata/` (committed; test-only):

| File | Purpose |
| --- | --- |
| `test-cert-2025.pem`, `test-cert-2026.pem` | Two self-signed RSA-2048 certs for rotation tests |
| `test-key-2025.pem`, `test-key-2026.pem` | Signing keys **only** for regenerating fixtures; never loaded by runtime code |
| `okta-response.xml` | Assertion signed, Response unsigned, exclusive c14n, `ds` declared on ancestor |
| `azure-response.xml` | Assertion signed, tenant-specific Issuer, XML-Schema attribute names |
| `keycloak-response.xml` | Response + Assertion both signed |
| `auth0-response.xml` | Assertion signed, minimal attributes, `Destination` set |
| `metadata.xml` | Expected SP metadata bytes |
| `c14n/*.xml` + `c14n/*.expected` | Golden canonicalization vectors |

Fixtures are generated **offline** by a dev script
(`scripts/gen-saml-fixtures.py`, Python `cryptography` + `lxml`, not run in
CI; not a build/runtime dependency). The script signs with RSA PKCS#1 v1.5 +
SHA-256 over canonicalized bytes produced by `lxml`, so it doubles as an
independent oracle. Document the exact command in the script header.

Never trust the test PKI at runtime: pinning is exact-DER, and the test certs
exist only in fixtures/configs used by tests. Add a `SECURITY.md` note if the
repo policy requires it.

### 8.3 Positive cases

- Assertion-signed / Response-unsigned (Okta/Azure shape) → success.
- Response-signed / Assertion-unsigned with `want_assertions_signed = false` → success.
- Both signed → success; both signatures verified.
- `InclusiveNamespaces PrefixList="xs"` on SignedInfo → success.
- `ds` namespace declared on `Response` instead of `Signature` → success.
- NameID `persistent` and `emailAddress` → link/create behave per `6.2`.
- Existing `IdentityLink` → `reuse_link` (no duplicate user).
- Verified email + existing local user + `trust_email_as_verified = true` → link.
- JIT create with mapped attributes (email/name) → user row with `!federated` marker.
- Second cert in rotation set verifies; first still verifies.
- Metadata endpoint content type and body; login redirect decodes to the
  expected AuthnRequest (inflate in test, assert ID/ACS/entityID).
- Ticket exchange returns a JWT whose `sub`/`aud`/`ver` match the user row.
- IdP-initiated (v1.1): accepted only when enabled and replay-cached.

### 8.4 Negative cases (must fail closed)

Each gets a dedicated fixture/mutation and an expected internal error; the
HTTP-level assertion is only "400 + no Set-Cookie + no session/ticket".

| Case | Expected error |
| --- | --- |
| Flip one byte in `SignatureValue` | `SignatureInvalid` |
| Flip one byte in the signed `Assertion` | `DigestMismatch` |
| Re-sign with the wrong (unpinned) key/cert | `CertificateMismatch` |
| Remove `Signature` from the Assertion while required | `MissingSignature` |
| Put `Signature` inside `Extensions` | `UnexpectedSignature` |
| Duplicate `ID` (wrapping) / two Assertions | `DuplicateId` / `MultipleAssertions` |
| `Reference URI` points at a different element | `ReferenceMismatch` |
| XPath transform in `Transforms` | `UnsupportedTransform` |
| `rsa-sha1` when not allowed | `UnsupportedSignatureAlgorithm` |
| `c14n WithComments` | `UnsupportedCanonicalization` |
| Expired `NotOnOrAfter` (Conditions/SCD), `NotBefore` in the future | `AssertionExpired` / `AssertionNotYetValid` |
| Missing SCD `NotOnOrAfter` | `MissingExpiry` |
| Wrong `Audience` / `Recipient` / `Destination` | corresponding mismatch |
| Wrong `Issuer` (Response/Assertion disagree) | `IssuerMismatch` |
| Replay same assertion twice | `ReplayedAssertion` |
| Replay same `RelayState` / reused state | `ReusedState` |
| Unknown/expired `RelayState` | `UnknownState` / `ExpiredState` |
| `InResponseTo` mismatch or absent (SP-initiated) | `InResponseToMismatch` |
| `SAMLResponse` missing / duplicated / wrong content type | `MissingSamlResponse` / `DuplicateSamlResponse` / `WrongContentType` |
| DOCTYPE / entity expansion / external ref | `ForbiddenXmlConstruct` |
| Depth > 32 / elements > 4096 / body > limit | `XmlLimitExceeded` / `TooLarge` |
| Non-UTF-8 / UTF-16 input | `MalformedXml` |
| `Transient` NameID / format mismatch | `TransientNameId` / `NameIdFormatMismatch` |
| Missing email for a new user | `MissingEmail` |
| Existing local user + unverified email + default policy | `EmailConflict` |
| User in another tenant / deleted user after link | `TenantMismatch` / `UserNotFound` |
| Disabled provider / unknown provider | 404 |
| Ticket reused / expired / forged | `TicketReused` / `TicketExpired` / `TicketInvalid` |
| Signature wrapping with a second `Subject`/`Assertion` | reject (`4.2 step 5`) |

### 8.5 HTTP-layer assertions

- Metadata: `200`, `Content-Type: application/samlmetadata+xml`, body parses
  as XML, contains `entityID`, ACS binding and `WantAssertionsSigned`.
- Login: `302`, `Location` starts with the configured `sso_url`, contains
  `SAMLRequest` and `RelayState`; inflating + base64-decoding yields the
  expected XML. Disabled provider → `404`; tampered `redirect_to` → `400`.
- ACS success: `303`, `Location` has `ticket`, `Cache-Control: no-store`; no
  `Set-Cookie`; ticket exchange returns `200` JSON with `token`/`user`.
- ACS failure: `400`, generic HTML, no assertion content, request id present.
- Exchange: `200` once, then `400` for the same ticket; forged ticket `400`;
  rate-limited after N attempts (existing `RateLimiterRegistry` pattern,
  `webauthn_api.zig:27`).
- `GET /saml/{id}/acs` → `405`; `POST` with JSON → `415`; oversize → `413`.

### 8.6 Test certificate generation in CI

Two acceptable approaches; **the committed-fixture approach is recommended**
because Zig 0.17 has no RSA signing and `zig build test` must stay
network/toolchain-independent.

**A. Committed deterministic fixtures (recommended).** Generate once on a
dev machine and commit certs, keys and signed responses:

```sh
# 2048-bit self-signed cert, 10 years, no passphrase (test-only)
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout test-key-2025.pem -out test-cert-2025.pem \
  -subj "/CN=zasdoor-saml-test-2025/O=zasdoor/C=US"

# Then produce signed fixtures with Python (independent c14n oracle):
python3 scripts/gen-saml-fixtures.py --cert test-cert-2025.pem --key test-key-2025.pem
```

CI simply runs `zig build test`; no openssl/python needed. Rotation tests use
the second committed cert/key pair.

**B. Generate in CI before tests (only if policy forbids committed keys).**
Run the same openssl command in the CI job, then run the Python fixture
generator (pin the Python packages or vendor the script); set
`SAML_TESTDATA_DIR` so tests read the generated directory. This adds a Python
+ openssl dependency to CI and makes failures less reproducible; document the
trade-off. Either way, no private key ever ships in the server binary.

### 8.7 Robustness

- Run every parser/c14n/dsig test through
  `std.testing.checkAllAllocationFailures` (0.17 builtin) so OOM paths do
  not leak or crash.
- Malformed corpus: truncation at every byte boundary (sample), unclosed
  tags, invalid UTF-8, huge attribute counts, namespace bombs, duplicate
  attributes, comments in odd places.
- Assert "no panic" — every parser branch returns an error, never
  `unreachable` on input-dependent data.
- Run `zig build lint-size` and `lint-fmt` (the repo gates) and keep files
  under 1800 lines.

---

## 9. Phased delivery, effort estimates, non-goals

Effort legend: **S** ≤ 2 person-days, **M** 3–5, **L** 6–10+.

| Phase | Scope | Effort | Exit criteria |
| --- | --- | --- | --- |
| **P0 — spike & gate** | XML parser + exclusive c14n prototype; reproduce W3C c14n vectors and 2–3 captured IdP responses; compare with `lxml` oracle | **S** (2 d) | Byte-identical canonical output for all vectors; go/no-go on pure Zig vs libxml2 (`5.7`) |
| **P1 — config, metadata, login** | `SamlConfig` parse/validate, admin `PUT/DELETE`, `getIdpRow`, metadata endpoint, login redirect (deflate/base64), `FederatedState` creation, CAS consume, rate limits | **S–M** (3 d) | Testkit: metadata 200 + login 302 with valid AuthnRequest; disabled/invalid config → 404 |
| **P2 — XML + c14n productionization** | Hardened parser, c14n full rules, golden-vector suite, OOM/fuzz tests | **L** (8–10 d) | All golden vectors pass; hostile corpus returns errors with no panic/leak |
| **P3 — DSig + assertion validation** | `dsig.zig`, PEM/pinning, RSA verify, time parsing/checks, state correlation, replay table, error taxonomy, metrics | **M** (4–5 d) | Positive fixtures 4/4; every negative case in `8.4` fails closed with the expected error |
| **P4 — provisioning + hand-off** | Link/email/provision (`6`), login ticket table, exchange endpoint, redirect validation, SPA contract doc | **S–M** (3 d) | End-to-end Testkit: ACS → ticket → JWT with correct `sub`/`aud`/`ver` |
| **P5 — hardening & docs** | Rate limits, audit/log hygiene, cleanup jobs, OpenAPI/README/CHANGELOG/mfa.md updates, interop checklist, security review | **M** (3 d) | Review sign-off; `zig build test`/`lint-size`/`lint-fmt` green |
| **P6 — optional** | IdP-initiated SSO (opt-in), `require_mfa_authn_context` | **S** (1–2 d) | Enabled only by config; replay-cache tests |
| **Future** | SLO, SP-signed AuthnRequests (RSA signing), encrypted assertions, metadata import | **M–L** each | separate design docs |

Total v1 (P0–P5): **~23–26 person-days**, i.e. 4–5 engineer-weeks with the
c14n work and interop iteration dominating. Add a 25–40% buffer for the first
real IdP integration (they always find one shape you did not).

Dependencies: P2 blocks P3; P3 blocks P4; P5 runs alongside P4. P0 must be
completed before committing to P2 (the libxml2 decision changes build files
and Docker/CI if the answer is "no").

**Explicit non-goals (v1)**: SLO, HTTP-Artifact, encryption, SP signing,
Attribute Query, SAML 1.1, multi-assertion responses, metadata fetch/import,
Role mapping from SAML groups, front-channel logout, per-provider UI beyond
configuration.

---

## 10. Security checklist

| # | Threat | Control (where) | Test |
| --- | --- | --- | --- |
| 1 | XXE / external entities / DTD | Parser rejects `<!DOCTYPE`, `<!ENTITY`, external IDs before tokenizing; no resolver exists (`5.3`) | `8.4` malformed corpus |
| 2 | Billion laughs / entity expansion | Same rejection + byte/depth/element limits | `8.7` |
| 3 | Signature wrapping / XSW | Exactly one Assertion; `Signature` only as a direct child of the signed element; unique IDs; `Reference URI` must equal `#ID` of that element; verify and use the same tree node; no XPath transforms (`4.3`) | `8.4` wrapping cases; independent review |
| 4 | Algorithm confusion / downgrade | Allowlist of canonicalization, signature, digest and transform URIs; SHA-1 off by default; HMAC/DSA/ECDSA rejected (`4.3 step 6`) | `8.4` |
| 5 | Certificate substitution | Exact DER pinning; no CA/CN/SAN/hostname logic; rotation set limited to 4 (`5.6`) | `8.4` wrong-cert |
| 6 | Replay (assertion, response, state) | Assertion-ID replay table with unique index; state CAS (`4.4 steps 12–13`); ticket CAS (`2.5`) | `8.4` replay, concurrent-consumption test |
| 7 | Open redirect / RelayState tampering | RelayState is our 128-bit request ID; redirect target stored server-side; only relative paths or allowlisted origins; max 1024 bytes (`2.3`, `2.5`) | `8.5` tampered `redirect_to` |
| 8 | Login CSRF (IdP-initiated) | `allow_idp_initiated = false` by default; when enabled, replay cache + `Destination`/`Recipient` required (`1.2`) | `8.3`/`8.4` |
| 9 | XML/HTTP DoS | 1 MiB wire cap, 256 KiB decoded cap, parse limits, per-IP rate limit, server request timeout | `8.5` oversize, `8.7` |
| 10 | Token leakage | No JWT in URLs/logs; one-time ticket 60 s, single use; `no-store` on ACS/exchange | `8.5` headers, ticket replay |
| 11 | PII / assertion logging | Never log XML, NameID, email or tokens; log internal error name + request id + hashed assertion id | review + grep for `std.log` |
| 12 | Tenant confusion | Provider `tenant_id` authoritative; tenant-scoped email lookup; user/tenant re-check on link (`6.4`) | unit test cross-tenant email |
| 13 | Account takeover via email auto-link | `trust_email_as_verified = false` default; only explicit verified-email link (`6.2`) | `8.4` EmailConflict |
| 14 | Federated-account password reset | `!federated` marker checked before reset (follow-up in auth module) | auth tests |
| 15 | Admin misconfiguration / privilege | Admin-only `requireAdmin` on provider CRUD; strict config validation; enabled check on every request (`2.2`, `3.3`) | 403 tests |
| 16 | Clock manipulation | Skew clamp 0–300 s; short-lived assertions; `NotOnOrAfter` required for bearer; max assertion lifetime | `8.4` time cases |
| 17 | Error oracle | Uniform public error page; details only in logs/metrics (`4.5`) | `8.5` |
| 18 | Transport downgrade | `https` required for `sso_url`/`acs_url` except explicit dev mode; HSTS via global middleware | config unit tests |
| 19 | Key material exposure | v1 stores only public IdP certs; no SP private key exists; test keys are testdata only | review |
| 20 | Dependency/API drift | Wrap `std.crypto.Certificate.rsa`; upgrade test; Zig pinned | CI |
| 21 | Cache poisoning | `no-store` on ACS; metadata only `public, max-age=300` and cannot contain secrets | `8.5` |
| 22 | Logout/session confusion | SLO not advertised; local logout still revokes via `token_version` | manual |

Additional review gates before merge: threat-model pass over `dsig.zig` and
`c14n.zig` by someone other than the author; fuzz corpus in CI; and a manual
pentest-style exercise replaying a captured response with one element moved
(signature wrapping).

---

## 11. Open questions and decisions needed

1. **P0 gate (P2 approach):** pure-Zig c14n vs libxml2. Requires a decision at
   the end of P0; affects build.zig, Dockerfile, CI, and binary portability.
2. **Signed AuthnRequests:** do any target customers require
   `AuthnRequestsSigned=true`? If yes, add RSA signing (no std support) — M/L
   effort with key management. Default assumption: no.
3. **Encrypted assertions:** confirm all target IdPs can be configured to send
   plaintext assertions. If not, XMLEnc is a separate project.
4. **trust_email_as_verified default:** false is the safe default but adds
   friction for enterprises whose IdP does not send a verified flag. Product
   decision; per-provider override exists.
5. **Tenant-scoped admin:** should `POST /mfa/idps` accept a `tenant_id` and
   require an admin of that tenant? Currently `default_tenant_id` is used
   (`main.zig:228`); v1 inherits the gap.
6. **SPA route + exchange contract:** `web/` must add
   `/saml/complete?ticket=…` and call the exchange endpoint; the exact envelope
   and navigation behavior should be agreed with the frontend owner.
7. **Manual link flow:** when `EmailConflict` occurs, the user is told to log
   in and link later — but no link endpoint exists for SAML yet. Either add
   `POST /api/v1/mfa/idps/{id}/link-identity` (authenticated) or document the
   limitation.
8. **Password reset for federated accounts:** block it in the same release
   (security follow-up, `10 #14`).
9. **OpenAPI/docs:** OpenAPI 3.1 additions for the new endpoints, a
   `docs/README.md` row, `docs/mfa.md` cross-reference and CHANGELOG entry are
   out of scope for this file but required before release.
10. **Metrics/alerting:** confirm Prometheus names (`saml_acs_failures_total`,
    `saml_login_total`) and alert thresholds with ops.

---

## Appendix A — typed extraction model

```zig
// src/modules/saml/assertion.zig
pub const Response = struct {
    id: []const u8,
    issue_instant: i64,
    destination: ?[]const u8,
    in_response_to: ?[]const u8,
    issuer: []const u8,
    assertion: Assertion,
    signature_verified: bool,
};

pub const Assertion = struct {
    id: []const u8,
    issue_instant: i64,
    issuer: []const u8,
    subject: Subject,
    conditions: ?Conditions,
    authn: ?AuthnStatement,
    attributes: []Attribute,
    signature_verified: bool,
};

pub const Subject = struct {
    name_id: []const u8,
    name_id_format: ?[]const u8,
    bearer: SubjectConfirmation,
};

pub const SubjectConfirmation = struct {
    not_before: ?i64,
    not_on_or_after: i64,     // required for bearer
    recipient: ?[]const u8,
    in_response_to: ?[]const u8,
    address: ?[]const u8,
};

pub const Conditions = struct {
    not_before: ?i64,
    not_on_or_after: ?i64,
    audiences: []const []const u8,
};

pub const AuthnStatement = struct {
    authn_instant: ?i64,
    session_index: ?[]const u8,
    authn_context_class_ref: ?[]const u8,
};

pub const Attribute = struct {
    name: []const u8,
    name_format: ?[]const u8,
    values: []const []const u8,
};
```

Service surface:

```zig
// src/modules/saml/service.zig
pub const SamlService = struct {
    allocator: std.mem.Allocator,
    store: *SamlStore,
    mfa: *mfa.persistence.MfaStore,
    users: *user.service.UserService,
    app_host: []const u8,
    prod_like: bool,

    pub fn metadataXml(self: *SamlService, a: std.mem.Allocator,
        provider: *const mfa.persistence.IdentityProviderRow) ![]u8;

    pub fn startLogin(self: *SamlService, io: std.Io, provider_id: i64,
        redirect_to: []const u8, now: i64) !StartLoginResult;

    pub fn finishAcs(self: *SamlService, io: std.Io, provider_id: i64,
        form: AcsForm, now: i64) !AcsResult; // AcsResult{ ticket, redirect_to }

    pub fn exchangeTicket(self: *SamlService, io: std.Io,
        ticket: []const u8, now: i64) !ExchangeResult; // { token, user, redirect_to }
};
```

Error mapping helper: `pub fn publicStatus(err: SamlError) u16` and
`pub fn publicMessage(err: SamlError) []const u8` so the API layer cannot leak
internal names.

## Appendix B — wire samples

SP metadata (one provider; no SLO, no signing, no encryption):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
                     entityID="https://id.example.com/saml/7/metadata">
  <md:SPSSODescriptor AuthnRequestsSigned="false"
                      WantAssertionsSigned="true"
                      protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
    <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat>
    <md:AssertionConsumerService
        Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
        Location="https://id.example.com/saml/7/acs" index="1" isDefault="true"/>
  </md:SPSSODescriptor>
</md:EntityDescriptor>
```

AuthnRequest (before deflate/base64):

```xml
<samlp:AuthnRequest
    xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
    xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
    ID="_3f2c1a0b9d8e4f6a8b7c5d4e3f2a1b0c"
    Version="2.0"
    IssueInstant="2026-10-18T00:00:00Z"
    Destination="https://idp.example.com/app/zasdoor/sso/saml"
    AssertionConsumerServiceURL="https://id.example.com/saml/7/acs"
    ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">
  <saml:Issuer>https://id.example.com/saml/7/metadata</saml:Issuer>
  <samlp:NameIDPolicy Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
                      AllowCreate="true"/>
</samlp:AuthnRequest>
```

Minimal signed Response shape used by fixtures (namespace prefix placement is
deliberately realistic: `ds` declared on `Response`, not on `Signature`):

```xml
<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
                xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
                xmlns:ds="http://www.w3.org/2000/09/xmldsig#"
                ID="_resp1" Version="2.0" IssueInstant="2026-10-18T00:00:05Z"
                Destination="https://id.example.com/saml/7/acs"
                InResponseTo="_3f2c1a0b9d8e4f6a8b7c5d4e3f2a1b0c">
  <saml:Issuer>https://idp.example.com/app/zasdoor/sso/saml</saml:Issuer>
  <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
  <saml:Assertion ID="_assert1" Version="2.0" IssueInstant="2026-10-18T00:00:05Z">
    <saml:Issuer>https://idp.example.com/app/zasdoor/sso/saml</saml:Issuer>
    <ds:Signature>
      <ds:SignedInfo>
        <ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>
        <ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>
        <ds:Reference URI="#_assert1">
          <ds:Transforms>
            <ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>
            <ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>
          </ds:Transforms>
          <ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>
          <ds:DigestValue>...</ds:DigestValue>
        </ds:Reference>
      </ds:SignedInfo>
      <ds:SignatureValue>...</ds:SignatureValue>
      <ds:KeyInfo><ds:X509Data><ds:X509Certificate>...</ds:X509Certificate></ds:X509Data></ds:KeyInfo>
    </ds:Signature>
    <saml:Subject>
      <saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">a@example.com</saml:NameID>
      <saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">
        <saml:SubjectConfirmationData NotOnOrAfter="2026-10-18T00:05:05Z"
            Recipient="https://id.example.com/saml/7/acs"
            InResponseTo="_3f2c1a0b9d8e4f6a8b7c5d4e3f2a1b0c"/>
      </saml:SubjectConfirmation>
    </saml:Subject>
    <saml:Conditions NotBefore="2026-10-18T00:00:00Z" NotOnOrAfter="2026-10-18T00:05:05Z">
      <saml:AudienceRestriction>
        <saml:Audience>https://id.example.com/saml/7/metadata</saml:Audience>
      </saml:AudienceRestriction>
    </saml:Conditions>
    <saml:AuthnStatement AuthnInstant="2026-10-18T00:00:05Z">
      <saml:AuthnContext>
        <saml:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport</saml:AuthnContextClassRef>
      </saml:AuthnContext>
    </saml:AuthnStatement>
    <saml:AttributeStatement>
      <saml:Attribute Name="mail"><saml:AttributeValue>a@example.com</saml:AttributeValue></saml:Attribute>
      <saml:Attribute Name="displayName"><saml:AttributeValue>Alice</saml:AttributeValue></saml:Attribute>
    </saml:AttributeStatement>
  </saml:Assertion>
</samlp:Response>
```

## Appendix C — references

Normative:

- OASIS SAML 2.0 Core, Bindings, Profiles, Metadata.
- OASIS SAML V2.0 Web Browser SSO Profile.
- XML Signature Syntax and Processing 1.1; Exclusive XML Canonicalization 1.0.
- W3C XML C14N 1.0/1.1 test cases.

Zig 0.17.0 std symbols verified for this design:

- `std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify` /
  `PSSSignature.verify` / `PublicKey.parseDer` / `PublicKey.fromBytes`
  (`lib/std/crypto/Certificate.zig`, RSA section).
- `std.crypto.Certificate.parse` and `Parsed.pubKey()` (`Certificate.zig`).
- `std.crypto.codecs.asn1` (`lib/std/crypto/codecs/asn1.zig`).
- `std.crypto.hash.sha2`, `std.base64.standard`, `std.compress.flate`
  (`Container.raw`), `std.json`.
- Absence: no `std.xml`, no canonicalization, no RSA private-key signing.

Repository anchors used in this design (line numbers at the time of writing,
HEAD `854ccd5` plus in-flight worktree changes):

- `src/modules/mfa/model.zig:37,62,110` — IdentityProvider / IdentityLink / FederatedState.
- `src/modules/mfa/persistence.zig:35,148,185,304,328,340` — marker, provider CRUD, email scoping, provisioning.
- `src/modules/mfa/idp.zig:89,124,229,316,435,450` — decision, config parse, state, provisioning, form encoding, randomness.
- `src/modules/mfa/idp_api.zig:28,100,135,186` — route pattern, params, callback, JWT minting.
- `src/modules/user/service.zig:312,424` — email normalization, session issuance.
- `src/modules/oauth/api.zig:28,239` — root route registration, redirect pattern.
- `src/main.zig:168-187,189,228,407,428,448` — store env, migration, tenant, body cap, groups.
- `src/schema.zig:58-65` — schema graph registry.
- `src/tests.zig:416,943,2142` — Testkit and module test wiring.
- `src/config.zig:25,116` — `app_host`, `isProdLike`.
- `build.zig` `lint-size` (1800 lines) and `lint-fmt` gates.

