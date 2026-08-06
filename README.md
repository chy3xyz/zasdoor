<div align="center">

# ⚡ Zenaipa

**One binary. A production-grade full-stack admin platform — Zig backend + SolidJS frontend.**

Ship your internal console faster than your coffee gets cold.

[![Zig](https://img.shields.io/badge/Zig-0.17-orange?logo=zig&logoColor=white)](https://ziglang.org)
[![zigmodu](https://img.shields.io/badge/zigmodu-v0.15.12-blue)](https://github.com/chy3xyz/zigmodu)
[![zent](https://img.shields.io/badge/zent-ORM-6b46c1)](https://github.com/chy3xyz/zent)
[![SolidJS](https://img.shields.io/badge/Frontend-SolidJS-2c4f7c?logo=solid&logoColor=white)](https://www.solidjs.com)
[![Tests](https://img.shields.io/badge/tests-31%20backend%20%2B%205%20frontend-green)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**English** · [**简体中文**](README.zh-CN.md)

</div>

---

## 🚀 Why Zenaipa?

| | |
|---|---|
| 🧩 **Batteries included** | Auth (JWT+PBKDF2), email verification, background jobs, file uploads, notifications, caching, multi-tenancy, audit log, dashboard, email templates — working out of the box, no glue code required |
| 🤖 **Agentic AI built in** | LLM assistant with encrypted provider keys, platform skills, human approval for write actions, quotas, workflow orchestration, reasoning-chain display, run audit & model tracking |
| 🛡️ **Security by default** | Per-IP login rate limiting, server-side **session revocation** (kick users offline instantly), file type allow-list, encrypted secrets, fail-closed production startup, redacted errors |
| 📦 **One binary** | Zig backend compiles to a single static binary; the SolidJS SPA is a static bundle. No runtime, no interpreter, no containers required (but Docker is included) |
| 🚢 **Deploy-ready** | Multi-stage Dockerfile, GitHub Actions CI, graceful shutdown with request draining, backup playbook, Prometheus metrics |

---

## ✨ Features

### 🔐 Authentication & accounts
- Register / login / logout, forgot & reset password, `GET /me` — **JWT + PBKDF2**
- Email verification with one-click links and in-app banners
- Admin bootstrap CLI: `zenaipa-admin create-admin --email you@example.com`
- **Per-client-IP rate limiting** (an attacker can't lock out everyone), anti-enumeration
- **Session revocation**: change password or kick a user → all their tokens die instantly

### 🏗️ Platform services
- **Background jobs** — durable queue with retries + management UI
- **Email** — SMTP (STARTTLS + system CA verification) with console sink for dev
- **Files** — upload/download/delete, owner + admin access, extension/MIME allow-list
- **Notifications** — per-user inbox with unread badge
- **Cache** — in-memory LRU, TTL + capacity configurable
- **Multi-tenancy** — `tenant_id` row isolation, tenant in the JWT `aud` claim, `X-Tenant-ID` registration binding

### 🎛️ Admin & operations
- **Dashboard** — live platform stats with 7-day registration trend
- **Audit log** — who did what, when, from where; filters + **CSV export** + retention-based auto-cleanup
- **User management** — CRUD, pagination, keyword search, self-protection, **kick-offline**
- **Task center** — live queue stats, retry / cancel / purge
- **Email templates** — admin-editable verification/reset mail with variable rendering
- Health probes, Prometheus `/metrics` (IP-allow-listed), `x-trace-id` tracing

### 🤖 Agentic AI assistant
- **Providers** — admin-managed OpenAI-compatible endpoints; API keys **encrypted at rest** (AES-256-GCM)
- **Skills** — LLM-callable platform tools: user search, task stats, audit search, tenant list (read-only) + `notify.send` (write, human-approved)
- **Chat** — per-user sessions with persisted history, **reasoning-chain display** (DeepSeek-R1 etc.)
- **Human-in-the-loop** — approval queue, approve executes the action
- **Governance** — rolling 24h quota, 4-way concurrency bulkhead,**circuit breaker** (5-failure → 60s OPEN + half-open probe), provider health check, run audit with the **actual model** recorded, Prometheus AI metrics
- **Workflow** — read-only health-report orchestration via zigmodu.ai

### 💎 Engineering quality
- Schema-as-code migrations (auto at startup), SQLite ↔ PostgreSQL via one env var
- Type-safe queries end-to-end (no SQL string building)
- **31 backend tests** (stores, services, HTTP via Testkit, JWT/multi-tenancy, audit, AI crypto/approval/quota, admin-gate 401/403/200, session revocation) + **5 frontend tests** (vitest)
- `zig fmt` clean, zero TODOs, graceful shutdown, documented backup strategy

---

## 🧱 Tech Stack

| Layer | Technology |
| --- | --- |
| Backend | [Zig](https://ziglang.org) 0.17 · [zigmodu](https://github.com/chy3xyz/zigmodu) v0.15.12+ (HTTP, security, AI, resilience, Application lifecycle) · [zent](https://github.com/chy3xyz/zent) (ORM, schema, migrations) |
| Frontend | [SolidJS](https://www.solidjs.com) · TypeScript · [Rsbuild](https://rsbuild.dev) · [Tailwind CSS](https://tailwindcss.com) 4 · [DaisyUI](https://daisyui.com) · vitest |
| Database | SQLite (default) · PostgreSQL (one env var) |

---

## 🏗️ Architecture

```
Browser (SolidJS SPA)
   │  /api/v1  (JSON envelope: { code, msg, data })
   ▼
Zig HTTP server (zigmodu, async fibers)
   │  security headers → access log → CORS → JWT (tenant) → token-version guard
   ▼
Module APIs ──► Services ──► Persistence (zent, type-safe) ──► SQLite / PostgreSQL
   │
   ├── Task Dispatcher (background thread)
   │     └── durable queue · mail.send handler · housekeeping (tokens/audit)
   └── AI Agent (zigmodu.ai)
         └── SkillRegistry → platform skills → human approval → run audit
```

Every domain follows the same layout: `model` → `persistence` → `service` → `api` → `module`.

---

## 🚀 Quick Start

```bash
# 1. Backend (starts on :8000 with a local zenaipa.db)
zig build run

# 2. Create the first admin
zig build
zig-out/bin/zenaipa-admin create-admin --email admin@example.com --password 'YourPass123' --name Boss

# 3. Frontend
cd web && npm install && npm run dev
```

Open <http://localhost:3001>. No SMTP configured? Verification/reset mails print to the backend console instead.

---

## ⚙️ Configuration

All settings are `ZENAIPA_*` env vars (see [`src/config.zig`](src/config.zig) for defaults).

| Variable | Default | Description |
| --- | --- | --- |
| `ZENAIPA_HTTP_PORT` | `8000` | HTTP port |
| `ZENAIPA_DB_DRIVER` | `sqlite` | `sqlite` \| `postgres` |
| `ZENAIPA_SQLITE_PATH` | `zenaipa.db` | SQLite path |
| `ZENAIPA_PG_CONNINFO` | localhost | PostgreSQL conninfo |
| `ZENAIPA_JWT_SECRET` | dev only | **Required explicitly in production (fail-closed)** |
| `ZENAIPA_TOKEN_EXPIRY` | `86400` | JWT lifetime (s) |
| `ZENAIPA_APP_HOST` | `http://localhost:3001` | Public origin for email links |
| `ZENAIPA_CORS_ORIGINS` | `*` | Comma-separated allow-list |
| `ZENAIPA_SMTP_*` | _(empty)_ | SMTP host/port/user/pass/from/starttls |
| `ZENAIPA_UPLOAD_DIR` / `ZENAIPA_UPLOAD_MAX_BYTES` | `uploads` / `10 MiB` | Upload storage |
| `ZENAIPA_CACHE_MAX_ENTRIES` / `ZENAIPA_CACHE_TTL_SECONDS` | `1024` / `300` | Cache |
| `ZENAIPA_TASK_MAX_ATTEMPTS` / `ZENAIPA_TASK_RETRY_INTERVAL_SECONDS` | `3` / `60` | Task retries |
| `ZENAIPA_AI_KEY_SECRET` | _(empty)_ | Master key for encrypting AI provider keys |
| `ZENAIPA_AI_DAILY_RUN_LIMIT` | `100` | AI runs per user / 24h |
| `ZENAIPA_AUDIT_RETENTION_DAYS` | `180` | Audit retention |
| `ZENAIPA_METRICS_ALLOW_IPS` | _(empty)_ | `/metrics` IP allow-list |

---

## 🤖 AI Assistant — in depth

1. **Configure a provider** (admin): AI 管理 → Provider — OpenAI-compatible `endpoint`, JSON array of `api_keys`, comma-separated `models`. Keys are AES-256-GCM encrypted (set `ZENAIPA_AI_KEY_SECRET` first). Use the **测试** button to verify connectivity.
2. **Chat** (AI 助手): ask the agent about your platform — *"任务队列现在什么情况?"* It calls read-only skills (user/task/audit/tenant) and shows its **reasoning chain** in a collapsible block.
3. **Write actions need approval**: `notify.send` lands in the approval queue; approving it performs the send (audit-logged, optimistic-locked).
4. **Governance**: rolling 24h quota, 4-way bulkhead, **circuit breaker**, provider health checks, run audit records the **actual model** answered, Prometheus AI metrics.

---

## 📡 API Overview

Envelope: `{ code, msg, data }`, `code === 0` = success.

| Method | Path | Access |
| --- | --- | --- |
| `POST` | `/api/v1/auth/register` · `/login` · `/logout` · `/forgot-password` · `/reset-password` · `/verify-email` | Public (per-IP rate-limited) |
| `GET/PUT/POST` | `/api/v1/auth/me` · `/profile` · `/password` · `/send-verification` | Authenticated |
| `GET/POST/PUT/DELETE` | `/api/v1/users` · `/users/{id}` · `/users/export` · `/users/{id}/revoke-sessions` | Admin |
| `GET` | `/api/v1/audit-logs` · `/audit-logs/export` | Admin |
| `GET/POST` | `/api/v1/tasks` · `/tasks/stats` · `/tasks/{id}/retry` · `/cancel` · `/tasks/purge` | Admin |
| `GET` | `/api/v1/system/info` · `/system/dashboard` | Admin |
| `POST/GET/DELETE` | `/api/v1/files` · `/files/{id}` | Authenticated (owner/admin) |
| `GET/POST/DELETE` | `/api/v1/notifications` · `/notifications/{id}/read` · `/read-all` | Authenticated |
| `GET/POST/PUT` | `/api/v1/tenants` · `/tenants/{id}` | Admin |
| `GET/PUT` | `/api/v1/email-templates` · `/email-templates/{code}` | Admin |
| `GET/POST/DELETE` | `/api/v1/ai/sessions` · `/ai/sessions/{id}/chat` · `/messages` | Authenticated (owner) |
| `GET/POST/PUT/DELETE` | `/api/v1/ai/providers` · `/ai/providers/{id}/check` | Admin |
| `GET/POST` | `/api/v1/ai/approvals` · `/ai/approvals/{id}/approve` · `/reject` | Admin |
| `GET/POST` | `/api/v1/ai/runs` · `/ai/workflow/run` · `/ai/metrics` · `/ai/skills` | Admin |
| `GET` | `/health/live` · `/api/v1/health/live` · `/api/v1/health/ready` · `/metrics` | Public |

---

## 🧪 Testing

```bash
zig build test                     # 31 backend tests (in-memory SQLite + Testkit HTTP)
cd web && npm run typecheck && npm test && npm run build   # vitest + build
```

## 🚢 Deployment

- **Docker**: multi-stage `Dockerfile` builds the API image; serve `web/dist` from any static host and proxy `/api` to the container.
- **CI**: GitHub Actions — `zig fmt --check`, `zig build test`, frontend typecheck/tests/build.
- **Graceful shutdown**: SIGTERM/SIGINT drains in-flight requests, then stops cleanly.
- **Backups**: [`docs/backup.md`](docs/backup.md) — online SQLite `.backup`, `pg_dump`/restore, uploads snapshots, retention schedule.
- **Security checklist**: explicit `ZENAIPA_JWT_SECRET` (mandatory on PostgreSQL), `ZENAIPA_AI_KEY_SECRET` for AI, `/metrics` IP allow-list, audit retention.

---

## 🗺️ Roadmap

| Status | Item |
| --- | --- |
| ✅ Done | AI assistant (providers/skills/chat/approvals/workflow/quota), audit log + CSV, dashboard, email templates, per-IP rate limiting, **session revocation**, file allow-list, graceful shutdown, Docker/CI, frontend tests, theme toggle |
| ✅ Done | **Streaming chat** — Agent `chatStream` + `on_delta` (zigmodu v0.15.16); SSE reasoning/delta/done feed with typing effect, JSON fallback |

---

## 🤝 Contributing

PRs welcome! Keep `zig fmt` clean and make `zig build test` pass. See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

[MIT](LICENSE) © Zenaipa contributors
