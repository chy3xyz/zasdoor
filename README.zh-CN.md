<div align="center">

# Zenaipa

**生产级全栈管理后台框架 —— Zig 后端 + SolidJS 前端，单二进制交付。**

[![Zig](https://img.shields.io/badge/Zig-0.17-orange?logo=zig&logoColor=white)](https://ziglang.org)
[![SolidJS](https://img.shields.io/badge/Frontend-SolidJS-2c4f7c?logo=solid&logoColor=white)](https://www.solidjs.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

[**English**](README.md) | **简体中文**

</div>

---

Zenaipa 是一个开箱即用的管理后台与内部平台脚手架：基于 **Zig** 构建的模块化后端
（[zigmodu](https://github.com/zigmodu) + [zent](https://github.com/zent)），搭配
**SolidJS + TypeScript** 单页应用，从 `git clone` 到上线所需的组件一应俱全：
认证、邮箱验证、后台任务、文件上传、通知、缓存，以及覆盖所有这些能力的后台界面
——另有审计日志、平台概览、可配置的邮件模板，以及完整的智能助手（Provider / 技能 / 聊天 / 审批 / 工作流）。

## ✨ 功能特性

### 认证与账号
- 注册 / 登录 / 登出、忘记与重置密码、`GET /me`（JWT + PBKDF2）
- 邮箱验证：一键验证链接，未验证用户在界面有横幅提示
- 管理员引导 CLI：一条命令创建首个管理员
- 登录限流与防枚举应答

### 平台服务
- **后台任务**：持久化任务队列，自动重试，配套管理界面
- **邮件**：SMTP 发送（STARTTLS 携带系统 CA 校验 + AUTH PLAIN），开发环境控制台日志兜底
- **文件管理**：上传、下载、删除，按用户隔离访问权限
- **通知**：每用户收件箱，页头未读角标
- **缓存**：内存 LRU，TTL 与容量可配置
- **定时维护**：自动清理过期令牌与旧通知

### 多租户
- 租户实体与管理界面（`/tenants`），支持软停用
- 行级隔离：`User` 与 `File` 携带 `tenant_id`，`Task` 记录来源租户
- 租户随 JWT 的 `aud` claim 传递，无需每请求查库
- 注册通过 `X-Tenant-ID` 请求头绑定租户（缺省落到默认租户，单租户部署零改动）

### 管理与运维
- **概览面板** — 平台实时统计：用户（含近 7 天注册趋势）、任务队列、文件、通知、租户、缓存
- **审计日志** — 谁在何时做了什么、来自哪里：登录/注册、用户/任务/租户/文件操作全记录，支持按操作者 / 操作类型 / 关键词筛选
- **邮件模板** — 可配置的验证与重置邮件（变量渲染，未配置时回退内置默认）
- 用户管理：CRUD、分页、关键词搜索、自我保护（不可删除/降级自己）
- 任务中心：实时队列统计，失败任务可重试 / 取消 / 清理
- 运行时诊断接口（`/api/v1/system/info`）
- 健康检查：存活探测 + 数据库就绪探测
- Prometheus 指标（`/metrics`）与每请求 `x-trace-id` 追踪
- 白名单列表排序（`?sort=col&order=asc|desc`）与分页钳制
- 安全响应头、CORS 白名单、脱敏访问日志

### 智能助手
- **Provider**：管理员维护 OpenAI 兼容端点；API 密钥加密存储（AES-256-GCM，主密钥 `ZENAIPA_AI_KEY_SECRET`）
- **技能**：可供 LLM 调用的平台工具（用户搜索、任务统计、审计检索、租户列表，仅管理员），写技能（`notify.send`）走人工审批
- **聊天**：按用户的会话与消息历史（`/api/v1/ai/sessions`）
- **审批与配额**：写技能的人工审批队列；每用户滚动 24 小时调用上限
- **工作流**：zigmodu.ai 编排（健康报告演示）+ 运行审计（`/api/v1/ai/runs`）+ Prometheus AI 指标

### 数据层
- Schema-as-code 迁移，启动时自动执行
- 默认 SQLite，一行环境变量切换 PostgreSQL
- 全模块共享一个类型安全查询客户端

## 🧱 技术栈

| 层 | 技术 |
| --- | --- |
| 后端 | [Zig](https://ziglang.org) 0.17、[zigmodu](https://github.com/zigmodu)（HTTP、安全、限流、缓存、Application 生命周期）、[zent](https://github.com/zent)（ORM、schema、迁移） |
| 前端 | [SolidJS](https://www.solidjs.com)、TypeScript、[Rsbuild](https://rsbuild.dev)、[Tailwind CSS](https://tailwindcss.com) 4、[DaisyUI](https://daisyui.com) |
| 数据库 | SQLite（默认）、PostgreSQL（运行时可切换） |

## 🏗️ 架构

```
浏览器（SolidJS SPA）
        │  /api/v1（JSON 信封：{ code, msg, data }）
        ▼
Zig HTTP 服务（zigmodu）
        │  全局中间件：安全响应头 → 访问日志 → CORS → JWT（租户）
        ▼
模块 API ──► 服务层 ──► 持久化（zent client）──► SQLite / PostgreSQL
        │
        └── 任务调度器（后台线程）
                ├── 持久化队列行
                ├── 注册的处理器（如 mail.send）
                └── 定时维护（令牌清理、通知修剪）
```

每个领域遵循同样的分层 — `model`（schema）→ `persistence`（查询）→
`service`（业务逻辑）→ `api`（HTTP 处理器）→ `module`（生命周期元数据）。

## 🚀 快速开始

### 环境要求

- [Zig](https://ziglang.org/download/) **0.17**（推荐用 [zigup](https://github.com/tristanisham/zigup) 管理）
- [Node.js](https://nodejs.org) **20+** 与 npm（仅前端需要）
- SQLite（静态链接）或一个可用的 PostgreSQL 实例

### 1. 启动后端

```bash
zig build run
```

服务启动于 `http://localhost:8000`，使用本地 `zenaipa.db` SQLite 文件。

### 2. 创建首个管理员

```bash
zig build
zig-out/bin/zenaipa-admin create-admin --email admin@example.com --password 'YourPass123' --name Boss
```

### 3. 启动前端

```bash
cd web
npm install
npm run dev
```

打开 <http://localhost:3001> 登录。开发服务器将 `/api` 代理到 8000 端口的 Zig 后端。
若未配置 SMTP，验证与重置邮件会打印在后端控制台。

## ⚙️ 配置

所有配置均为带 `ZENAIPA_` 前缀的环境变量，默认值见
[`src/config.zig`](src/config.zig)。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ZENAIPA_HTTP_PORT` | `8000` | HTTP 监听端口 |
| `ZENAIPA_DB_DRIVER` | `sqlite` | `sqlite` 或 `postgres` |
| `ZENAIPA_SQLITE_PATH` | `zenaipa.db` | SQLite 文件路径 |
| `ZENAIPA_PG_CONNINFO` | localhost:5432 | PostgreSQL 连接串 |
| `ZENAIPA_JWT_SECRET` | `dev-secret-change-me` | JWT 签名 HMAC 密钥 |
| `ZENAIPA_TOKEN_EXPIRY` | `86400` | JWT 有效期（秒） |
| `ZENAIPA_APP_HOST` | `http://localhost:3001` | 邮件链接中的公网应用地址 |
| `ZENAIPA_CORS_ORIGINS` | `*` | 逗号分隔白名单（生产请勿使用 `*`） |
| `ZENAIPA_SMTP_HOST` | _(空)_ | SMTP 主机；为空则仅控制台输出邮件 |
| `ZENAIPA_SMTP_PORT` | `587` | SMTP 端口 |
| `ZENAIPA_SMTP_USERNAME` / `ZENAIPA_SMTP_PASSWORD` | _(空)_ | SMTP 凭据 |
| `ZENAIPA_SMTP_FROM` | `zenaipa@localhost` | 发件人地址 |
| `ZENAIPA_SMTP_STARTTLS` | `true` | 在 `STARTTLS` 后升级 TLS |
| `ZENAIPA_UPLOAD_DIR` | `uploads` | 上传文件本地目录 |
| `ZENAIPA_UPLOAD_MAX_BYTES` | `10485760` | 单文件上限（10 MiB） |
| `ZENAIPA_CACHE_MAX_ENTRIES` | `1024` | 缓存容量 |
| `ZENAIPA_CACHE_TTL_SECONDS` | `300` | 缓存 TTL |
| `ZENAIPA_TASK_MAX_ATTEMPTS` | `3` | 后台任务最大重试次数 |
| `ZENAIPA_TASK_RETRY_INTERVAL_SECONDS` | `60` | 重试退避间隔 |
| `ZENAIPA_AI_KEY_SECRET` | _(空)_ | 加密 AI Provider 密钥的主密钥（保存 Provider 前必须设置） |
| `ZENAIPA_AI_DAILY_RUN_LIMIT` | `100` | 每用户滚动 24 小时 Agent 调用上限 |

## 🛠️ 操作指南

### 📊 概览面板

管理员的**概览 / Dashboard** 页面（即 `GET /api/v1/system/dashboard`）聚合平台实时计数：

```jsonc
{
  "users": { "total": 128, "registered_last_7d": [3, 5, 2, 8, 4, 6, 7] },  // 旧→新
  "tasks": { "pending": 2, "claimed": 1, "done": 512, "failed": 3, "canceled": 0 },
  "files": 84,
  "notifications": 960,
  "tenants": 4,
  "cache_entries": 37
}
```

### 📋 审计日志

所有敏感操作都会写入 `AuditLog` 表 —— 操作者、操作类型、对象、详情、IP、成功标志与时间戳。已记录的操作：

| 操作 | 含义 |
| --- | --- |
| `auth.login` / `auth.login.fail` | 登录成功 / 失败 |
| `auth.register` | 新账号注册 |
| `user.create` / `user.update` / `user.delete` | 管理员用户管理 |
| `task.retry` / `task.cancel` / `task.purge` / `task.delete` | 任务队列操作 |
| `tenant.create` / `tenant.update` | 租户管理 |
| `file.delete` | 文件删除 |

通过 `GET /api/v1/audit-logs`（仅管理员）查询，可选筛选参数：

| 查询参数 | 说明 |
| --- | --- |
| `page`, `page_size` | 分页（钳制，最大 200） |
| `actor` | 操作者用户 ID（精确） |
| `action` | 操作类型前缀，子串匹配（如 `user.`） |
| `keyword` | 详情子串搜索 |

### 💌 邮件模板

验证与重置邮件由管理员可编辑的模板渲染（`GET/PUT /api/v1/email-templates`，仅管理员）。内置模板 code 与默认内容：

| Code | 默认主题 | 默认正文 |
| --- | --- | --- |
| `verify_email` | `验证你的 {app_name} 邮箱` | 问候语 + `{link}` |
| `reset_password` | `重置你的 {app_name} 密码` | 问候语 + `{link}` |

可用变量（主题中同样可用）：

| 变量 | 值 |
| --- | --- |
| `{app_name}` | `zenaipa` |
| `{link}` | 一键操作链接（验证 / 重置） |
| `{email}` | 收件人地址 |

当某个 code 没有管理员模板时使用内置默认，因此开箱即用。模板内容入队前会经过
JSON 序列化，你编辑中的引号/换行永远不会破坏邮件载荷。

### 🤖 智能助手

管理员在 **AI 管理 → Provider** 配置 Provider：OpenAI 兼容 `endpoint`、JSON 数组形式的
`api_keys` 与逗号分隔的 `models`。密钥先加密再入库，需先设置 `ZENAIPA_AI_KEY_SECRET`
（否则无法保存）。随后可在 **AI 助手** 中与 Agent 对话：

- 内置技能（仅管理员，LLM 可调用）：`zenaipa.user.search`、`zenaipa.task.stats`、
  `zenaipa.audit.search`、`zenaipa.tenant.list`（只读）与 `zenaipa.notify.send`
  （写操作——进入**审批**队列，批准后才会真正发送）
- 会话按用户持久化消息历史；滚动 24 小时配额限制调用次数（`ZENAIPA_AI_DAILY_RUN_LIMIT`）
- **AI 管理 → 运行记录** 展示每次 Agent 运行；**AI 管理 → 工作流** 运行只读健康报告
  工作流；`GET /api/v1/ai/metrics` 暴露 Prometheus Agent 指标

## 📡 API 概览

所有端点返回信封 `{ code, msg, data }`；`code === 0` 表示成功。

| 方法 | 路径 | 访问 |
| --- | --- | --- |
| `POST` | `/api/v1/auth/register` · `/login` · `/logout` | 公开（限流） |
| `POST` | `/api/v1/auth/forgot-password` · `/reset-password` · `/verify-email` | 公开（限流） |
| `GET` | `/api/v1/auth/me` | 已登录 |
| `POST` | `/api/v1/auth/send-verification` | 已登录 |
| `PUT` | `/api/v1/auth/profile` · `/api/v1/auth/password` | 已登录 |
| `GET/POST/PUT/DELETE` | `/api/v1/users` · `/api/v1/users/{id}` | 管理员 |
| `GET` | `/api/v1/audit-logs` | 管理员 |
| `GET/POST` | `/api/v1/tasks` · `/tasks/{id}/retry` · `/tasks/{id}/cancel` · `/tasks/purge` | 管理员 |
| `GET` | `/api/v1/tasks/stats` · `/api/v1/system/info` · `/api/v1/system/dashboard` | 管理员 |
| `POST/GET/DELETE` | `/api/v1/files` · `/api/v1/files/{id}` | 已登录（属主或管理员） |
| `GET/POST/DELETE` | `/api/v1/notifications` · `/notifications/{id}/read` · `/read-all` | 已登录 |
| `GET/POST/PUT` | `/api/v1/tenants` · `/api/v1/tenants/{id}` | 管理员 |
| `GET/PUT` | `/api/v1/email-templates` · `/api/v1/email-templates/{code}` | 管理员 |
| `GET/POST/DELETE` | `/api/v1/ai/sessions` · `/ai/sessions/{id}/chat` · `/messages` | 已登录（属主） |
| `GET/POST/PUT/DELETE` | `/api/v1/ai/providers` | 管理员 |
| `GET/POST` | `/api/v1/ai/approvals` · `/ai/approvals/{id}/approve` · `/reject` | 管理员 |
| `GET/POST/GET` | `/api/v1/ai/runs` · `/ai/workflow/run` · `/ai/metrics` · `/ai/skills` | 管理员 |
| `GET` | `/health/live` · `/api/v1/health/live` · `/api/v1/health/ready` · `/metrics` | 公开 |

> **多租户：** 用户/文件记录的响应都包含 `tenant_id`；非管理员只能访问自己租户的行。
> 平台管理员可通过 `?tenant_id=` 查询参数筛选跨租户数据。
>
> **鉴权：** 管理端路由在后端强制校验角色（`requireAdmin`，对照数据库而非仅凭
> JWT claim），因此隐藏前端入口绝不是唯一防线。

## 📁 项目结构

```
src/
├── main.zig               # 装配：服务、模块、HTTP 服务、调度器
├── admin_cli.zig          # zenaipa-admin CLI（创建/列出管理员）
├── schema.zig             # 共享 zent schema 图 + 类型安全客户端
├── config.zig             # 环境配置
├── db.zig                 # 存储生命周期：驱动 + 自动迁移
├── jobs.zig               # 注册的后台任务处理器
├── scheduled.zig          # 调度器执行的定时任务
├── middleware/            # auth 辅助（JWT 属性）、访问日志、指标、安全响应头
├── services/              # Mailer（SMTP + 控制台）、缓存
└── modules/               # tenant, user, auth, task, file, notify, system, audit, mail_template, ai
web/
└── src/
    ├── api/               # 类型化 API 客户端（auth, user, task, file, notify, tenant, audit, system, mailTemplate）
    ├── pages/             # SignIn, SignUp, VerifyEmail, Users, Tasks, Files, Tenants,
    │                      # Profile, Dashboard, AuditLogs, MailTemplates
    ├── layouts/           # AuthLayout、MainLayout（导航 + 通知铃铛）
    ├── providers/         # AuthProvider、toast/通知状态
    ├── hooks/             # usePaged（数据驱动分页）、useAuth
    ├── components/        # DataTable、UserFormModal
    └── constants/         # 路由路径
```

## ⏱️ 后台任务与调度

任务是 `Task` 表中的持久化行。调度器每秒扫描：

1. **认领** — 取出最早到期且状态为 `pending` 的任务并标记为 `claimed`
2. **执行** — 调用注册的处理器（当前为 `mail.send`）
3. **收尾** — 标记任务为 `done`，或在达到 `max_attempts` 前按退避策略安排重试
   （超出后标记 `failed`）

崩溃 worker 的过期认领会被自动重新入队。同一后台线程还执行定时维护：过期令牌清理
（每小时）与通知修剪（每天）。

> **注意：** zent 的 SQLite 驱动是单连接，因此所有后台数据库工作都停留在一个调度
> 线程上。纯 CPU 负载可安全改用 zigmodu 的 `WorkerPool` 或 `cron.Scheduler`。

## 🧪 测试

```bash
# 后端：单元 + 集成测试（内存 SQLite + Testkit HTTP 分发）
# 覆盖 store、service、JWT/多租户、审计、概览计数、邮件模板，
# 以及管理端门禁（401/403/200）HTTP 流程
zig build test

# 前端：类型检查与生产构建
cd web
npm run typecheck
npm run build
```

## 🚢 部署建议

- **TLS**：在 Zig 服务前由反向代理（Nginx、Caddy 或云负载均衡）终结 HTTPS。
- **PostgreSQL**：设置 `ZENAIPA_DB_DRIVER=postgres` 与 `ZENAIPA_PG_CONNINFO`；schema
  在启动时自动迁移。
- **邮件**：配置 SMTP 与真实的 `ZENAIPA_APP_HOST`，使验证/重置链接指向你的公网地址。
  STARTTLS 会使用系统 CA bundle 校验服务器证书（找不到 CA 存储时降级为不校验并告警）。
- **密钥**：生产环境务必覆盖 `ZENAIPA_JWT_SECRET` 与 SMTP 凭据。
- **文件存储**：默认后端写入本地磁盘（`ZENAIPA_UPLOAD_DIR`）；横向扩展时可把
  `FileService` 换成对象存储。

## 🤝 参与贡献

欢迎贡献！bug 与功能建议请开 issue，PR 请提交到 `main` 分支。Zig 代码请保持
`zig fmt` 格式，并在开 PR 前确保 `zig build test` 通过。

## 📄 许可证

[MIT](LICENSE) © Zenaipa contributors
