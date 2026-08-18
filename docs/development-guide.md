# Zasdoor 二次开发最佳实践

本文面向在 zasdoor 全栈管理框架上扩展业务模块的开发者。它记录本仓库
沉淀下来的架构约定、zent/zigmodu 用法、安全与性能规范,以及踩过的坑。

配套阅读:`docs/streaming.md`(AI 流式契约)、`docs/backup.md`(备份剧本)、
zent 仓库 `docs/BEST_PRACTICES.md`(ORM 层通用规范)。

---

## 1. 架构总览

```
HTTP 请求
  │
  ▼
api.zig(HTTP 路由/鉴权/参数绑定/DTO)   ← zigmodu.http
  │
  ▼
service.zig(领域逻辑/校验/编排)          ← 无 HTTP、无 SQL
  │
  ▼
persistence.zig(*Store: 全部 SQL)        ← zent builder / crud_helpers
  │
  ▼
zent codegen Client ──► sqlite / PostgreSQL
```

- 分层职责严格:**api 层做 HTTP 翻译,service 层做业务,persistence 层做数据**。
  新模块请保持同样的六文件骨架(见 §2),不要跨层写 SQL 或 HTTP。
- 后端每个模块是一个目录:`src/modules/<name>/`;前端对应
  `web/src/pages/<Name>.tsx` + `web/src/api/<domain>/`。
- 依赖关系:`api → service → persistence → zent`;模块间只通过
  service 的指针(见 §3 服务装配)协作,不直接共享 store。

---

## 2. 新增一个业务模块(分步)

### 2.1 骨架(与 user/task 模块同构)

```
src/modules/order/
  model.zig        zent schema-as-code:表/字段/索引/唯一约束
  persistence.zig  OrderStore + DTO(OrderRow / OrderListResult)+ 本模块 infos
  service.zig      领域服务(校验、编排),无 HTTP/SQL
  api.zig          pub fn OrderApi(comptime Service: type) type + registerRoutes
  module.zig       zigmodu.api.Module 元数据(生命周期钩子为 no-op)
  root.zig         barrel:pub const model/persistence/service/api/module
```

要点:

- `model.zig` 用 `zent.core.schema.Schema` 与 `zent.core.field.*` 定义表:

  ```zig
  const zent = @import("zent");
  const field = zent.core.field;
  const Schema = zent.core.schema.Schema;

  pub const Order = Schema("Order", .{
      .fields = &.{
          field.String("code"),
          field.Int("amount").Default(0),
          field.Int("tenant_id").Default(0),   // 多租户模块必须带
          field.String("status").Default("pending"),
      },
      .mixins = &.{zent.core.mixin.TimeMixin},  // created_at/updated_at 自动维护
      .indexes = &.{zent.core.index.Fields(&.{ "status", "created_at" })},
  });
  ```

  规则:时间字段一律用 `TimeMixin`,不手写;热查询路径建索引;
  唯一业务键(邮箱/模板 code/provider name)用 schema 唯一约束并在
  service 层处理 `error.UniqueViolation`(见 §5.3)。

- `persistence.zig` 头部按惯例导出:

  ```zig
  const schema = @import("../../schema.zig");
  pub const infos = zent.codegen.graph.buildGraph(&.{model.Order}).types;
  pub const Client = schema.Client;
  pub const OrderInfo = infos[0];
  ```

### 2.2 注册进 schema.zig

在 `src/schema.zig` 把新表加入对应 graph(或新建 graph):

```zig
const graph = zent.codegen.graph.buildGraph(&.{ tenant_model.Tenant, user_model.User, /* ... */ order_model.Order });
```

> 注意:zent `buildGraph` 单次调用有 comptime 分支配额,表多时拆多个
> graph(本项目拆了 3 个)并在 `pub const infos = graph.types ++ ...` 汇总,
> `Client` 由全量 infos 生成。跨表边(WithEdge)需在同 graph 内。

### 2.3 服务装配(main.zig 手工 DI)

在 `src/main.zig` 依次:初始化 Store → Service → 传入 Api 泛型:

```zig
var order_store = order.persistence.OrderStore.init(allocator, store_env.client);
var order_svc = order.service.OrderService.init(allocator, &order_store, ...);
// ...
var v1 = server.group("/api/v1");
try order.api.OrderApi(@TypeOf(order_svc)).init(&order_svc, ...).registerRoutes(&v1);
```

模块间依赖用显式指针注入(参考 `ai.service.SkillsRefs`,
main.zig:158-168);不要在模块内直接 `@import` 其他模块的 store 单例。

### 2.4 前端页面

1. `web/src/pages/Order.tsx` 写页面(SolidJS);
2. `web/src/api/order/{path,query,types,index}.ts` 封装后端 API
   (`path.ts` 集中 URL,基于 `APP_CONFIG.apiPrefix`;axios 实例在
   `api/client.ts`,自动带 Bearer、401 全局登出);
3. `web/src/index.tsx` 用 `lazy(() => import(...))` + `<Route>` 注册,
   `constants/routePath.ts` 加路径常量,`MainLayout` 侧边栏加菜单;
