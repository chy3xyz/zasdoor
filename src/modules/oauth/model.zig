//! OAuth2 / OIDC domain types.
//!
//! Persistent OAuth entities (AuthorizationCode, RefreshToken, Consent) live
//! in the `iam` model and are accessed through IamService. This module owns
//! the in-memory protocol types: token responses and claim sets.

/// Standard OIDC scopes (dev.md section 7).
pub const default_scopes = "openid profile email offline_access";

/// A decoded/constructed token result handed to the API layer.
pub const TokenResult = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    refresh_token: ?[]const u8,
    id_token: ?[]const u8,
    scope: []const u8,
};

/// The parsed OIDC ID-token / access-token claim set.
pub const Claims = struct {
    iss: []const u8,
    sub: []const u8,
    aud: []const u8,
    exp: i64,
    iat: i64,
    nonce: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    azp: ?[]const u8 = null,
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    name_key: ?[]const u8 = null,
};
