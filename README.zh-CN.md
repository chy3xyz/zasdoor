<div align="center">

# ⚡ Zasdoor

**单二进制交付。生产级全栈管理平台 —— Zig 后端 + SolidJS 前端。**

让你在咖啡凉掉之前,把内部管理台搭好上线。

[![Zig](https://img.shields.io/badge/Zig-0.17-orange?logo=zig&logoColor=white)](https://ziglang.org)
[![zigmodu](https://img.shields.io/badge/zigmodu-v0.15.22-blue)](https://github.com/chy3xyz/zigmodu)
[![zent](https://img.shields.io/badge/zent-ORM-6b46c1)](https://github.com/chy3xyz/zent)
[![SolidJS](https://img.shields.io/badge/前端-SolidJS-2c4f7c?logo=solid&logoColor=white)](https://www.solidjs.com)
[![Tests](https://img.shields.io/badge/测试-56%20后端%20%2B%205%20前端-green)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[**English**](README.md) · **简体中文**

</div>

---

## 🚀 为什么选择 Zasdoor?

| | |
|---|---|
| 🧩 **开箱即用** | 认证（JWT+PBKDF2）、邮箱验证、后台任务、文件上传、通知、缓存、多租户、审计日志、概览面板、邮件模板——全部开箱即用,无需胶水代码 |
| 🤖 **内置智能助手** | LLM 助手:密钥加密存储、平台技能、写操作人工审批、配额、工作流编排、推理链展示、运行审计与模型追踪 |
| 🛡️ **安全默认** | 按 IP 登录限流、**服务端会话吊销**(一键踢下线)、文件类型白名单、密钥加密、生产 fail-closed、错误信息脱敏 |
| 📦 **单二进制** | Zig 后端编译为单个静态二进制;SolidJS 前端为静态包。无运行时、无解释器——但 Docker 也已备好 |
| 🚢 **开箱可部署** | 多阶段 Dockerfile、GitHub Actions CI、优雅关闭（排空在途请求）、备份手册、Prometheus 指标 |

---

## ✨ 功能特性

### 🔐 认证与账号
- 注册 / 登录 / 登出、忘记与重置密码、`GET /me` —— **JWT + PBKDF2**
- 邮箱验证:一键链接 + 应用内横幅
- 管理员引导 CLI:`zasdoor-admin create-admin --email you@example.com`
- **按客户端 IP 限流**(攻击者无法锁死全体用户)、防枚举应答
- **会话吊销**:改密或踢下线 → 该用户所有 token 立即失效

### 🏛️ IAM 与身份(ZITADEL 风格)
- **组织 / 项目 / 应用** —— 资源层级;应用即 OAuth2 客户端,带 `client_id` + `client_secret`
- **角色与授权** —— 项目级角色绑定用户,另有通用 `POST /iam/authz/check` 鉴权端点
- **会话管理** —— 列出 / 吊销单个用户或全部会话
- **OAuth2 / OIDC** —— `authorization_code`(+ PKCE `plain`/`S256`)、`client_credentials`、`refresh_token`;`.well-known/openid-configuration`、JWKS、`userinfo`、令牌 introspection 与吊销
- **MFA** —— TOTP 注册/校验(HmacSHA1、6 位)、恢复码、租户级 MFA 策略
- **Web3 / SIWE** —— EIP-4361 签名登录、一次性 nonce、钱包↔用户绑定、绑定钱包签发 JWT
- **AI Agent** —— 机器身份:能力与 scope 白名单、按周期**预算账本**(`budget_remaining` 声明)、令牌校验端点
- **事件存储** —— 追加式领域事件持久化(审计与投影的基础)

### 🏗️ 平台服务
- **后台任务** —— 持久化队列 + 自动重试 + 管理界面
- **邮件** —— SMTP(STARTTLS + 系统 CA 校验),开发环境控制台兜底
- **文件** —— 上传/下载/删除,属主+管理员权限,扩展名/MIME 白名单
- **通知** —— 每用户收件箱 + 未读角标
- **缓存** —— 内存 LRU,TTL/容量可配
- **多租户** —— `tenant_id` 行级隔离、租户随 JWT `aud`、`X-Tenant-ID` 注册绑定

### 🎛️ 管理与运维
- **概览面板** —— 平台实时统计 + 近 7 天注册趋势
- **审计日志** —— 谁在何时做了什么;筛选 + **CSV 导出** + 按保留期自动清理
- **用户管理** —— CRUD、分页、关键词搜索、自我保护、**一键踢下线**
- **任务中心** —— 实时队列统计、重试/取消/清理
- **邮件模板** —— 可编辑的验证/重置邮件,变量渲染
- 健康探测、Prometheus `/metrics`(IP 白名单)、`x-trace-id` 追踪

### 🤖 智能助手
- **Provider** —— 管理员维护 OpenAI 兼容端点;API 密钥 **AES-256-GCM 加密落库**
- **技能** —— LLM 可调用的平台工具:用户搜索、任务统计、审计检索、租户列表(只读)+ `notify.send`(写,人工审批)
- **聊天** —— 按用户会话、历史持久化、**推理链折叠展示**(DeepSeek-R1 等)
- **人工审批** —— 审批队列,批准时真正执行
- **治理** —— 滚动 24h 配额、4 路并发 Bulkhead、**熔断保护**(连续失败 → 开路 + 半开探测)、Provider 健康检查、运行审计记录**实际应答模型**与**每次 run 用量快照**(tokens/steps/工具调用,基于 `Metrics.toStats()`,zigmodu v0.15.17)、Prometheus AI 指标
- **工作流** —— 基于 zigmodu.ai 的只读健康报告编排

### 💎 工程品质
- Schema-as-code 迁移(启动自动);SQLite ↔ PostgreSQL 一个环境变量切换
- 全链路类型安全查询(零 SQL 字符串拼接)
- **56 个后端测试**(store/service、Testkit HTTP、JWT/多租户、审计、AI 加密/审批/配额、管理端门禁 401/403/200、会话吊销、IAM、OAuth PKCE、MFA TOTP、SIWE EIP-4361、Agent 预算)+ **5 个前端测试**(vitest)
- `zig fmt` 全绿、零 TODO、优雅关闭、备份策略文档化

---

## 🧱 技术栈

| 层 | 技术 |
| --- | --- |
| 后端 | [Zig](https://ziglang.org) 0.17 · [zigmodu](https://github.com/chy3xyz/zigmodu) v0.15.22+(HTTP、安全、AI、resilience、Application 生命周期) · [zent](https://github.com/chy3xyz/zent) v0.29.4+(ORM、schema、迁移) |
| 前端 | [SolidJS](https://www.solidjs.com) · TypeScript · [Rsbuild](https://rsbuild.dev) · [Tailwind CSS](https://tailwindcss.com) 4 · [DaisyUI](https://daisyui.com) · vitest |
| 数据库 | SQLite(默认)· PostgreSQL(一个环境变量切换) |

---

## 🏗️ 架构

```
浏览器（SolidJS SPA）
   │  /api/v1（JSON 信封：{ code, msg, data }）
   ▼
Zig HTTP 服务（zigmodu,异步 fiber）
   │  安全响应头 → 访问日志 → CORS → JWT（租户）→ token 版本校验
   ▼
模块 API ──► 服务层 ──► 持久化（zent,类型安全）──► SQLite / PostgreSQL
   │
   ├── 任务调度器（后台线程）
   │     └── 持久化队列 · mail.send 处理器 · 维护任务（令牌/审计清理）
   └── AI Agent（zigmodu.ai）
         └── SkillRegistry → 平台技能 → 人工审批 → 运行审计
```

每个领域统一分层:`model` → `persistence` → `service` → `api` → `module`。

---

## 🚀 快速开始

```bash
# 1. 后端(启动于 :8000,本地 zasdoor.db)
zig build run

# 2. 创建首个管理员
zig build
zig-out/bin/zasdoor-admin create-admin --email admin@example.com --password 'YourPass123' --name Boss

# 3. 前端
cd web && npm install && npm run dev
```

打开 <http://localhost:3001>。未配置 SMTP?验证/重置邮件会打印在后端控制台。

---

## ⚙️ 配置

所有配置为 `ZASDOOR_*` 环境变量(默认值见 [`src/config.zig`](src/config.zig))。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ZASDOOR_HTTP_PORT` | `8000` | HTTP 端口 |
| `ZASDOOR_DB_DRIVER` | `sqlite` | `sqlite` \| `postgres` |
| `ZASDOOR_SQLITE_PATH` | `zasdoor.db` | SQLite 路径 |
| `ZASDOOR_PG_CONNINFO` | localhost | PostgreSQL 连接串 |
| `ZASDOOR_JWT_SECRET` | 仅开发 | **生产必须显式设置(fail-closed)** |
| `ZASDOOR_TOKEN_EXPIRY` | `86400` | JWT 有效期(秒) |
| `ZASDOOR_APP_HOST` | `http://localhost:3001` | 邮件链接公网地址 |
| `ZASDOOR_CORS_ORIGINS` | `*` | 逗号分隔白名单 |
| `ZASDOOR_SMTP_*` | _(空)_ | SMTP 主机/端口/账号/密码/发件人/starttls |
| `ZASDOOR_UPLOAD_DIR` / `ZASDOOR_UPLOAD_MAX_BYTES` | `uploads` / `10 MiB` | 上传存储 |
| `ZASDOOR_CACHE_MAX_ENTRIES` / `ZASDOOR_CACHE_TTL_SECONDS` | `1024` / `300` | 缓存 |
| `ZASDOOR_TASK_MAX_ATTEMPTS` / `ZASDOOR_TASK_RETRY_INTERVAL_SECONDS` | `3` / `60` | 任务重试 |
| `ZASDOOR_AI_KEY_SECRET` | _(空)_ | AI Provider 密钥加密主密钥 |
| `ZASDOOR_AI_DAILY_RUN_LIMIT` | `100` | 每用户 24h AI 调用上限 |
| `ZASDOOR_AUDIT_RETENTION_DAYS` | `180` | 审计保留天数 |
| `ZASDOOR_METRICS_ALLOW_IPS` | _(空)_ | `/metrics` IP 白名单 |

---

## 🤖 智能助手 — 深入

1. **配置 Provider**(管理员):AI 管理 → Provider —— OpenAI 兼容 `endpoint`、JSON 数组 `api_keys`、逗号分隔 `models`。密钥 AES-256-GCM 加密(先设 `ZASDOOR_AI_KEY_SECRET`)。用 **测试** 按钮验证连通性。
2. **聊天**(AI 助手):问 Agent 关于平台的问题 —— *「任务队列现在什么情况?」*。它调用只读技能(用户/任务/审计/租户),并在可折叠块中展示**推理过程**。
3. **写操作需审批**:`notify.send` 进入审批队列;批准时执行发送(审计记录、乐观锁防重复)。
4. **治理**:滚动 24h 配额、4 路 Bulkhead、**熔断保护**、Provider 健康检查、运行审计记录**实际应答模型**与**每次 run 用量快照**(tokens/steps/工具调用,基于 `AgentMetrics.toStats()`)、Prometheus AI 指标。

---

## 📡 API 概览

信封:`{ code, msg, data }`,`code === 0` 表示成功。

| 方法 | 路径 | 访问 |
| --- | --- | --- |
| `POST` | `/api/v1/auth/register` · `/login` · `/logout` · `/forgot-password` · `/reset-password` · `/verify-email` | 公开(按 IP 限流) |
| `GET/PUT/POST` | `/api/v1/auth/me` · `/profile` · `/password` · `/send-verification` | 已登录 |
| `GET/POST/PUT/DELETE` | `/api/v1/users` · `/users/{id}` · `/users/export` · `/users/{id}/revoke-sessions` | 管理员 |
| `GET` | `/api/v1/audit-logs` · `/audit-logs/export` | 管理员 |
| `GET/POST` | `/api/v1/tasks` · `/tasks/stats` · `/tasks/{id}/retry` · `/cancel` · `/tasks/purge` | 管理员 |
| `GET` | `/api/v1/system/info` · `/system/dashboard` | 管理员 |
| `POST/GET/DELETE` | `/api/v1/files` · `/files/{id}` | 已登录(属主/管理员) |
| `GET/POST/DELETE` | `/api/v1/notifications` · `/notifications/{id}/read` · `/read-all` | 已登录 |
| `GET/POST/PUT` | `/api/v1/tenants` · `/tenants/{id}` | 管理员 |
| `GET/POST/DELETE` | `/api/v1/iam/organizations` · `/iam/projects` · `/iam/projects/{id}/applications` · `/iam/roles` | 管理员 |
| `POST` | `/api/v1/iam/authz/check` | 已登录 |
| `GET/POST` | `/api/v1/iam/users/{id}/sessions` · `/iam/sessions/{id}/revoke` | 管理员 |
| `POST` | `/api/v1/mfa/totp/enroll` · `/mfa/totp/verify` · `/mfa/verify` | 已登录 |
| `GET/POST` | `/api/v1/mfa/recovery` · `/mfa/policy` | 已登录 |
| `GET/POST` | `/api/v1/agents` · `/agents/{id}` · `/agents/{id}/token` · `/agents/token/verify` | 已登录 |
| `POST` | `/api/v1/web3/siwe/nonce` · `/web3/siwe/verify` · `/web3/wallet/bind` | 公开 / 已登录 |
| `GET/POST` | `/.well-known/openid-configuration` · `/oauth/authorize` · `/oauth/token` · `/oauth/userinfo` | 公开(协议) |
| `GET/PUT` | `/api/v1/email-templates` · `/email-templates/{code}` | 管理员 |
| `GET/POST/DELETE` | `/api/v1/ai/sessions` · `/ai/sessions/{id}/chat` · `/messages` | 已登录(属主) |
| `GET/POST/PUT/DELETE` | `/api/v1/ai/providers` · `/ai/providers/{id}/check` | 管理员 |
| `GET/POST` | `/api/v1/ai/approvals` · `/ai/approvals/{id}/approve` · `/reject` | 管理员 |
| `GET/POST` | `/api/v1/ai/runs` · `/ai/workflow/run` · `/ai/metrics` · `/ai/skills` | 管理员 |
| `GET` | `/health/live` · `/api/v1/health/live` · `/api/v1/health/ready` · `/metrics` | 公开 |

---

## 🧪 测试

```bash
zig build test                     # 56 个后端测试(内存 SQLite + Testkit HTTP)
cd web && npm run typecheck && npm test && npm run build   # vitest + 构建
```

## 🚢 部署

- **Docker**:多阶段 `Dockerfile` 构建 API 镜像;`web/dist` 由任意静态主机托管并代理 `/api` 到容器。
- **CI**:GitHub Actions —— `zig fmt --check`、`zig build test`、前端 typecheck/测试/构建。
- **优雅关闭**:SIGTERM/SIGINT 排空在途请求后干净退出。
- **备份**:[`docs/backup.md`](docs/backup.md) —— SQLite 在线 `.backup`、`pg_dump`/恢复、uploads 快照、保留节奏。
- **开发指南**:[`docs/development-guide.md`](docs/development-guide.md) —— 新增业务模块的完整步骤(zent/zigmodu 约定、事务、安全、性能、测试陷阱)。
- **模块文档**:[`docs/iam.md`](docs/iam.md) · [`docs/oauth.md`](docs/oauth.md) · [`docs/mfa.md`](docs/mfa.md) · [`docs/agent.md`](docs/agent.md) · [`docs/web3.md`](docs/web3.md) · [`docs/eventstore.md`](docs/eventstore.md) · [`docs/authz.md`](docs/authz.md)
- **安全检查清单**:显式 `ZASDOOR_JWT_SECRET`(PostgreSQL 下强制)、AI 用 `ZASDOOR_AI_KEY_SECRET`、`/metrics` IP 白名单、审计保留。

---

## 🗺️ 路线图

| 状态 | 项目 |
| --- | --- |
| ✅ 已完成 | 智能助手(Provider/技能/聊天/审批/工作流/配额)、审计日志 + CSV、概览面板、邮件模板、按 IP 限流、**会话吊销**、文件白名单、优雅关闭、Docker/CI、前端测试、主题切换 |
| ✅ 已完成 | **流式聊天** —— Agent `chatStream` + `on_delta`(zigmodu v0.15.16);SSE reasoning/delta/done 打字机效果,JSON 降级 |
| ✅ 已完成 | **运行用量审计** —— zigmodu v0.15.17 `Metrics.toStats()`;每次 AI run 持久化 tokens/steps/工具调用用量,管理端 runs 表格展示 |
| ✅ 已完成 | **流式工具 JSON 修复** —— zigmodu v0.15.18(`b28444a`);SkillRegistry tools_json 输出合法 JSON(去掉多余 `}`),修复流式 chat 中 DeepSeek/OpenAI 以 400 拒绝工具 schema(`ProviderError`)的问题 |
| ✅ 已完成 | **依赖升级到最新** —— zigmodu v0.15.22 + zent v0.29.4;zent `Sum` 改为 f64 已适配(`@intFromFloat`),`migrate.zig` comptime 配额修复(`10ab9ce`) |
| ✅ 已完成 | **ZITADEL 风格 IAM** —— 组织 / 项目 / 应用 / 角色 / 会话 + `authz/check` |
| ✅ 已完成 | **OAuth2 / OIDC** —— 授权码 + PKCE、客户端凭证、刷新令牌、discovery/JWKS/userinfo/introspection/revocation |
| ✅ 已完成 | **MFA** —— TOTP 注册与校验、恢复码、租户级策略 |
| ✅ 已完成 | **Web3 / SIWE** —— EIP-4361 消息解析、nonce 预留、钱包绑定、JWT 登录 |
| ✅ 已完成 | **AI Agent** —— 带能力/scope 白名单的机器身份 + 按周期预算账本 |
| ✅ 已完成 | **事件存储** —— 追加式领域事件 |

---

## 🤝 参与贡献

欢迎 PR!保持 `zig fmt` 干净并确保 `zig build test` 通过。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 📄 许可证

[MIT](LICENSE) © Zasdoor contributors
