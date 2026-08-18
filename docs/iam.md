# IAM 模块(组织 / 项目 / 应用 / 角色)

> ZITADEL 风格的身份与访问管理内核,在 zasdoor 既有多租户(`tenant_id` 行隔离)之上构建。
> 对应代码:`src/modules/iam/`(model → persistence → service → api)。

## 1. 资源层级

```
Organization(组织)
 └── Project(项目)
      ├── Application(应用,即 OAuth2 客户端)
      └── Role(角色) ← RoleAssignment(角色分配,绑定到用户)
```

- **Organization**:顶层业务实体,带可选 `domain`(如 `acme.example.com`)。
- **Project**:组织下的一个业务单元,聚合应用与角色。
- **Application**:OAuth2 客户端,创建时返回 **`client_id` + `client_secret`**(secret 只出现一次,务必保存)。
  - `pkce_required`:强制 PKCE(默认 true)。
  - `redirect_uris`:授权码回调白名单。
  - `grant_types`:如 `authorization_code`、`client_credentials`、`refresh_token`。
- **Role / RoleAssignment**:项目内角色(如 `admin`、`auditor`),可分配给用户;会话与应用授权都引用角色。
- **Session**:独立的会话表,支持按用户/按会话吊销(与认证模块的 JWT token-version 联动)。

## 2. HTTP API(全部要求管理员 JWT)

| Method | Path | 说明 |
| --- | --- | --- |
| GET/POST/DELETE | `/api/v1/iam/organizations` · `/{id}` | 组织 CRUD |
| GET/POST/DELETE | `/api/v1/iam/projects` · `/{id}` | 项目 CRUD |
| GET/POST | `/api/v1/iam/projects/{id}/applications` | 应用列表 / 创建(返回 client_id+secret) |
| DELETE | `/api/v1/iam/applications/{id}` | 删除应用 |
| GET/POST | `/api/v1/iam/projects/{id}/roles` | 角色列表 / 创建 |
| DELETE | `/api/v1/iam/roles/{id}` | 删除角色 |
| POST | `/api/v1/iam/roles/{id}/assign` | 分配角色给用户 |
| GET | `/api/v1/iam/users/{id}/sessions` | 列出用户会话 |
| POST | `/api/v1/iam/sessions/{id}/revoke` | 吊销单个会话 |
| POST | `/api/v1/iam/users/{id}/revoke-sessions` | 吊销用户全部会话 |

分页参数:`page` / `page_size`(最大 100),响应为 ruoyi 分页形状 `{ list, total, page, pageSize }`。

## 3. 代码布局约定

与其它模块一致:`model.zig`(zent schema)→ `persistence.zig`(类型安全查询)→
`service.zig`(领域逻辑)→ `api.zig`(HTTP)。全部表注册在 `src/schema.zig` 的
`infos` 中,迁移随启动自动执行。

## 4. 安全说明

- 所有 IAM 路由挂在 `jwtAuthWithSecurity` + `tokenVersionGuard` 之后,并逐 handler 校验 `admin` 角色。
- 删除组织/项目是级联或受限操作,API 层做存在性检查后返回 404。
- `client_secret` 以明文可读一次;生产环境建议再套一层应用级加密(参照 AI provider key 的 AES-256-GCM 方案)。