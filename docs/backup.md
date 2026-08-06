# 备份与恢复

zenaipa 的持久化数据分为三部分:

| 数据 | 位置 | 备份方式 |
| --- | --- | --- |
| 业务数据库 | `ZENAIPA_SQLITE_PATH`(默认 `zenaipa.db`)或 PostgreSQL | 见下方 |
| 上传文件 | `ZENAIPA_UPLOAD_DIR`(默认 `uploads/`) | 文件快照 |
| 运行数据 | 内存缓存(可重建)、任务队列(在 DB 内) | 随 DB 备份 |

## SQLite

SQLite 支持**在线一致性备份**(无需停服,使用 `sqlite3` 的 backup API 或 `.backup` 命令):

```bash
# 在线备份(推荐,一致性快照)
sqlite3 zenaipa.db ".backup 'backups/zenaipa-$(date +%F).db'"

# 或停止服务后直接复制文件
cp zenaipa.db backups/zenaipa-$(date +%F).db
cp -r uploads backups/uploads-$(date +%F)
```

> 不要直接 `cp` 正在写入的 .db 文件——可能得到不一致副本。优先 `.backup`。

## PostgreSQL

```bash
pg_dump "$ZENAIPA_PG_CONNINFO" -Fc -f backups/zenaipa-$(date +%F).dump
pg_restore -d zenaipa_new backups/zenaipa-*.dump
```

## 恢复

1. **停服**(或对 PG 使用在线恢复)。
2. 恢复数据库文件/转储与 `uploads/` 目录。
3. 启动 `zenaipa`;启动时 schema 迁移是幂等的,不会破坏已有数据。

## 建议的备份节奏

| 项 | 频率 | 保留 |
| --- | --- | --- |
| 数据库 | 每日(夜间低峰) | 30 天 |
| uploads | 每日增量 + 每周全量 | 30 天 |
| 配置(环境变量清单) | 随代码库 | 永久 |

## 运维清单(生产)

- 设置 `ZENAIPA_JWT_SECRET`、`ZENAIPA_AI_KEY_SECRET`(缺少时 PostgreSQL 模式拒绝启动)。
- 限制 `/metrics` 到监控网段:`ZENAIPA_METRICS_ALLOW_IPS=10.0.0.0/8`(注意当前为精确 IP 匹配)。
- 审计日志按 `ZENAIPA_AUDIT_RETENTION_DAYS`(默认 180 天)自动清理;如需归档,在清理前导出 CSV。
- 容器部署:`docker build` 后挂载 `/data` 卷(DB + uploads),SIGTERM 会自动优雅排空在途请求。
