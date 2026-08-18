//! Event Store domain model - the system's append-only source of records.
//!
//! Event-sourcing model (dev.md section 14): every state
//! change is an immutable event appended to one aggregate's stream, guarded by
//! optimistic concurrency (aggregate_version). Projections replay these events
//! to build query models.
//!
//! Entities:
//!   - Event           one immutable fact appended to an aggregate stream.
//!   - EventPosition   per-projection high-water mark (which sequence each
//!                     projection has consumed).
//!   - ProjectionState the persisted state of a projection (cursor + blob).

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

/// An immutable fact on an aggregate's event stream.
/// sequence is a global monotonic row id; aggregate_version is the
/// per-aggregate optimistic-concurrency counter.
pub const Event = Schema("Event", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.String("aggregate_type"),
        field.String("aggregate_id"),
        field.Int("aggregate_version"),
        field.String("event_type"),
        field.Text("payload").Default("{}"), // JSON
        field.Text("metadata").Default("{}"), // JSON
        field.Int("actor_id").Default(0),
    },
    .indexes = &.{
        zent.core.index.Fields(&.{ "aggregate_type", "aggregate_id" }),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// High-water mark: the latest event sequence a projection has consumed.
pub const EventPosition = Schema("EventPosition", .{
    .fields = &.{
        field.String("position_name"), // e.g. users_projection
        field.Int("last_sequence").Default(0),
        field.Int("processed_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Persistent state of a projection (its cursor + arbitrary blob).
pub const ProjectionState = Schema("ProjectionState", .{
    .fields = &.{
        field.String("name"),
        field.String("json_blob").Default("{}"),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
