# Authz 模块(授权检查)

> 通用鉴权端点,把"谁能做什么"从业务代码中抽出。
> 对应代码:`src/modules/authz/`(service + api;策略表随 IAM 注册)。

## 1. 能力

- 基于 **角色**(IAM RoleAssignment)的授权判定。
- 单一 HTTP 端点 `POST /api/v1/iam/authz/check`,入参 `{ user_id, action, resource? }`,返回是否允许。
- 支持资源级限制(如仅某 project 内生效),策略可扩展。

## 2. API

| Method | Path | 说明 |
| --- | --- | --- |
| POST | `/api/v1/iam/authz/check` | 已登录。`{user_id, action, resource?}` → `{allowed: bool, roles: [...]}` |

## 3. 与 IAM 的协作

- 角色在 IAM 模块创建并分配给用户(`/iam/roles/{id}/assign`)。
- Authz 检查读取该用户的全部角色,按 `(action, resource)` 匹配策略。
- 未命中任何策略默认拒绝(deny by default)。

## 4. 安全要点

- 默认拒绝:显式策略才放行。
- 校验由服务端完成,前端只做展示;切勿信任前端路由守卫。