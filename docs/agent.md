# Agent 模块(机器身份与预算账本)

> 面向 AI Agent / 服务的机器身份:能力白名单、scope、按周期预算。
> 对应代码:`src/modules/agent/`(model → persistence → service → api)。

## 1. 概念

- **Agent**:一个机器身份,归属某个用户(`owner_user_id`),可配置:
  - `capabilities`:能力白名单(JSON 数组字符串,如 `["wallet.balance"]`)。
  - `scopes`:OAuth scope 白名单。
  - `budget`:每周期预算额度(0 = 不限)。
  - `budget_period_seconds`:预算周期(默认 86400s = 一天),周期滚动重置。
  - `expires_at`:过期时间(0 = 永不过期)。
- **AgentUsage**:预算账本,记录每个周期已用额度,按需**原子扣减**、可恢复。
- **Token**:签发 JWT,`sub=agent_<id>`、`actor=<owner>`、`budget_remaining`(有预算时)。

## 2. HTTP API(全部要求已登录 JWT)

| Method | Path | 说明 |
| --- | --- | --- |
| GET | `/api/v1/agents?page=&page_size=` | 分页列表(ruoyi 形状,可选 owner 过滤) |
| POST | `/api/v1/agents` | 创建 Agent |
| GET | `/api/v1/agents/{id}` | 详情 |
| POST | `/api/v1/agents/{id}/token` | 签发 Token(body 可选 `ttl` 秒) |
| POST | `/api/v1/agents/{id}/deactivate` | 停用(令牌随之失效) |
| POST | `/api/v1/agents/token/verify` | 校验 Token,返回 `{ valid, payload }`(需置于 `{id}` 路由之前注册) |

## 3. 预算账本语义

- 当前周期剩余 = `budget - used`;周期过期(now - period_start >= period)自动滚动重置。
- 消费走原子 UPDATE(防并发超支),返回新剩余额。
- 服务方在每次调用前检查 `budget_remaining`,不足拒绝(403 / 429)。
- 预算为 0 表示不限额,`budget_remaining` claim 不签发。

## 4. 安全要点

- Agent token 是普通 JWT,`sub` 前缀 `agent_` 便于审计区分人/机器。
- 停用后,`verify` 返回 `valid: false`;token 校验也会核对 agent 是否 active。
- 能力/scope 在服务调用链入口做白名单校验(service 层)。