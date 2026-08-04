//! zent schema-as-code — admin audit log (who did what, when, from where).

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const AuditLog = Schema("AuditLog", .{
    .fields = &.{
        field.Int("actor_user_id"),
        field.String("actor_name").Default(""),
        field.String("action"),
        field.String("target_type").Default(""),
        field.Int("target_id").Default(0),
        field.String("detail").Default(""),
        field.String("ip").Default(""),
        field.Bool("success").Default(true),
        field.Int("tenant_id").Default(1),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
