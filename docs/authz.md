# Authz 模块(授权检查 + 策略 + 决策审计)

> 通用鉴权内核:显式策略优先、角色回退、默认拒绝。
> 对应代码:`src/modules/authz/`(model + persistence + service + api)。

## 1. 判定顺序

1. **显式策略**(`Policy` 表,仅 `enabled`):按 `priority` 降序评估;先过 `resource`/`action` 通配与 `condition` 条件,再匹配 `subject`;任一匹配的 `deny` 立即拒绝(deny-overrides),否则第一个匹配的 `allow` 放行。
2. **角色权限回退**:IAM 角色 `permissions` 中的 `resource.action`(支持 `*` 通配)。
3. **UNKNOWN**:无任何匹配,调用方默认拒绝。

## 2. 策略模型

| 字段 | 说明 |
| --- | --- |
| `effect` | `allow` / `deny` |
| `subject` | `*`、`user:<id>`、`role:<role key>` |
| `resource` / `action` | 精确值或 `*` |
| `condition` | 可选 JSON 对象,支持 `org_id`/`project_id`/`resource_id` 整数约束;空串 = 总是适用 |
| `priority` | 评估顺序提示(deny 始终优先) |
| `enabled` | 关闭后不参与判定 |
| `tenant_id` | 租户隔离;检查时可用 `tenant_id` 过滤 |

## 3. API

| Method | Path | Auth | 说明 |
| --- | --- | --- | --- |
| POST | `/api/v1/iam/authz/check` | JWT | `{subject_id, resource, action, project_id?, resource_id?, tenant_id?}` → `{allowed, decision, source, policy_id?}` |
| GET | `/api/v1/iam/authz/policies` | admin | 列出全部策略 |
| POST | `/api/v1/iam/authz/policies` | admin | 创建策略 |
| PUT | `/api/v1/iam/authz/policies/{id}` | admin | 局部更新(只传需要改的字段) |
| DELETE | `/api/v1/iam/authz/policies/{id}` | admin | 删除策略 |
| GET | `/api/v1/iam/authz/decisions` | admin | 最近 100 条决策记录 |

`decision`:`allow` / `deny` / `unknown`;`source`:`policy` / `role` / `none`。

## 4. 示例

```json
{"name":"no-delete","effect":"deny","subject":"*","resource":"proposal","action":"delete"}
{"name":"alice-vote","effect":"allow","subject":"user:1","resource":"proposal","action":"vote"}
{"name":"viewers-write","effect":"allow","subject":"role:viewer","resource":"proposal","action":"write"}
{"name":"p42-read","effect":"allow","subject":"*","resource":"proposal","action":"read","condition":{"project_id":42}}
```

## 5. 决策审计

- 每次 `authorizeDetailed` 都写入 `AuthzDecision`(subject/resource/action/decision/source/policy_id/created_at)。
- `GET /iam/authz/decisions` 返回最近 100 条(admin)。
- 定时任务清理 30 天前的记录;写入失败不影响授权结果(尽力而为)。

## 6. 与 IAM 的协作

- 角色在 IAM 模块创建并分配(`/iam/roles/{id}/assign`),Authz 读取用户全部角色。
- 未命中策略时用角色 `permissions` 回退;仍未命中则 `unknown`。
- 策略管理端点要求 `admin`(否则 403)。

## 7. 安全要点

- deny-overrides;默认拒绝。
- 策略在服务端求值,前端路由守卫仅作展示。
- `subject` 里的用户/角色标识由服务端解析,不信任客户端传入的角色。
- `condition` 只接受 `org_id`/`project_id`/`resource_id` 整数,未知键/类型在创建/更新时返回 400。
