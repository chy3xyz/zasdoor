//! zent schema-as-code — configurable email templates (verification, reset).

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const EmailTemplate = Schema("EmailTemplate", .{
    .fields = &.{
        field.String("code").Unique(),
        field.String("subject").Default(""),
        field.String("body").Default(""),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
