# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **OAuth 2.0 Device Authorization Grant (RFC 8628)**: `POST
  /oauth/device_authorization` returns a `device_code`, a human `user_code`
  (XXXX-XXXX) and verification URIs; `POST /oauth/device` approves/denies the
  code while signed in; `POST /oauth/token` with
  `grant_type=urn:ietf:params:oauth:grant-type:device_code` polls with
  `authorization_pending` / `slow_down` / `access_denied` / `expired_token`
  semantics, and is single-use. Discovery advertises the endpoint + grant.
- **OAuth 2.0 Token Exchange (RFC 8693)**: `POST /oauth/token` with
  `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` exchanges a
  `subject_token` (access / ID / JWT) for a new access token; an optional
  `actor_token` adds the delegation `act` claim, `audience` sets the new
  token audience, and `scope` may only be downscoped. Responses carry
  `issued_token_type`; discovery advertises the grant.
- **WebAuthn / Passkey (ES256)**: register and authenticate passkeys. New
  `WebauthnCredential` / `WebauthnChallenge` tables, a minimal CBOR decoder
  (`mfa/cbor.zig`), registration + assertion verification, public passkey
  login issuing a session JWT, credential list/delete, and config
  (`ZASDOOR_WEBAUTHN_RP_ID` / `_RP_NAME` / `_ORIGIN` / `_CHALLENGE_TTL`).
  Public login endpoints are per-IP rate-limited; attestation `none` only.
- **Authorization policy engine (P2)**: a `Policy` table with nullable
  `allow`/`deny` effects, `*` / `user:<id>` / `role:<key>` subjects,
  resource/action wildcards, priority and tenant scoping. Explicit policies
  are evaluated deny-first before the RBAC fallback; `POST /iam/authz/check`
  now returns `source` and `policy_id`, and admins manage policies at
  `/iam/authz/policies` (GET/POST/PUT/DELETE). Policies accept an optional
  JSON `condition` (`org_id`/`project_id`/`resource_id`), and every decision is
  recorded in `AuthzDecision` for audit (`GET /iam/authz/decisions`, 30-day
  scheduled purge).

### Changed

- **Dependencies fetched from git instead of sibling checkouts** — zigmodu
  **v0.39.11** and zent **v0.91.0** are now `.url` + `.hash` entries in
  `build.zig.zon` (tagged tarballs), replacing `.path` entries that pointed at
  `../../../zig_ws/*`. `zig build` clones and unpacks them into `zig-pkg/`, so
  the build no longer depends on a particular directory layout around the
  repository. CI, release and the Dockerfile drop their "recreate the sibling
  dependency layout" steps and their `ZIGMODU_SHA` / `ZENT_SHA` pins, which
  were still naming v0.39.6 / v0.83.0 and are now redundant with the manifest
  hashes; `zig-pkg/` is gitignored and was already in `.dockerignore`.
- **Adapt to Zig 0.17.0 stable** (deps were then zigmodu
  **v0.39.6** and zent **v0.83.0**). Breakages addressed:
  - `std.Io.net.Stream.read` destructures its `net_read` result as a tuple,
    but Zig 0.17.0's `Io.Operation.net_read` yields a `Stream.ReadResult`
    struct, so the helper fails to compile when instantiated. The SMTP
    `readLine` path now calls `readWithControl` (same single-byte, unbuffered
    syscall) and reads `data_len`.
  - zigmodu middleware factories that allocate per-instance state are now
    fallible (`error{OutOfMemory}!Middleware`): `http_middleware.cors`,
    `http_middleware.securityHeaders` and
    `tracing_middleware.rateLimitPerClient`; call sites propagate with `try`.
  - `SecurityModule.verifyPassword` returns `PasswordError!bool`
    (zigmodu v0.33.4+): login, password-reset, email-verification and
    change-password now surface an undecodable stored hash (or a decode-time
    allocation failure) as `error.Unexpected` → HTTP 500 instead of
    answering "wrong password". The OAuth client-credentials path logs it and
    fails closed as `invalid_client`.
  - The `changePassword` unit test stored a placeholder `"hash"`, which the
    new API reports as corrupt; it now stores a real PBKDF2 hash and checks a
    genuinely wrong password.
- **Sync with upstream `chy3xyz/zenaipa` v0.2.3** (this fork diverged at
  v0.2.2). Upstream's dependency bumps (zent v0.67 / zigmodu v0.20.1) are
  already superseded here (zent v0.83 / zigmodu v0.39.6), so only the
  dependency-independent patterns were ported:
  - `src/schema.zig`: all tables in **one** `buildGraph` (zent raised the
    comptime branch quota in v0.29.4; the split was stale guidance and blocked
    cross-table `WithEdge`).
  - JSON write endpoints use `bindJsonLoose` (snake_case/camelCase and `null`
    tolerant) instead of strict `bindJson` — 34 endpoints across 11 modules.
  - `ai.quotaForUser` uses `SumOrZero`: an empty rolling window folds SQL NULL
    to 0 instead of `error.TypeMismatch`.
  - `mail_template.upsert` is a single `SaveOrUpdateOnWith` on the unique
    `code` (atomic, keeps row id / `created_at`) instead of exists-then-write.
  - `task.requeueStale` re-queues within-budget claims with one
    `UPDATE ... WHERE id IN (...)` (`zent.sql.In`).
  - File uploads run through zigmodu `UploadGuard.check`: bytes are sniffed so
    active content (SVG/HTML) renamed to `.txt` is refused; extension + size
    checks share one call. `FileTypeNotAllowed` maps to **400**, not 500.
  - Ported the matching upstream tests (quota empty window, batch requeue +
    `countByStatus`, UploadGuard rename bypass); backend suite 79 → **81**.
- **Borrow upstream `chy3xyz/zenaipa` v0.3.0 hardening** (an
  engineering-practice release; its dependency bumps were already in place
  here):
  - New `src/http/url_guard.zig`: an OWASP API4 SSRF baseline for AI provider
    endpoints (write-path validation on create/update plus a pre-outbound
    re-check in `ai/service.zig`, so rows written earlier cannot bypass it);
    userinfo and literal loopback/private hosts are rejected.
  - AI admin routes now also run `tokenVersionGuard`; AI API frees store rows
    with the owning store allocator instead of the request arena (a silent
    leak); three `@errorName` client leaks replaced with generic messages.
  - Upload names are sanitized (`sanitizeFilename`) and storage-key extensions
    must be alphanumeric, closing rename/traversal paths; an orphaned disk file
    on delete is logged.
  - Session teardown is ownership-explicit (`UserService.freeSession`), fixing
    the password-hash copy leak through the request arena; register no longer
    reports a DB error as 409 "email taken"; three more store/hash frees moved
    to their producing allocator (caught by the new E2E leak gate).
  - `resetPassword` is transactional (`UserStore.resetPasswordAtomic`): hash
    update + token clear commit together, with the shared password policy still
    enforced.
  - Task queue: `markDone`/`markFailedOrRetry` are status-guarded and return
    affected-row semantics; `retryTask`/`cancelTask`/purge return real counts;
    handlers return `anyerror!void`, so a failing `mail.send` payload retries
    instead of being recorded done or killing the dispatcher.
  - Cache accesses are mutex-serialized (the LRU manager is single-threaded);
    notification mark/delete/purge counts are real.
  - Production-shaped startup preflight is fail-closed (explicit JWT secret
    >=16 chars, no wildcard CORS); the server gains `max_connections` +
    `request_timeout_ms` caps with 503 over-limit; zent's runtime log sink is
    routed to `std.log`.
  - `/metrics` exports dispatcher processed/failed counters; `/system/info`
    reports a build-time version (`-Drelease`); added `lint-size`/`lint-fmt`
    build steps, `scripts/run_e2e.sh` (shutdown panic/leak gate),
    `scripts/check_file_size.sh` and `.dockerignore`.
  - Web: non-2xx envelopes are unwrapped into `ApiError`, so the server's
    message is shown instead of axios's generic 400 text.
- **Security hardening (assessment P0/P1)**:
  - **Refresh-token rotation + reuse detection**: refresh tokens are
    single-use; replaying an already-rotated token revokes the entire rotation
    family (new `family_id` / `rotated_at` columns). Refresh is also bound to
    the authenticating client (confidential clients must present the secret).
  - **OIDC signing key ring**: `ZASDOOR_OIDC_KEY_SECRETS` (comma-separated)
    adds historical keys that are published in JWKS and accepted for
    verification while the primary key signs, so tokens issued before a
    rotation keep verifying during the overlap window.
  - **Exact redirect matching**: `redirect_uri` and
    `post_logout_redirect_uri` are matched as exact JSON-array elements
    (substring matching was bypassable via a suffix domain).
  - **RP-initiated logout**: new `/oauth/end-session` endpoint (advertised in
    discovery) revokes the user's sessions via a token-version bump and
    redirects to a registered `post_logout_redirect_uri`.
  - ID tokens now carry **`at_hash`** bound to the access token.
  - `pkce_required` now defaults to **true** for new applications.
  - **Shared-storage login lockout**: failed-login state moved from an
    in-process hash map to a persisted `login_attempts` table (transactional
    increment), so lockouts are global across instances; stale rows are swept
    by a scheduled job.
  - **OIDC `address` / `phone` scopes**: `User` gains optional `phone` /
    `address`; `PUT /auth/profile` sets them (JSON-safe validation) and the
    ID token + userinfo emit `phone_number` / `address` when the scope is
    requested and a value exists. Discovery advertises both scopes.
  - CI gained a `ReleaseSafe` build and the E2E shutdown/leak gate.

### Security

- **Federated accounts cannot acquire a local password**: password reset now
  refuses `!federated` accounts (`FederatedAccount` -> HTTP 400) even with a
  previously minted token, and forgot-password no longer creates a reset token
  for them. The marker constant is defined once in the user domain.
- **IdP management is admin-only**: `GET/POST /mfa/idps` and
  `POST /mfa/idps/{id}/link` now require an admin user (403 otherwise); the
  public `start`/`callback` routes are unchanged.

### Verified

- `zig build`, `zig build test` (107/107) and `zig build -Doptimize=ReleaseSafe`
  pass on Zig 0.17.0; `zig fmt --check` and `scripts/run_e2e.sh` (boot ->
  probes -> admin/login/info -> graceful shutdown, no panic/leak) are green,
  with the web typecheck/vitest/rsbuild also passing.

## [0.4.0] - 2026-09-13

### Added

- **OIDC asymmetric signing + real JWKS**: ID/access tokens are now signed with
  **EdDSA (Ed25519)**; `/.well-known/jwks.json` serves the matching **public** JWK
  and discovery advertises the algorithm it actually uses. The signing key is
  derived deterministically from `ZASDOOR_JWT_SECRET` via HKDF-SHA256, so keys are
  stable across restarts with no new configuration. ES256 (P-256) primitives are
  in place for a follow-up.
- **OAuth user consent**: scopes must be granted before an authorization code is
  issued; an un-consented request returns `consent_required` with the requested
  scopes, and `consent_granted=true` records the grant.
- **Federated (social) login**: OIDC identity providers with a single-use,
  TTL-bounded anti-CSRF `state`, server-side authorization-code exchange,
  userinfo/id_token parsing, persisted identity links and just-in-time user
  provisioning (`POST /mfa/idps/{id}/start`, `GET /mfa/idps/{id}/callback`).
- **Password policy & account lockout**: a shared policy (min/max length, common-
  password denylist, identity checks) enforced on register/change/reset, plus
  per-account failed-login lockout that is checked before the DB lookup.
- **HTTP integration tests** for the IAM / OAuth / MFA / web3 / agent routes
  through Zigmodu's Testkit (no socket), plus identity-provider and OAuth unit
  tests. Backend suite grew from 58 to **79 tests**.
- `SECURITY.md`, a documentation index, an identity-provider management page, and
  a tag-triggered release workflow.

### Security

- Federated login no longer auto-links an existing local account when the provider
  does not assert `email_verified` — that was an account-takeover vector; such a
  callback now returns `409` and requires an explicit link while signed in.
- Federated users' `verified` flag now mirrors the provider's `email_verified`
  claim instead of being hardcoded true.
- Email lookup during federated provisioning is tenant-scoped, so a login can
  never link across tenant boundaries.
- Password denylist extended with `password123` and other common passwords.

### Fixed

- `/api/v1/health/ready` freed its readiness probe through the per-request
  connection arena while the rows were allocated by the store allocator; it now
  frees with the allocator that produced them.
- **Graceful shutdown no longer panics**: `main` joined the server thread twice
  (`defer server_handle.join()` plus an explicit join), so every SIGTERM/SIGINT
  logged the shutdown and then hit `reached unreachable code` in
  `std.Thread.join`. The join now happens exactly once.

### Changed

- **Adapt to zigmodu v0.15.44 + zent v0.45.0** (path deps via
  `zig_ws/zigmodu` and `zig_ws/zent`). The sibling checkouts were bumped
  past the previous baseline (zigmodu v0.15.22 / zent v0.29.7) and the
  project rebuilt from a cleared `.zig-cache` + `.zig-global-cache`.
  `zig build` succeeds, all 79 unit tests pass (`zig build test`),
  (CI/Docker clone these exact pinned commits — see below),
  and the binary starts cleanly (DB migration, 17 modules, route
  registration, HTTP accept loop).

### Verified

- **zent v0.36 breaking points**: `migrateSchema` now runs under an
  advisory lock by default (`MigrateOptions.lock_timeout_ms` default
  10s, `0` disables) — zasdoor's `db.zig::StoreEnv.open` keeps the
  default; the single-process dev path is unaffected. `OutboxMessage`
  `claimed_at` column is opt-in (we don't use zent outbox — `TaskStore`
  has its own claim-based dispatcher with its own `requeueStale`,
  unchanged). `createAllTables` allocator argument — N/A, we use
  `migrateSchema`. Interceptor chain move semantics — N/A, no
  interceptors registered. UUID PK DDL fix and `StorageKey` — N/A,
  all PKs are `i64` and field names match column names. Migration
  checksum verification — fresh DBs are fine; existing `zasdoor.db`
  / `zenaipa.db` get an updated checksum on first re-migration.
- **zent v0.37 pool contract**: `Options.max_wait_ms` only matters
  when callers opt into a `ConnPool`. zasdoor uses
  `zent.codegen.client.makeClient(..., driver.asDriver())` with a
  directly-owned driver (`SQLiteDriver` / `PostgresDriver` allocated
  in `StoreEnv`), so the pool parking semantics don't change runtime
  behaviour here. `ConnPool.deinit` caller contract — N/A, no
  ConnPool.
- **zigmodu surface area**: `jwtAuthWithSecurity` (the middleware
  `AppSecurity.jwtMiddleware` returns) still exists and still writes
  `user_id` / `tenant_id` attrs that `middleware/auth.zig` reads — no
  `sendErrorResponse` / `bindJson` / `setAttr` callsite changed.
  `http_middleware.cors`, `tracingMiddleware`, `RateLimiterRegistry`,
  `PageParams.parse`, `sendPaged`, `RequestUtil.getRealIp`,
  `Extract.toDtoList`, `HttpMetricsCollector`, `Server.initWithConfig`
  all still exported. `withName` / `builder(...)` not used here
  (legacy `Server` + `RouteGroup` setup preserved). The DO/DON'T
  table in zigmodu AGENTS.md recommends `http.productionProfile()` /
  `PrometheusMetrics` / Auth Path A
  (`jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.rbac)`)
  for new apps; this is a legacy application and the v0.14.x baseline
  is unchanged on purpose — left for a follow-up.

### Dependencies

- zigmodu v0.15.37 (`HttpMetricsCollector` thread-safe counters,
  OOM-safe WS accept loop, linux shutdown-listener-before-close fix;
  `OutboxOps.requeueStale` example, `Preflight`, `productionProfile`,
  `PrometheusMetrics`, `JwksKeyRing`, `DistributedLock` available but
  not adopted by this app)
- zent v0.37.0 (v0.32.3 SQLite single-connection serialization,
  v0.33.0 `UseInterceptor` Create/BulkInsert coverage, v0.35.0 outbox
  claim-based dispatch, v0.36.0 migration lock + checksum, outbox
  `claimed_at`, BulkInsert chunking, `StorageKey`, `queryTargetsByValue`,
  MySQL TLS, UUID PK DDL fix, v0.37.0 pool `max_wait_ms` blocking waits
  + nested-preload N+1 fix)

## [0.3.0] - 2026-02-11

### Added

- **Project renamed to Zasdoor**(formerly Zenaipa): package, binaries,
  env prefix (`ZASDOOR_*`), web UI branding, and docs updated end-to-end.
- **IAM module**: organizations / projects / applications
  (OAuth2 clients with `client_id`/`client_secret`) / roles & assignments /
  sessions; admin HTTP API under `/api/v1/iam/*`.
- **Authz module**: generic `POST /api/v1/iam/authz/check` authorization endpoint.
- **OAuth2 / OIDC**: authorization code + PKCE (`plain`/`S256`),
  `client_credentials`, `refresh_token`; discovery, JWKS, userinfo,
  introspection, revocation.
- **MFA**: TOTP (HmacSHA1) enroll/verify, recovery codes, per-tenant policy.
- **Web3 / SIWE**: EIP-4361 message parsing, single-use nonce reservation,
  wallet↔user binding, JWT issuance for bound wallets.
- **Agent module**: machine identities with capability/scope allow-lists,
  per-period budget ledger (`budget_remaining` JWT claim), token verify endpoint.
- **Event store**: append-only domain-event persistence.
- Web frontend pages: IAM (organizations/projects/applications/roles),
  agents, MFA settings, web3 wallet binding.

### Changed

- Env var prefix `ZENAIPA_*` → `ZASDOOR_*`; binaries `zenaipa`/`zenaipa-admin`
  → `zasdoor`/`zasdoor-admin`; web package `zenaipa-web` → `zasdoor-web`.
- Backend test suite grown to 56 tests (IAM, OAuth PKCE, MFA TOTP,
  SIWE EIP-4361, agent budget ledger).

---
## [0.2.2] - 2026-08-11

### Fixed

- **Security**: `bumpTokenVersion` is now a single atomic
  `token_version = token_version + 1` UPDATE (no read-modify-write race);
  `changePassword` propagates `TokenInvalidationFailed` instead of silently
  swallowing it
- **Security**: `claimNext` checks affected rows — concurrent workers no
  longer execute the same task twice
- **Security**: `deleteSession` wrapped in a transaction with an owner check
  (fixes a pre-existing authorization bypass where a non-owner could wipe
  another user's session messages)
- **Security**: public registration is pinned to the default tenant
  (`X-Tenant-ID` header no longer selects a target tenant)
- **Security/leak**: JWT guard now reads only the `token_version` column
  (column projection) and drops the per-request arena free of gpa-owned rows
- **Performance**: Task table gains a `status + available_at` index
  (claimNext / listTasks hot path)

### Changed

- Persistence layer refactored onto `zent.crud_helpers`
  (`get/first/count/exists/latest/paginatedWithOptions`) — 7 modules, ~65
  lines of hand-rolled Query lifecycles removed
- zent v0.29.7 dynamic `[]sql.Predicate` Where support adopted: all
  optional-predicate lists (user/task/notify/file/audit/ai) now use
  `paginatedWithOptions` with sort whitelists
- Added `docs/development-guide.md` — secondary-development best practices
  (module skeleton, zent conventions, transactions, security, performance,
  testing pitfalls)

### Dependencies

- zigmodu v0.15.22+ (sqlx Threaded-Io, HttpMetrics/AccessLogger thread-safety)
- zent v0.29.7 (dynamic Where slices, crud_helpers: latest/paginatedWithOptions/
  increment, Sum → f64, comptime quota fix)

## [0.2.1] - 2026-08-10

### Fixed

- zent v0.29.4 `QueryBuilder.Sum` now returns `f64` (numeric SUM parsed via
  text representation); `quotaForUser` converted with `@intFromFloat` and
  covered by a quota-aggregation test (was a dormant `@intCast(f64)` compile
  error on an unreferenced path)

### Dependencies

- zigmodu v0.15.22 (sqlx Threaded-Io + HttpMetrics/AccessLogger thread-safety
  fixes, no API change)
- zent v0.29.4 (Sum → f64, Rows pool UAF fix, From-edge FK dedup)

## [0.2.0] - 2026-08-07

First tagged release — the full-stack admin framework with an agentic AI
assistant, streaming chat, governance and security hardening.

### Added

- **Full-stack admin framework** — task dispatcher (durable queue + mail.send),
  email templates + verification, files, notifications, cache, admin CLI
  (`zasdoor-admin create-admin`)
- **Multi-tenant isolation** — Tenant entity, JWT `aud` binding, row-level
  scoping
- **Audit & ops** — audit log with CSV export & retention, dashboard stats,
  email templates, per-IP login rate limiting, graceful shutdown
- **Agentic AI assistant** — admin-managed providers (AES-256-GCM encrypted
  keys), platform skills (user/task/audit/tenant search + `notify.send`),
  human approval queue for write actions, workflow orchestration, rolling 24h
  quota, 4-way concurrency bulkhead, provider health check
- **Streaming chat** — `chatStream` + `on_delta` (zigmodu v0.15.16); SSE
  reasoning/delta/done feed with typing effect and JSON fallback
- **Run usage audit** — per-run tokens/steps/tool-call snapshot via
  `AgentMetrics.toStats()` (zigmodu v0.15.17); actual model recorded
- **Resilience** — circuit breaker on provider calls (5-failure → 60s OPEN +
  half-open probe), fail-closed JWT, session revocation (JWT credential
  version)
- **Hardening** — file allow-list, error redaction, metrics IP ACL, audit
  retention, Docker, CI (backend + frontend), frontend tests + theme,
  toast notifications, DataTable skeleton loading, backup playbook

### Fixed

- Streaming tool schemas rejected by DeepSeek/OpenAI (HTTP 400 →
  `ProviderError`): upstream zigmodu v0.15.18 `tools_json` brace fix; zasdoor
  consumes it via `SkillRegistry`
- zent `migrate.zig` comptime branch-quota overflow on 15+ table schemas
  (upstream `10ab9ce`); schemas now compile on zent v0.29.2+

### Dependencies

- zigmodu v0.15.21 (HTTP, security, AI, resilience, Application lifecycle)
- zent v0.29.3 (ORM, schema-as-code, migrations)
