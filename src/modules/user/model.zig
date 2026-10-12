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
        // OIDC phone / address scope 数据源(空 = 不输出对应 claim)。
        field.String("phone").Default(""),
        field.String("address").Default(""),
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

/// Failed-login lockout state, keyed by normalized email.
///
/// Persisted in the data store (not an in-process hash map) so every instance
/// in a multi-instance deployment shares the same counters and cooldowns.
pub const LoginAttempt = Schema("LoginAttempt", .{
    .fields = &.{
        // "key" is a SQL reserved word on some dialects; use lock_key.
        field.String("lock_key").Unique(),
        field.Int("failures").Default(0),
        field.Int("window_start").Default(0),
        field.Int("locked_until").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
