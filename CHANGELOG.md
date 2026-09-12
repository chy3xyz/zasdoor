# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
