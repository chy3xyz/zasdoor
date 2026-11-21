//! Instance / Group / Domain domain model (dev.md sections 3-4).
//!
//! These are the domain layers that sit above the per-tenant Organization
//! rows already defined in `iam/model.zig`:
//!
//!   - Instance      one complete ZenaIAM deployment; carries system config,
//!                   SMTP settings, a signing-key reference and global domain.
//!   - Group         org-scoped named collection of users.
//!   - GroupMember   join row binding a user to a group (org-scoped).
//!   - Domain        org-scoped verified email/SSO domain. The verification
//!                   token is stored only as a hash; `verified_at` is set when
//!                   the token is matched by the service layer.
//!
//! All schemas share the existing multi-tenant (tenant_id) isolation and use
//! TimeMixin for created_at/updated_at, matching `iam/model.zig`.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

/// A complete ZenaIAM deployment (e.g. `iam.chy.xyz`): system configuration,
/// SMTP, security policy, signing keys, global domain and organizations.
pub const Instance = Schema("Instance", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.String("name"),
        field.String("display_name").Default(""),
        field.String("global_domain").Default(""),
        field.Bool("active").Default(true),
        // System configuration as a JSON text blob (SMTP host/port/user/pass,
        // security policy, etc.) so no secret column leaks as a plain field.
        field.Text("config_json").Default("{}"),
        // Reference into the OAuth/OIDC signing-key ring; the key material
        // itself is never stored here.
        field.String("signing_key_ref").Default(""),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// An organization-scoped group of users (dev.md section 4: Organization ->
/// Groups). `org_id` references iam.Organization.id; 0 means instance-wide.
pub const Group = Schema("Group", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("org_id").Default(0),
        field.String("name"),
        field.String("description").Default(""),
        field.Bool("active").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Membership edge between a user and a group, scoped to the same org/tenant.
pub const GroupMember = Schema("GroupMember", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("org_id").Default(0),
        field.Int("group_id"),
        field.Int("user_id"),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// An organization domain awaiting/after verification. `verification_token_hash`
/// stores only a hash of the challenge token; the plaintext is delivered out of
/// band (DNS TXT / email). `verified_at` is set (non-zero) only when the service
/// layer matches the presented token against the stored hash.
pub const Domain = Schema("Domain", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("org_id"),
        field.String("name"),
        field.Bool("verified").Default(false),
        field.String("verification_token_hash").Default("").Sensitive(),
        field.Int("verified_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
