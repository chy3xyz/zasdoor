//! zent schema-as-code — user domain for zenaipa.
//!
//! Mirrors pagoda's two entities (`User`, `PasswordToken`) with the same
//! semantics: email is unique + lowercased on write, password is stored
//! hashed (Sensitive), users may be admins and email-verified.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const User = Schema("User", .{
    .fields = &.{
        field.String("name"),
        field.String("email").Unique(),
        field.String("password").Sensitive(),
        field.Bool("verified").Default(false),
        field.Bool("admin").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

pub const PasswordToken = Schema("PasswordToken", .{
    .fields = &.{
        field.Int("user_id"),
        field.String("token").Sensitive(),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
