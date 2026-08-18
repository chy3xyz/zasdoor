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
        field.Text("capabilities").Default("[]"), // JSON array, e.g. ["wallet.balance","swap.execute"]
        field.Text("scopes").Default("[]"), // JSON array, e.g. ["read:wallet","write:swap"]
        field.Int("budget").Default(0), // max units per period (0 = unlimited)
        field.Int("budget_period_seconds").Default(86400),
        field.Int("expires_at").Default(0), // 0 = never
        field.Bool("active").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
