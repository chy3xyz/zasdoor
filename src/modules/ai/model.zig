//! zent schema-as-code — AI platform: providers (encrypted keys), chat
//! sessions/messages, human approvals and run audit.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

/// OpenAI-compatible provider configuration (admin-managed; keys encrypted).
pub const AiProvider = Schema("AiProvider", .{
    .fields = &.{
        field.String("name").Unique(),
        field.String("endpoint"),
        field.String("api_keys_encrypted").Default(""),
        field.String("models").Default(""),
        field.String("fallback_providers").Default(""),
        field.Bool("enabled").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// A chat session owned by one user (tenant-scoped).
pub const AiSession = Schema("AiSession", .{
    .fields = &.{
        field.Int("user_id"),
        field.Int("tenant_id").Default(1),
        field.String("title").Default(""),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// One message in a session (role: user / assistant / tool).
pub const AiMessage = Schema("AiMessage", .{
    .fields = &.{
        field.Int("session_id"),
        field.String("role").Default("user"),
        field.String("content").Default(""),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Human-in-the-loop approval queue for write skills (e.g. notify.send).
pub const AiApproval = Schema("AiApproval", .{
    .fields = &.{
        field.Int("session_id"),
        field.Int("requested_by"),
        field.String("skill_name").Default(""),
        field.String("args").Default(""),
        field.String("status").Default("pending"),
        field.Int("approved_by").Default(0),
        field.Int("approved_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Durable record of every agent/workflow run (metrics & audit).
pub const AiRun = Schema("AiRun", .{
    .fields = &.{
        field.Int("session_id").Default(0),
        field.Int("user_id"),
        field.Int("tenant_id").Default(1),
        field.String("kind").Default("chat"),
        field.String("prompt").Default(""),
        field.Int("tokens_in").Default(0),
        field.Int("tokens_out").Default(0),
        field.String("status").Default("ok"),
        field.String("err_msg").Default(""),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
