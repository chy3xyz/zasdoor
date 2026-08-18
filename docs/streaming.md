# 流式聊天接入契约(Streaming Chat)

> 状态:**已落地**。zigmodu v0.15.16(`e7cf9df`)修复 `requestStream` 本地路径并
> 完成 Agent 流式切换(TODO #4);zasdoor 已按本契约接入(后端 SSE + 前端打字机)。
>
> **v0.15.18 补丁(`b28444a`)**:`SkillRegistry.toOpenAiFunctionsAlloc` 曾为每个
> 工具多输出一个 `}` 使 tools JSON 非法,DeepSeek/OpenAI 以 HTTP 400 拒绝 → 流式
> chat 出现 `ProviderError`。上游已修复(闭合改为 `]}}}`),zasdoor 的工具 schema
> 全量走 `SkillRegistry`,无需改动即恢复;上游测试新增 `std.json` 解析守卫。
>
> **关键澄清(消除误解)**:流式切换**不影响工具决策**——`chatStream` 内部先聚合
> 完整 `ChatResponse`(含 `tool_calls`)再返回,Agent 拿到的与 `chatWith` 完全同构
> (已验证 `content matches: YES`)。流式是"旁路推送 delta + 完整聚合决策"并行,
> 不是"边流边决策"。
>
> **唯一阻塞是测试基建,且已定位为框架 bug 候选**:`requestStream` 对本地 HTTP
> (非 TLS)连接读取挂起(真实 HTTPS 正常)——不是 mock 写法问题(4 种写法均复现)。
> 待上游修复 `requestStream` 本地路径后,Agent 切换(3-5 行)与 zasdoor 接入即可落地。

## 契约(SSE 事件流)

`POST /api/v1/ai/sessions/{id}/chat`(保持现有请求体 `{ content }`)改为:

```
Content-Type: text/event-stream

event: reasoning
data: <思考链增量片段>          # DeepSeek-R1/Qwen 等推理模型

event: delta
data: <正文增量片段>

event: tool
data: {"name":"...","arguments":"<半截 JSON>"}   # 技能调用(可选)

event: done
data: {"answer":"<完整回答>","reasoning_content":"<完整推理>","budget_exhausted":false}
```

- 与现有非流式响应**完全兼容**的 `done` 事件携带完整结果(落库用)。
- 断流/失败降级:前端未收到 `done` 即按现有 JSON 路径重试或展示错误。

## zasdoor 接入步骤(上游 TODO #4 落地后)

### 1. `src/modules/ai/service.zig` — 给 Agent 挂 `hooks.on_delta`

`chat()` 构造 Agent 时:

```zig
const ChatStreamCtx = struct { session_id: i64 };
var stream_ctx = ChatStreamCtx{ .session_id = session_id };
agent.hooks = .{
    .ctx = &stream_ctx,
    .on_delta = struct {
        fn onDelta(_: ?*anyopaque, delta: zigmodu.ai.AiProvider.StreamDelta) anyerror!void {
            // 经 Sse writer 推送(见步骤 2);当前可先转发到内存队列。
            _ = delta;
        }
    }.onDelta,
};
```

`AgentHooks.on_delta`(`zigmodu/src/ai/agent.zig:73`)签名已确认:
`fn (?*anyopaque, AiProvider.StreamDelta) anyerror!void`,delta 含
`content_delta` / `reasoning_delta` / `tool_name` / `tool_arguments_delta` / `done`。

### 2. `src/modules/ai/api.zig` — chat 端点改 SSE

- 响应头 `Content-Type: text/event-stream`、`Cache-Control: no-cache`。
- 用 zigmodu `http.Sse`(`zigmodu/http/Sse.zig`)writer。
- `agent.run` 同步执行期间,`on_delta` 推送到 Sse writer;run 结束后发 `done`。
- 现有逻辑保持:消息落库(user/assistant 带完整 answer + reasoning)、`touchSession`、
  配额/Bulkhead/run 审计不变。

### 3. `web/src/pages/AiChat.tsx` — 消费 SSE

- 发送后改用 `fetch` 流式读取(`ReadableStream`/`EventSource` POST 限制需用 fetch)。
- 渲染:推理过程块**实时追加**、正文**打字机效果**。
- `done` 事件落库后刷新消息列表(与现有逻辑一致)。
- 保留现有一次性 JSON 路径作为降级。

## 前置检查

- [ ] zigmodu Agent 主循环 `chatWith → chatStream + DeltaBridge` 已切换(`agent.zig` 无 `TODO(#4)`)
- [ ] zigmodu `requestStream` 本地(非 TLS)路径修复(框架 bug 候选;真实 HTTPS 已验证正常)
- [ ] Agent 主循环切换后 `on_delta` 触发;Testkit 增加 SSE 直连测试
- [ ] zasdoor `zig build test` 通过后接 SSE 测试(Testkit 直连 chat 端点)
