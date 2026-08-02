//! zent schema-as-code — background task queue (backlite-style).
//!
//! `Task` rows are durable work items: `pending` rows are claimed by the
//! dispatcher, retried with backoff up to `max_attempts`, and end in
//! `done` / `failed` / `canceled`.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Task = Schema("Task", .{
    .fields = &.{
        field.String("name"),
        field.String("payload").Default(""),
        field.String("status").Default("pending"),
        field.Int("tenant_id").Default(0),
        field.Int("attempts").Default(0),
        field.Int("max_attempts").Default(3),
        field.String("last_error").Default(""),
        field.Int("available_at").Default(0),
        field.Int("started_at").Default(0),
        field.Int("finished_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
