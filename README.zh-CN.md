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
认证、邮箱验证、后台任务、文件上传、通知、缓存，以及覆盖所有这些能力的后台界面。

## ✨ 功能特性

### 认证与账号
- 注册 / 登录 / 登出、忘记与重置密码、`GET /me`（JWT + PBKDF2）
- 邮箱验证：一键验证链接，未验证用户在界面有横幅提示
- 管理员引导 CLI：一条命令创建首个管理员
- 登录限流与防枚举应答

### 平台服务
- **后台任务**：持久化任务队列，自动重试，配套管理界面
- **邮件**：SMTP 发送（STARTTLS + AUTH PLAIN），开发环境控制台日志兜底
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
- 用户管理：CRUD、分页、关键词搜索、自我保护（不可删除/降级自己）
- 任务中心：实时队列统计，失败任务可重试 / 取消 / 清理
- 运行时诊断接口（`/api/v1/system/info`）
- 健康检查：存活探测 + 数据库就绪探测
- 安全响应头、CORS 白名单、脱敏访问日志

### 数据层
- Schema-as-code 迁移，启动时自动执行
- 默认 SQLite，一行环境变量切换 PostgreSQL
- 全模块共享一个类型安全查询客户端

## 🧱 技术栈

| 层 | 技术 |
| --- | --- |
| 后端 | [Zig](https://ziglang.org) 0.17、[zigmodu](https://github.com/zigmodu)（HTTP、安全、限流、缓存）、[zent](https://github.com/zent)（ORM、schema、迁移） |
| 前端 | [SolidJS](https://www.solidjs.com)、TypeScript、[Rsbuild](https://rsbuild.dev)、[Tailwind CSS](https://tailwindcss.com) 4、[DaisyUI](https://daisyui.com) |
| 数据库 | SQLite（默认）、PostgreSQL（运行时切换） |

## 🏗️ 架构

```
浏览器 (SolidJS SPA)
        │  /api/v1 （统一信封：{ code, msg, data }）
        ▼
Zig HTTP 服务 (zigmodu)
        │  全局中间件：安全头 → 访问日志 → CORS → JWT（租户）
        ▼
模块 API ──► Service ──► Persistence（zent client）──► SQLite / PostgreSQL
        │
        └── 任务调度器（后台线程）
                ├── 持久化队列
                ├── 已注册处理器（如 mail.send）
                └── 定时维护（令牌清理、通知归档）
```

每个领域模块遵循统一分层：`model`（schema）→ `persistence`（查询）→ `service`
（业务逻辑）→ `api`（HTTP 处理器）→ `module`（生命周期元数据）。

## 🚀 快速开始

### 环境要求

- [Zig](https://ziglang.org/download/) **0.17**（推荐用 [zigup](https://github.com/tristanisham/zigup) 管理版本）
- [Node.js](https://nodejs.org) **20+** 与 npm（仅前端需要）
- SQLite（静态链接）或运行中的 PostgreSQL

### 1. 启动后端

```bash
zig build run
```

服务默认监听 `http://localhost:8000`，使用本地 `zenaipa.db` SQLite 文件。

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
未配置 SMTP 时，验证与重置邮件会打印在后端控制台。

## ⚙️ 配置

所有配置均为 `ZENAIPA_` 前缀的环境变量，默认值见 [`src/config.zig`](src/config.zig)。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ZENAIPA_HTTP_PORT` | `8000` | HTTP 监听端口 |
| `ZENAIPA_DB_DRIVER` | `sqlite` | `sqlite` 或 `postgres` |
| `ZENAIPA_SQLITE_PATH` | `zenaipa.db` | SQLite 文件路径 |
| `ZENAIPA_PG_CONNINFO` | localhost:5432 | PostgreSQL 连接串 |
| `ZENAIPA_JWT_SECRET` | `dev-secret-change-me` | JWT 签名密钥 |
| `ZENAIPA_TOKEN_EXPIRY` | `86400` | JWT 有效期（秒） |
| `ZENAIPA_APP_HOST` | `http://localhost:3001` | 邮件链接使用的公网地址 |
| `ZENAIPA_CORS_ORIGINS` | `*` | 逗号分隔白名单（`*` 仅限开发） |
| `ZENAIPA_SMTP_HOST` | 空 | SMTP 主机；留空则仅控制台输出邮件 |
| `ZENAIPA_SMTP_PORT` | `587` | SMTP 端口 |
| `ZENAIPA_SMTP_USERNAME` / `ZENAIPA_SMTP_PASSWORD` | 空 | SMTP 凭据 |
| `ZENAIPA_SMTP_FROM` | `zenaipa@localhost` | 发件地址 |
| `ZENAIPA_SMTP_STARTTLS` | `true` | `STARTTLS` 后升级 TLS |
| `ZENAIPA_UPLOAD_DIR` | `uploads` | 上传文件本地目录 |
| `ZENAIPA_UPLOAD_MAX_BYTES` | `10485760` | 上传大小上限（10 MiB） |
| `ZENAIPA_CACHE_MAX_ENTRIES` | `1024` | 缓存容量 |
| `ZENAIPA_CACHE_TTL_SECONDS` | `300` | 缓存 TTL |
| `ZENAIPA_TASK_MAX_ATTEMPTS` | `3` | 后台任务最大尝试次数 |
| `ZENAIPA_TASK_RETRY_INTERVAL_SECONDS` | `60` | 重试退避间隔 |

## 📡 API 概览

所有接口返回统一信封 `{ code, msg, data }`，`code === 0` 表示成功。

| 方法 | 路径 | 访问权限 |
| --- | --- | --- |
| `POST` | `/api/v1/auth/register` · `/login` · `/logout` | 公开（限流） |
| `POST` | `/api/v1/auth/forgot-password` · `/reset-password` · `/verify-email` | 公开（限流） |
| `GET` | `/api/v1/auth/me` | 登录 |
| `POST` | `/api/v1/auth/send-verification` | 登录 |
| `PUT` | `/api/v1/auth/profile` · `/api/v1/auth/password` | 登录 |
| `GET/POST/PUT/DELETE` | `/api/v1/users` · `/api/v1/users/{id}` | 管理员 |
| `GET/POST` | `/api/v1/tasks` · `/tasks/{id}/retry` · `/tasks/{id}/cancel` · `/tasks/purge` | 管理员 |
| `GET` | `/api/v1/tasks/stats` · `/api/v1/system/info` | 管理员 |
| `POST/GET/DELETE` | `/api/v1/files` · `/api/v1/files/{id}` | 登录（本人或管理员） |
| `GET/POST/DELETE` | `/api/v1/notifications` · `/notifications/{id}/read` · `/read-all` | 登录 |
| `GET/POST/PUT` | `/api/v1/tenants` · `/api/v1/tenants/{id}` | 管理员 |
| `GET` | `/health/live` · `/api/v1/health/live` · `/api/v1/health/ready` | 公开 |

> **多租户**：用户/文件等记录会返回 `tenant_id`；普通用户只能访问本租户数据，
> 平台管理员可通过 `?tenant_id=` 查询参数跨租户筛选。

## 📁 项目结构

```
src/
├── main.zig               # 装配：服务、模块、HTTP 服务、调度器
├── admin_cli.zig          # zenaipa-admin CLI（创建/列出管理员）
├── schema.zig             # 共享 zent schema 图与类型化客户端
├── config.zig             # 环境配置
├── db.zig                 # 存储生命周期：驱动 + 自动迁移
├── jobs.zig               # 已注册的后台任务处理器
├── scheduled.zig          # 由调度器执行的定时任务
├── middleware/            # CORS、JWT、限流、访问日志、安全头
├── services/              # 邮件、缓存
└── modules/               # tenant、user、auth、task、file、notify、system
web/
└── src/
    ├── api/               # 类型化 API 客户端（auth、user、task、file、notify）
    ├── pages/             # 登录、注册、邮箱验证、用户、任务、文件、个人资料…
    ├── layouts/           # AuthLayout、MainLayout（导航 + 通知铃铛）
    ├── providers/         # AuthProvider、通知状态
    └── constants/         # 路由常量
```

## ⏱️ 后台任务与调度

任务以持久化行存放在 `Task` 表，调度器每秒扫描一次：

1. **认领** — 取最早的到期 `pending` 任务并标记为 `claimed`
2. **执行** — 调用已注册的处理器（当前为 `mail.send`）
3. **收尾** — 标记 `done`，失败则按退避策略重试，达到 `max_attempts` 后标记 `failed`

worker 崩溃导致的过期认领会自动重新入队。同一后台线程还负责定时维护：每小时清理
过期令牌，每天归档旧通知。

> **说明**：zent 的 SQLite 驱动是单连接，因此所有后台数据库操作收敛到调度器单线程。
> 纯 CPU 型任务可放心使用 zigmodu 的 `WorkerPool` 或 `cron.Scheduler`。

## 🧪 测试

```bash
# 后端：单元 + 集成测试（内存 SQLite + Testkit HTTP 派发）
zig build test

# 前端：类型检查与生产构建
cd web
npm run typecheck
npm run build
```

## 🚢 部署建议

- **TLS**：在 Zig 服务前用反向代理（Nginx、Caddy 或云负载均衡）终止 HTTPS。
- **PostgreSQL**：设置 `ZENAIPA_DB_DRIVER=postgres` 与 `ZENAIPA_PG_CONNINFO`，
  启动时自动迁移表结构。
- **邮件**：配置 SMTP 与真实的 `ZENAIPA_APP_HOST`，确保验证/重置链接指向公网地址。
- **密钥**：生产环境务必覆盖 `ZENAIPA_JWT_SECRET` 与 SMTP 凭据。
- **文件存储**：默认写入本地磁盘（`ZENAIPA_UPLOAD_DIR`），横向扩展时可将
  `FileService` 替换为对象存储。

## 🤝 参与贡献

欢迎任何形式的贡献！请通过 Issue 反馈缺陷与功能建议，并针对 `main` 分支提交
Pull Request。提交前请用 `zig fmt` 格式化代码，并确保 `zig build test` 通过。

## 📄 许可证

[MIT](LICENSE) © Zenaipa contributors
