# Instance / Groups / Domains (P1)

> dev.md 的组织结构层:Instance、Group/GroupMember、Domain 验证。
> 代码:\`src/modules/orgstruct/\`;API 挂在 \`/api/v1/iam/*\`(admin)。

## 1. 实体

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| \`instances\` | \`tenant_id\`, \`name\`, \`global_domain\`, \`config_json\`, \`signing_key_ref\`, \`active\` | 系统实例级配置(SMTP/安全/签名密钥引用) |
| \`groups\` | \`tenant_id\`, \`org_id\`, \`name\`, \`active\` | 组织内用户组 |
| \`group_members\` | \`tenant_id\`, \`org_id\`, \`group_id\`, \`user_id\` | 成员关系,唯一性由 store 保证 |
| \`domains\` | \`tenant_id\`, \`org_id\`, \`name\`, \`verified\`, \`verification_token_hash\`, \`verified_at\` | 组织域名与验证状态 |

## 2. 路由(均需 admin + JWT + tokenVersion + authorize 中间件)

- \`GET/POST /iam/instances\`, \`GET/PUT/DELETE /iam/instances/{id}\`
- \`GET/POST /iam/groups\`, \`GET/PUT/DELETE /iam/groups/{id}\`
- \`GET/POST /iam/groups/{id}/members\`, \`DELETE /iam/groups/{id}/members/{user_id}\`
- \`GET/POST /iam/domains\`, \`GET/DELETE /iam/domains/{id}\`, \`POST /iam/domains/{id}/verify\`

## 3. 域名验证

1. \`POST /iam/domains\` 生成随机 base64url token,**只存哈希**,明文仅在响应 \`verification_token\` 返回一次(TXT 记录值)。
2. \`POST /iam/domains/{id}/verify\` 携带明文 token,服务端用密码哈希校验器比对;匹配才置 \`verified=true\` 并写 \`verified_at\`。
3. 已验证、跨租户、错误 token 一律不修改记录(403/400/404)。

## 4. 租户隔离

所有 store 的 get/list 变体都带 tenant 谓词(\`getGroupForTenant\` 等),跨租户 ID 返回 null;成员添加时从 tenant-scoped group 解析 org_id,不接受客户端传入的 org。

## 5. 事件溯源(P1 同步落地)

- User 服务的 \`register\` / \`updateContact\` 等写操作在写入后追加不可变事件到 Event Store(\`user.registered\` / \`user.contact.updated\`)。
- \`users_activity\` 投影消费这些事件,生成独立的 JSON 数组查询模型(\`src/modules/eventstore/user_projection.zig\`),由定时任务推进 high-water mark。
- 事件追加失败仅告警、不影响主写入(best-effort);投影与可变的 user 表解耦。
