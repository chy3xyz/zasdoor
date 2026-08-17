//! ZenaIAM domain model - the ZITADEL-style identity/authorization kernel.
//!
//! Mirrors ZITADEL's Organization / Project / Application / Role hierarchy,
//! laid on top of zenaipa's existing multi-tenant (tenant_id) isolation.
//!
//! Entities:
//!   - Project          a product-level security boundary.
//!   - Application      an OAuth/OIDC client (client_id + client_secret).
//!   - Role             a project-scoped named permission group.
//!   - RoleAssignment   binds a user to a role within a project/organization.
//!   - Session          an independent user session (device/IP/UA/refresh).
//!   - AuthorizationCode  short-lived OAuth authorization code.
//!   - RefreshToken     long-lived OAuth refresh token (only hash stored).
//!   - Consent          a user's granted scopes for a client.
//!
//! This is one comptime graph so iam.persistence.infos registers all of
//! them in a single migrate group (keeping the store's per-graph branch
//! quota well under its limit, like the existing schema.zig design).

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

/// An Organization - the multi-tenant core (ZITADEL Organization). Projects
/// and users hang off an organization, forming the Instance->Organization->
/// Project hierarchy (dev.md section 3-4).
pub const Organization = Schema("Organization", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.String("name"),
        field.String("description").Default(""),
        field.String("domain").Default(""),
        field.Bool("active").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// A product-level security boundary (ZITADEL "Project"): applications,
/// API resources, roles and grants all hang off a project (and optionally an
/// organization).
pub const Project = Schema("Project", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("org_id").Default(0),
        field.String("name"),
        field.String("description").Default(""),
        field.Bool("active").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// An OAuth/OIDC client. client_id is a stable public identifier;
/// client_secret_hash stores only a hash (Sensitive), never the plaintext.
/// Application types follow ZITADEL: web | spa | native | machine.
pub const Application = Schema("Application", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("project_id"),
        field.String("name"),
        field.String("type").Default("web"), // web | spa | native | machine
        field.String("client_id").Unique(),
        field.String("client_secret_hash").Sensitive(),
        field.Text("redirect_uris").Default(""), // JSON array of strings
        field.Text("post_logout_redirect_uris").Default(""),
        field.Text("allowed_origins").Default(""), // JSON array
        field.Text("grant_types").Default(""), // JSON array
        field.Text("response_types").Default(""), // JSON array
        field.Text("scopes").Default(""), // space-separated
        field.Int("access_token_ttl").Default(3600),
        field.Int("refresh_token_ttl").Default(0), // 0 = no refresh
        field.Bool("pkce_required").Default(false),
        field.Bool("active").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// A project-scoped named role (ZITADEL project roles).
pub const Role = Schema("Role", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("project_id"),
        field.String("key"),
        field.String("name"),
        field.Text("permissions").Default(""), // JSON array
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Binds a user to a role within a project/organization.
pub const RoleAssignment = Schema("RoleAssignment", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("user_id"),
        field.Int("role_id"),
        field.Int("project_id").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// An independent user session (dev.md section 9): device, IP, UA, refresh.
/// Separating session from the JWT lets us revoke per device / per client /
/// "logout all sessions" without a single shared JWT secret.
pub const Session = Schema("Session", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("user_id"),
        field.Int("client_id").Default(0), // application id or 0 for password login
        field.String("device_id").Default(""),
        field.String("ip").Default(""),
        field.String("user_agent").Default(""),
        field.String("auth_method").Default("password"),
        field.Int("last_seen_at").Default(0),
        field.Int("expires_at"),
        field.Int("revoked_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Short-lived OAuth authorization code. code_hash stores only a hash;
/// code_challenge holds the PKCE S256 challenge when PKCE is used.
pub const AuthorizationCode = Schema("AuthorizationCode", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("application_id"),
        field.Int("user_id"),
        field.String("code_hash").Sensitive(),
        field.String("redirect_uri").Default(""),
        field.String("scope").Default(""),
        field.String("nonce").Default(""),
        field.String("code_challenge").Default(""), // PKCE S256 challenge (base64url)
        field.String("code_challenge_method").Default(""), // plain | S256 | ""
        field.Int("expires_at"),
        field.Int("used_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// Long-lived OAuth refresh token. Only the hash is stored (dev.md section 20).
pub const RefreshToken = Schema("RefreshToken", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("application_id"),
        field.Int("user_id"),
        field.Int("session_id").Default(0),
        field.String("token_hash").Sensitive(),
        field.String("scope").Default(""),
        field.Int("expires_at"),
        field.Int("revoked_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// A user's stored consent: which scopes were granted to which client.
pub const Consent = Schema("Consent", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("application_id"),
        field.Int("user_id"),
        field.String("scope").Default(""),
        field.Int("granted_at").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
