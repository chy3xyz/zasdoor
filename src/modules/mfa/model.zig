//! MFA / account-security domain model (dev.md V3).
//!
//! Entities:
//!   - TotpCredential    a user's TOTP secret (only stored base32-encoded;
//!                       marked Sensitive).
//!   - RecoveryCode      a single-use recovery code (only its hash is stored).
//!   - IdentityProvider  a federated login provider (OIDC/OAuth like Google,
//!                       GitHub) with JSON config.
//!   - MfaPolicy         per-tenant/setting: whether MFA is required.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const TotpCredential = Schema("TotpCredential", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("user_id"),
        field.String("secret").Sensitive(), // base32 secret
        field.Bool("enabled").Default(false),
        field.Int("verified_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

pub const RecoveryCode = Schema("RecoveryCode", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("user_id"),
        field.String("code_hash").Sensitive(),
        field.Bool("used").Default(false),
        field.Int("expires_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

pub const IdentityProvider = Schema("IdentityProvider", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.String("name"),
        field.String("provider_type").Default("oidc"), // oidc | oauth | github | google
        field.Text("config").Default("{}"), // JSON: {issuer, client_id, client_secret,...}
        field.Bool("enabled").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

pub const MfaPolicy = Schema("MfaPolicy", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Bool("require_mfa").Default(false),
        field.Bool("allow_recovery_codes").Default(true),
        field.Bool("allow_totp").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
