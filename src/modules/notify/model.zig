//! zent schema-as-code — per-user notifications (flash messaging, task
//! completion events, system alerts).

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Notification = Schema("Notification", .{
    .fields = &.{
        field.Int("user_id"),
        field.String("title"),
        field.String("body").Default(""),
        field.Bool("read").Default(false),
        field.String("kind").Default("info"),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
