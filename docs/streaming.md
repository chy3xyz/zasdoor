# 流式聊天接入契约(Streaming Chat)

> 状态:**待上游**。zigmodu 的 `chatStream + DeltaBridge` 已用真实 DeepSeek API
> 验证(zigmodu v0.15.13,`7ac16c8`),但 Agent 主循环尚未切换(TODO #4,待
> SSE-capable mock harness)。zenaipa 的接入代码按本契约设计,上游落地后
> 按下列步骤 10 分钟内接通。

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

## zenaipa 接入步骤(上游 TODO #4 落地后)

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
- [ ] mock harness 可驱动 `requestStream`(上游阻塞点)
- [ ] zenaipa `zig build test` 通过后接 SSE 测试(Testkit 直连 chat 端点)
