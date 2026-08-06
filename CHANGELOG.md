# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
