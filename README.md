<div align="center">

# Zenaipa

**A production-grade full-stack admin framework — Zig backend, SolidJS frontend, one binary.**

[![Zig](https://img.shields.io/badge/Zig-0.17-orange?logo=zig&logoColor=white)](https://ziglang.org)
[![SolidJS](https://img.shields.io/badge/Frontend-SolidJS-2c4f7c?logo=solid&logoColor=white)](https://www.solidjs.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

**English** | [**简体中文**](README.zh-CN.md)

</div>

---

Zenaipa is a batteries-included starting point for building admin consoles and internal
platforms. It pairs a modular **Zig** backend (built on
[zigmodu](https://github.com/zigmodu) and [zent](https://github.com/zent)) with a
**SolidJS + TypeScript** single-page app, and ships everything you need to go from
`git clone` to a deployed product: authentication, email verification, background jobs,
file uploads, notifications, caching, and an admin UI that covers all of it.

## ✨ Features

### Authentication & accounts
- Register / login / logout, forgot & reset password, `GET /me` (JWT + PBKDF2)
- Email verification with one-click links and in-app banners for unverified users
- Admin bootstrap CLI — create your first administrator in one command
- Login rate limiting and anti-enumeration responses

### Platform services
- **Background jobs** — durable task queue with automatic retries and a management UI
- **Email** — SMTP transport (STARTTLS + AUTH PLAIN) with a console sink for development
- **File management** — upload, download and delete with per-user access control
- **Notifications** — per-user inbox with an unread badge in the header
- **Caching** — in-memory LRU with configurable TTL and capacity
- **Scheduled maintenance** — automatic cleanup of expired tokens and old notifications

### Admin & operations
- User management: CRUD, pagination, keyword search, self-protection guards
- Task center: live queue stats, retry / cancel / purge failed work
- Runtime diagnostics endpoint (`/api/v1/system/info`)
- Health probes: liveness and DB-backed readiness
- Security headers, CORS allow-list, and redacted access logs

### Data layer
- Schema-as-code migrations run automatically at startup
- SQLite out of the box; PostgreSQL via a single environment variable
- One type-safe query client shared across all modules

## 🧱 Tech Stack

| Layer | Technology |
| --- | --- |
| Backend | [Zig](https://ziglang.org) 0.17, [zigmodu](https://github.com/zigmodu) (HTTP, security, rate limiting, cache), [zent](https://github.com/zent) (ORM, schema, migrations) |
| Frontend | [SolidJS](https://www.solidjs.com), TypeScript, [Rsbuild](https://rsbuild.dev), [Tailwind CSS](https://tailwindcss.com) 4, [DaisyUI](https://daisyui.com) |
| Database | SQLite (default), PostgreSQL (runtime switch) |

## 🏗️ Architecture

```
Browser (SolidJS SPA)
        │  /api/v1 (JSON envelope: { code, msg, data })
        ▼
Zig HTTP server (zigmodu)
        │  global middleware: security headers → access log → CORS
        ▼
Module APIs ──► Services ──► Persistence (zent client) ──► SQLite / PostgreSQL
        │
        └── Task Dispatcher (background thread)
                ├── durable queue rows
                ├── registered handlers (e.g. mail.send)
                └── scheduled housekeeping (token cleanup, notification pruning)
```

Each domain follows the same layout — `model` (schema) → `persistence` (queries) →
`service` (business logic) → `api` (HTTP handlers) → `module` (lifecycle metadata).

## 🚀 Quick Start

### Requirements

- [Zig](https://ziglang.org/download/) **0.17** (we recommend managing it with [zigup](https://github.com/tristanisham/zigup))
- [Node.js](https://nodejs.org) **20+** and npm (frontend only)
- SQLite (linked statically) or a running PostgreSQL instance

### 1. Run the backend

```bash
zig build run
```

The server starts on `http://localhost:8000` using a local `zenaipa.db` SQLite file.

### 2. Create the first administrator

```bash
zig build
zig-out/bin/zenaipa-admin create-admin --email admin@example.com --password 'YourPass123' --name Boss
```

### 3. Run the frontend

```bash
cd web
npm install
npm run dev
```

Open <http://localhost:3001> and sign in. The dev server proxies `/api` to the Zig
backend on port 8000. If SMTP is not configured, verification and password-reset emails
are printed to the backend console instead.

## ⚙️ Configuration

All settings are environment variables with the `ZENAIPA_` prefix. See
[`src/config.zig`](src/config.zig) for defaults.

| Variable | Default | Description |
| --- | --- | --- |
| `ZENAIPA_HTTP_PORT` | `8000` | HTTP listen port |
| `ZENAIPA_DB_DRIVER` | `sqlite` | `sqlite` or `postgres` |
| `ZENAIPA_SQLITE_PATH` | `zenaipa.db` | SQLite file path |
| `ZENAIPA_PG_CONNINFO` | localhost:5432 | PostgreSQL connection string |
| `ZENAIPA_JWT_SECRET` | `dev-secret-change-me` | HMAC key for JWT signing |
| `ZENAIPA_TOKEN_EXPIRY` | `86400` | JWT lifetime (seconds) |
| `ZENAIPA_APP_HOST` | `http://localhost:3001` | Public app origin for email links |
| `ZENAIPA_CORS_ORIGINS` | `*` | Comma-separated allow-list (use `*` only in dev) |
| `ZENAIPA_SMTP_HOST` | _(empty)_ | SMTP host; empty = console-only email |
| `ZENAIPA_SMTP_PORT` | `587` | SMTP port |
| `ZENAIPA_SMTP_USERNAME` / `ZENAIPA_SMTP_PASSWORD` | _(empty)_ | SMTP credentials |
| `ZENAIPA_SMTP_FROM` | `zenaipa@localhost` | From address |
| `ZENAIPA_SMTP_STARTTLS` | `true` | Upgrade to TLS after `STARTTLS` |
| `ZENAIPA_UPLOAD_DIR` | `uploads` | Local directory for uploaded files |
| `ZENAIPA_UPLOAD_MAX_BYTES` | `10485760` | Max upload size (10 MiB) |
| `ZENAIPA_CACHE_MAX_ENTRIES` | `1024` | Cache capacity |
| `ZENAIPA_CACHE_TTL_SECONDS` | `300` | Cache TTL |
| `ZENAIPA_TASK_MAX_ATTEMPTS` | `3` | Max attempts per background task |
| `ZENAIPA_TASK_RETRY_INTERVAL_SECONDS` | `60` | Retry backoff interval |

## 📡 API Overview

Every endpoint returns the envelope `{ code, msg, data }`; `code === 0` means success.

| Method | Path | Access |
| --- | --- | --- |
| `POST` | `/api/v1/auth/register` · `/login` · `/logout` | Public (rate-limited) |
| `POST` | `/api/v1/auth/forgot-password` · `/reset-password` · `/verify-email` | Public (rate-limited) |
| `GET` | `/api/v1/auth/me` | Authenticated |
| `POST` | `/api/v1/auth/send-verification` | Authenticated |
| `PUT` | `/api/v1/auth/profile` · `/api/v1/auth/password` | Authenticated |
| `GET/POST/PUT/DELETE` | `/api/v1/users` · `/api/v1/users/{id}` | Admin |
| `GET/POST` | `/api/v1/tasks` · `/tasks/{id}/retry` · `/tasks/{id}/cancel` · `/tasks/purge` | Admin |
| `GET` | `/api/v1/tasks/stats` · `/api/v1/system/info` | Admin |
| `POST/GET/DELETE` | `/api/v1/files` · `/api/v1/files/{id}` | Authenticated (owner or admin) |
| `GET/POST/DELETE` | `/api/v1/notifications` · `/notifications/{id}/read` · `/read-all` | Authenticated |
| `GET` | `/health/live` · `/api/v1/health/live` · `/api/v1/health/ready` | Public |

## 📁 Project Structure

```
src/
├── main.zig               # Wiring: services, modules, HTTP server, dispatcher
├── admin_cli.zig          # zenaipa-admin CLI (create/list administrators)
├── schema.zig             # Shared zent schema graph + typed client
├── config.zig             # Environment configuration
├── db.zig                 # Store lifecycle: driver + auto-migrations
├── jobs.zig               # Registered background task handlers
├── scheduled.zig          # Interval jobs executed by the dispatcher
├── middleware/            # CORS, JWT, rate limit, access log, security headers
├── services/              # Mailer, cache
└── modules/               # user, auth, task, file, notify, system
web/
└── src/
    ├── api/               # Typed API clients (auth, user, task, file, notify)
    ├── pages/             # SignIn, SignUp, VerifyEmail, Users, Tasks, Files, Profile…
    ├── layouts/           # AuthLayout, MainLayout (nav + notification bell)
    ├── providers/         # AuthProvider, toast/notification state
    └── constants/         # Route paths
```

## ⏱️ Background Jobs & Scheduling

Tasks are durable rows in the `Task` table. The dispatcher scans every second:

1. **Claim** — picks the oldest due `pending` task and marks it `claimed`
2. **Run** — invokes the registered handler (currently `mail.send`)
3. **Finalize** — marks the task `done`, or schedules a retry with backoff until
   `max_attempts` is reached (then `failed`)

Stale claims (a crashed worker) are automatically requeued. The same background thread
also runs interval housekeeping: expired token cleanup (hourly) and notification
pruning (daily).

> **Note:** zent's SQLite driver is a single connection, so all background database
> work stays on one dispatcher thread. CPU-only workloads can safely use zigmodu's
> `WorkerPool` or `cron.Scheduler` instead.

## 🧪 Testing

```bash
# Backend: unit + integration tests (in-memory SQLite + Testkit HTTP dispatch)
zig build test

# Frontend: type check and production build
cd web
npm run typecheck
npm run build
```

## 🚢 Deployment Notes

- **TLS**: terminate HTTPS at a reverse proxy (Nginx, Caddy, or a cloud load balancer)
  in front of the Zig server.
- **PostgreSQL**: set `ZENAIPA_DB_DRIVER=postgres` and `ZENAIPA_PG_CONNINFO`; the schema
  migrates automatically on startup.
- **Email**: configure SMTP and a real `ZENAIPA_APP_HOST` so verification/reset links
  point at your public origin.
- **Secrets**: always override `ZENAIPA_JWT_SECRET` and SMTP credentials in production.
- **File storage**: the default backend writes to the local disk
  (`ZENAIPA_UPLOAD_DIR`); swap `FileService` for object storage when scaling out.

## 🤝 Contributing

Contributions are welcome! Please open an issue for bugs and feature requests, and
submit pull requests against the `main` branch. Keep Zig code formatted with
`zig fmt`, and make sure `zig build test` passes before opening a PR.

## 📄 License

[MIT](LICENSE) © Zenaipa contributors
