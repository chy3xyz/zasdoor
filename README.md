# zenaipa — Zig 全栈管理后台框架

对 Go 版 [Pagoda](https://github.com/mikestefanello/pagoda) 的重写：**Zig (zigmodu + zent) 后端 + SolidJS 前端**，单二进制提供服务，开箱即用的后台管理系统骨架。

## 特性（对照 Pagoda）

| 能力 | 说明 |
| --- | --- |
| 认证 | 注册 / 登录 / 登出 / 忘记密码 / 重置密码 / `me`，JWT + PBKDF2 密码哈希 + 登录限流 |
| 邮箱验证 | 注册后自动发送验证邮件，`/verify-email` 链接验证，未验证用户前端有横幅提示 |
| 邮件服务 | 控制台日志（开发）/ SMTP 真实发送（生产），支持 STARTTLS 与 AUTH PLAIN |
| 用户管理 | 管理员 CRUD + 分页 + 关键词搜索，保护"不能删除/降级自己" |
| 管理员引导 | `zig-out/bin/zenaipa-admin create-admin --email ...`（对应 Pagoda `make admin`） |
| 后台任务 | 持久化任务队列（zent 表）+ 单线程 Dispatcher，失败自动退避重试，管理页可重试/取消/清理 |
| 定时任务 | 令牌过期清理（每小时）、通知归档（每天），运行在 Dispatcher 同一后台线程 |
| 缓存 | LRU 缓存服务（zigmodu CacheManager），TTL 与容量可配置 |
| 文件管理 | 原始字节上传 → 本地磁盘 + 元数据表，下载/删除，权限隔离（普通用户仅自己的文件） |
| 通知 | 每用户通知（验证成功、密码修改、系统消息），头部铃铛 + 未读角标，30s 轮询 |
| 系统诊断 | `GET /api/v1/system/info`：运行时信息（DB、邮件模式、缓存、任务计数、模块数） |
| 安全 | CORS 白名单、安全响应头（HSTS/X-Frame-Options/nosniff…）、访问日志（脱敏）、JWT 中间件 |
| 健康检查 | `/health/live`（根）、`/api/v1/health/live`、`/api/v1/health/ready`（DB 探测） |
| 数据库 | SQLite（默认）/ PostgreSQL 运行时切换，schema-as-code 自动迁移 |

## 技术栈

- 后端：Zig 0.17 + [zigmodu](https://github.com/zigmodu)（HTTP/安全/缓存/限流）+ [zent](https://github.com/zent)（ORM/schema）
- 前端：SolidJS + TypeScript + Rsbuild + Tailwind CSS 4 + DaisyUI

## 快速开始

```bash
# 1. 后端（默认 SQLite 文件 zenaipa.db，端口 8000）
zig build run

# 2. 创建第一个管理员（新开终端）
zig build
zig-out/bin/zenaipa-admin create-admin --email admin@example.com --password 'YourPass123' --name Boss

# 3. 前端（端口 3001，/api 代理到 8000）
cd web
npm install
npm run dev
```

打开 http://localhost:3001 登录。未配置 SMTP 时，验证/重置邮件会打印在服务端日志里（控制台 sink）。

## 环境变量（前缀 `ZENAIPA_`）

```bash
# 服务
ZENAIPA_HTTP_PORT=8000
ZENAIPA_DB_DRIVER=sqlite            # sqlite | postgres
ZENAIPA_SQLITE_PATH=zenaipa.db
ZENAIPA_PG_CONNINFO='host=localhost port=5432 dbname=zenaipa user=postgres password=postgres sslmode=prefer'
ZENAIPA_JWT_SECRET=change-me
ZENAIPA_TOKEN_EXPIRY=86400
ZENAIPA_APP_HOST=http://localhost:3001
ZENAIPA_CORS_ORIGINS=*              # 或逗号分隔的白名单

# 邮件（留空 host = 仅控制台日志）
ZENAIPA_SMTP_HOST=smtp.example.com
ZENAIPA_SMTP_PORT=587
ZENAIPA_SMTP_USERNAME=no-reply@example.com
ZENAIPA_SMTP_PASSWORD=secret
ZENAIPA_SMTP_FROM=no-reply@example.com
ZENAIPA_SMTP_STARTTLS=true

# 文件 / 缓存 / 任务
ZENAIPA_UPLOAD_DIR=uploads
ZENAIPA_UPLOAD_MAX_BYTES=10485760
ZENAIPA_CACHE_MAX_ENTRIES=1024
ZENAIPA_CACHE_TTL_SECONDS=300
ZENAIPA_TASK_MAX_ATTEMPTS=3
ZENAIPA_TASK_RETRY_INTERVAL_SECONDS=60
```

## API 概览

所有接口返回统一信封 `{ code, msg, data }`（`code === 0` 成功）。

- 公开：`POST /api/v1/auth/{register,login,logout,forgot-password,reset-password,verify-email}`
- 登录后：`GET /auth/me`、`POST /auth/send-verification`、`PUT /auth/{profile,password}`
- 管理员：`/users`（CRUD+分页）、`/tasks`（列表/统计/重试/取消/清理）、`/system/info`
- 登录后：`/files`（上传/下载/删除）、`/notifications`（列表/未读数/已读/删除）
- 健康：`GET /health/live`、`GET /api/v1/health/{live,ready}`

## 后台任务与定时任务

任务写入 `Task` 表，`Dispatcher` 每秒扫描一次：认领到期任务 → 执行注册的 handler（当前为 `mail.send`）→ 标记完成；失败按指数退避重试，达到 `max_attempts` 后标记失败。管理页"任务中心"可查看/重试/取消。

> 注意：zent 的 SQLite 驱动是单连接，因此所有后台 DB 操作被收敛到 Dispatcher 单线程（`src/scheduled.zig`）。纯 CPU 任务可改用 zigmodu 的 `cron.Scheduler`/`WorkerPool`。

## 测试

```bash
zig build test        # 16 个单元/集成测试（内存 SQLite + Testkit HTTP 派发）
cd web && npm run typecheck && npm run build
```

## 已知边界

- SMTP STARTTLS 默认不做证书链验证（`ca = .no_verification`），生产请自行加载 CA bundle。
- 文件存储为本地磁盘（`ZENAIPA_UPLOAD_DIR`），上云可替换 `FileService` 的落盘实现。
- HTTPS 终止建议由反向代理（Nginx/Caddy/云负载均衡）承担；zigmodu 也支持 HTTP/2 TLS 前置配置。
