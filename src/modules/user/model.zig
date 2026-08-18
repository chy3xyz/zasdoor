//! zent schema-as-code — user domain for zasdoor.
//!
//! User-domain entities: `User`, `PasswordToken`, `EmailVerification`.
//! Email is unique + lowercased on write, password is stored hashed
//! (Sensitive), users may be admins and email-verified.

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
        field.Int("tenant_id").Default(1),
        // 凭证版本:改密/踢下线时递增,旧 JWT(ver 更小)立即失效。
        field.Int("token_version").Default(0),
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

/// One-time email-verification token. Only the hash is stored.
pub const EmailVerification = Schema("EmailVerification", .{
    .fields = &.{
        field.Int("user_id"),
        field.String("token").Sensitive(),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
