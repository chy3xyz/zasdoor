# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  (`zenaipa-admin create-admin`)
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
  `ProviderError`): upstream zigmodu v0.15.18 `tools_json` brace fix; zenaipa
  consumes it via `SkillRegistry`
- zent `migrate.zig` comptime branch-quota overflow on 15+ table schemas
  (upstream `10ab9ce`); schemas now compile on zent v0.29.2+

### Dependencies

- zigmodu v0.15.21 (HTTP, security, AI, resilience, Application lifecycle)
- zent v0.29.3 (ORM, schema-as-code, migrations)