4. 管理页面包 `<AdminGate>`,登录页包 `<Protected>`。

### 2.5 注册模块元数据

`module.zig` 导出 `zigmodu.api.Module` 元数据并在 `main.zig` 传入
`Application.init`;HTTP 路由不进模块生命周期,由 main.zig 手工挂载
(这是本项目的既定模式)。

---

## 3. zent 使用规范(本仓库沉淀)

### 3.1 首选 crud_helpers(尽量别手搓 Query 生命周期)

| 需求 | 用 | 示例 |
|---|---|---|
| 按主键查单行 | `crud.get(accessor, id)` | `crud.get(client.order, id)` |
| 按谓词查单行 | `crud.first(accessor, preds)` | `crud.first(client.order, .{preds.codeEQ(...)})` |
| 最新一条 | `crud.latest(accessor, preds, "created_at")` | 取最近登录/最近 token |
| 存在性 | `crud.exists(accessor, preds)` | upsert 前判断 |
| 计数 | `crud.count(accessor, preds)` | 仪表盘统计 |
| 列表 | `crud.all(accessor, preds)` | 全量小表 |
| 分页+排序 | `crud.paginatedWithOptions(accessor, preds, opts, page, size)` | 见 §3.2 |
| 原子增减 | `crud.increment(accessor, "col", delta, preds)` | token_version、余额 |
| 事务 | `beginTx`(见 §3.4) | 多步写 |

统一在 `persistence.zig` 顶部 `const crud = zent.crud_helpers;`。

### 3.2 分页与可选谓词

- 固定谓词:`crud.paginatedWithOptions(client.x, .{preds.aEQ(...)}, .{ .sort_col = "created_at", .desc = true }, page, page_size)`,
  返回 `PageResult`(含 `total/page/page_size/total_pages`),用
  `result.deinit(infos, XInfo, allocator)` 释放 items。
- **可选谓词**:用动态 slice 构建(zent `Where` 支持 `[]sql.Predicate`):

  ```zig
  var preds_buf: [3]zent.sql.Predicate = undefined;
  var n_preds: usize = 0;
  if (status) |s| { preds_buf[n_preds] = preds.statusEQ(.{ .string = s }); n_preds += 1; }
  var result = try crud.paginatedWithOptions(client.x, preds_buf[0..n_preds], .{ .sort_col = "created_at", .desc = true }, page, page_size);
  ```

- **排序列永远白名单校验**(防排序注入):

  ```zig
  const sort_col_name: []const u8 = if (sort_col) |col| blk: {
      if (!std.mem.eql(u8, col, "name") and !std.mem.eql(u8, col, "created_at")) break :blk "created_at";
      break :blk col;
  } else "created_at";
  ```

  `paginatedWithOptions` 内部对非法列返回 `error.InvalidSortColumn`,所以
  白名单可以只做「回退列」,双保险。

### 3.3 内存契约(最容易出 bug 的地方)

- zent 结果全部是 **owned**:`first/get/latest` 返回的实体、`All/paginated`
  的 items 都要释放;字符串字段来自 store 的 allocator。
- 释放方式:`zent.codegen.deinitEntity(infos, XInfo, &entity, store.allocator)`
  (实体);`result.deinit(infos, XInfo, allocator)`(PageResult)。
- 本项目约定:persistence 层 `dupXxx(entity) → Row`(Row 自带
  `free(allocator)`),api 层只操作 Row;**Row 的 free 必须用 store 的
  allocator**,绝不能用 per-request arena(`ctx.allocator`)释放 gpa 分配
  ——Zig 0.17 的 arena free 是 no-op,会导致泄漏(本项目曾踩过,
  见 src/middleware/auth.zig 修复记录)。
- `crud.first` 的结果必须 `var` 声明 + `|*entity|` 捕获,`const` 会被
  `deinitEntity` 在编译期拒绝。

### 3.4 多步写必须开事务

两条以上写操作(含跨表)包进同一事务,失败整体回滚:

```zig
var tx = try zent.codegen.beginTx(schema.infos, self.client);
defer tx.deinit();           // 未 commit 时自动 ROLLBACK
{
    var d = tx.client.child.Delete(); ... // 事务内用 tx.client,不是 self.client
}
try tx.commit();
```

注意:`beginTx` 的 infos 必须与 client 匹配——本项目用全量
`schema.infos`(不是模块子图 infos)。事务回调方案 `crud.withTx`
对局部 struct 回调类型有兼容限制,本项目统一用手动 `beginTx/commit`。

### 3.5 查询聚合与类型

- `Sum` 返回 `f64`(zent v0.29.4 起),转整型用 `@intFromFloat(...)`,
  不要 `@intCast`。
- `Count` 返回 `i64`;`q.paged` / `paginatedWithOptions` 内部一次调用完成
  count + limit/offset。
- 大表深分页:OFFSET 分页是 O(n),增长表切 `crud.cursorPage`(keyset)。

---

## 4. 多租户与安全规范

