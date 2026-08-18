# Event Store 模块(事件存储)

> 追加式领域事件持久化 —— 审计与投影(projection)的基础设施。
> 对应代码:`src/modules/eventstore/`(model → persistence → service → module;无 HTTP API)。

## 1. 设计

- **追加式(append-only)**:事件只增不改,天然可审计、可回放。
- **聚合根**:事件按 `aggregate_type` + `aggregate_id` 归类,带单调递增 `sequence`。
- **元数据**:`event_type`、`payload`(JSON)、`created_at`、`actor`(操作者)。
- **无 HTTP 端点**:作为服务层供其它模块写事件、按聚合读取回放,或供未来 CQRS 投影使用。

## 2. 表结构(示意)

```
event_events
  id            INTEGER PRIMARY KEY AUTOINCREMENT
  tenant_id     INTEGER NOT NULL
  aggregate_type TEXT NOT NULL
  aggregate_id  INTEGER NOT NULL
  sequence      INTEGER NOT NULL
  event_type    TEXT NOT NULL
  payload       TEXT NOT NULL,   -- JSON
  actor_id      INTEGER
  created_at    INTEGER NOT NULL
```

## 3. 用法

- 业务模块在状态变更时追加事件(如 `user.registered`、`session.revoked`)。
- 审计模块可读取事件流补充 `audit_logs`(或直接作为审计源)。
- 支持按 `(aggregate_type, aggregate_id)` 顺序回放,重建聚合状态。

## 4. 扩展点

- 事件订阅器(projection worker)可消费新事件构建读模型。
- 如需跨进程广播,可接消息队列;当前为进程内同步写。