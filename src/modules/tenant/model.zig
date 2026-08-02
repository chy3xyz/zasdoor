//! zent schema-as-code — tenant entity.
//!
//! Every isolated table carries a `tenant_id` column. `status` allows
//! soft-disable without cascading deletes: `active` | `disabled`.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Tenant = Schema("Tenant", .{
    .fields = &.{
        field.String("name"),
        field.String("status").Default("active"),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