- **tenant_id 贯穿数据层**:所有租户数据表带 `tenant_id` 列;查询/写入
  谓词强制带 `tenant_idEQ`。公开注册固定进入默认租户(租户指定仅走认证的
  管理端 `/users` 接口)——不要信任客户端 `X-Tenant-ID` 头。
- **JWT 凭证版本**:改密/踢下线通过 `bumpTokenVersion` 原子递增
  `token_version`;新增「逐请求校验 ver」的接口沿用
  `tokenVersionGuard` + `getTokenVersion` 列投影,不要拉全行。
- **敏感列投影**:只需个别列(密码哈希、token_version)时用
  `q.Select(&.{"col"})`,不要 `getById` 拉全行。
- **乐观锁**:条件更新(如任务 claim)必须检查影响行数:

  ```zig
  const affected = try upd.Save();
  if (affected == 0) { /* 被别人抢先,放弃/重试 */ }
  ```

- **错误分类**:zent 把唯一/非空/外键冲突映射为
  `error.UniqueViolation` 等;service 层捕获后转业务错误,避免「先查后插」
  的竞态与多余查询。
- **日志/审计**:管理操作(登录、注册、审批、导出)写平台审计
  `audit.log(...)`;敏感操作失败不要 `catch {}` 静默吞掉——至少
  `std.log.err` 或传播错误。

---

## 5. 性能注意事项

1. **索引**:凡有按某列过滤/排序的热路径,在 schema 加
   `index.Fields(&.{...})`(复合索引注意列顺序,等值在前、范围在后)。
2. **批量操作**:循环内逐条 `Update/Exec` 改 `WHERE id IN (...)` 一次
   (参考 task `requeueStale` 的待办);大批量插入用 `BulkInsert` /
   `crud.batchCreate`。
3. **N+1**:列表 + 每行查关联,改 zent `WithEdge`(同 graph 内)或一次
   `findByIds` 再内存分组。
4. **分页**:`audit_log`/`ai_run`/`notification` 这类增长表,深分页换
   `cursorPage`。
5. **编译期**:zig 本地 path 依赖缓存以 fingerprint 为键,升级 zigmodu/
   zent 后如遇「改了没生效」,用 `zig build --summary all` 确认是否
   重编译,必要时 `ZIG_GLOBAL_CACHE_DIR=/tmp/x` 强制全量。

---

## 6. 测试

- 入口 `src/tests.zig`(build.zig 的 test step,`zig build test`)。
- 用 `openMemory()`(SQLite `:memory:` + 全量迁移)起环境:

  ```zig
  test "order: ..." {
      const allocator = std.testing.allocator;
      var env = try openMemory(allocator);
      defer env.deinit();
      var store = order.persistence.OrderStore.init(allocator, env.client);
      // ... 断言
  }
  ```

- HTTP 层用 `zigmodu.http.Testkit.dispatch` 不开 socket,同套
  store/svc 装配后 `registerRoutes` 再 dispatch,断言状态码与响应体。
- 约定:
  - 新增持久化方法务必配往返断言(写入 → 读回 → 释放);
  - 引用未调用的函数不会触发其类型检查(Zig 延迟分析),新方法要么被
    调用、要么补测试,否则编译错误会被藏起来(本项目 `quotaForUser`
    曾因此被 `Sum→f64` 破坏而无人察觉);
  - 提交前 `zig fmt --check src/` + `zig build` + `zig build test`。

---

## 7. 常见陷阱速查

| 陷阱 | 正确做法 |
|---|---|
| arena 释放 gpa 分配 | Row.free 一律用 store.allocator |
| `@intCast(f64)` | 用 `@intFromFloat` |
| 条件更新不看行数 | 检查 `Save()/Exec()` 返回值,0 行即冲突 |
| 两步写无事务 | `beginTx` + `commit`,defer deinit 兜底回滚 |
| 排序列直接拼 SQL | schema 字段白名单 + `paginatedWithOptions` 二次校验 |
| `Where` 传动态 slice | zent ≥ v0.29.7 支持 `[]sql.Predicate`;旧版本用元组 |
| 升级依赖后缓存假象 | `--summary all` / 换 global cache 验证真实编译 |
| 敏感列全行读出 | `q.Select` 列投影 |
| 循环逐条写 | `IN (...)` 批量 / batchCreate |
| 未引用函数的编译错误 | 补测试激活该路径 |

---

## 8. 发版与 CI

- 三个构建产物:服务 `zig build run`、管理 CLI `zig build admin`
  (`create-admin --email ...`)、测试 `zig build test`。
- CI(.github/workflows/ci.yml)在 push main 时按
  `zig_ws/{zigmodu,zent}` 兄弟布局重建依赖后跑 fmt + build + test,
  以及前端 typecheck + build;发版前保证 CI 绿。
- 发版流程:更新 `CHANGELOG.md` → bump `build.zig.zon` version →
  `chore(release): vX.Y.Z` 提交 → `git tag vX.Y.Z` → push → 
  `gh release create`(notes 取 CHANGELOG)。
