//! AI Agent identity model (dev.md V4).

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Agent = Schema("Agent", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("owner_user_id"),
        field.String("name"),
        field.String("description").Default(""),
        field.Text("capabilities").Default("[]"),
        field.Text("scopes").Default("[]"),
        field.Int("budget").Default(0),
        field.Int("budget_period_seconds").Default(86400),
        field.Int("expires_at").Default(0),
        field.Bool("active").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Per-agent budget accounting ledger (one row per budget period).
pub const AgentUsage = Schema("AgentUsage", .{
    .fields = &.{
        field.Int("agent_id"),
        field.Int("period_start"),
        field.Int("used").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
