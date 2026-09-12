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

/// Binds a local user to a federated identity: the external provider's
/// stable `subject` (OIDC `sub`) for a given provider. One local user may
/// have links to several providers; the (provider_id, subject) pair is the
/// external identity key used at login time.
pub const IdentityLink = Schema("IdentityLink", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("provider_id"),
        field.Int("user_id"),
        field.String("subject"),
        field.String("email").Default(""),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Single-use anti-CSRF `state` for a federated login attempt. Persisted so
/// the callback can validate and consume it exactly once before the code is
/// exchanged. `used` is flipped on consumption (replay -> ReusedState);
/// `expires_at` bounds the attempt's lifetime.
pub const FederatedState = Schema("FederatedState", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("provider_id"),
        field.String("state").Unique(),
        field.String("redirect_to").Default(""),
        field.Int("expires_at"),
        field.Bool("used").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
