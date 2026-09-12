//! MFA / IdP module test suite.
//!
//! Federated login is exercised end-to-end without any network: config
//! parsing, single-use state validation (unknown / expired / replayed),
//! userinfo / id_token extraction, and find-or-create + identity linking
//! against an in-memory SQLite store.
const std = @import("std");
const db_mod = @import("../../db.zig");
const schema = @import("../../schema.zig");
const user_mod = @import("../user/root.zig");
const persist = @import("persistence.zig");
const idp = @import("idp.zig");

/// Minimal in-memory store helper (same shape as src/tests.zig openMemory,
/// but only migrates the schema groups this module touches).
fn openMemory(allocator: std.mem.Allocator) !db_mod.StoreEnv(schema.infos, .{
    user_mod.persistence.infos,
    persist.infos,
}) {
    return db_mod.StoreEnv(schema.infos, .{
        user_mod.persistence.infos,
        persist.infos,
    }).open(allocator, .sqlite, ":memory:");
}

const sample_config = "{\"name\":\"Google\",\"type\":\"oidc\",\"authorize_url\":\"https://accounts.google.com/o/oauth2/v2/auth\",\"token_url\":\"https://oauth2.googleapis.com/token\",\"userinfo_url\":\"https://openidconnect.googleapis.com/v1/userinfo\",\"client_id\":\"abc123\",\"client_secret\":\"s3cr3t\",\"redirect_uri\":\"https://idp.local/cb\",\"scope\":\"openid profile email\"}";

test "mfa idp: config parsing keeps token/userinfo fields" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = persist.MfaStore.init(allocator, env.client);
    var svc = idp.IdpService.init(allocator, &store);

    const cfg = try svc.parseConfig(sample_config);
    defer svc.freeConfig(cfg);
    try std.testing.expectEqualStrings("Google", cfg.name);
    try std.testing.expectEqualStrings("oidc", cfg.provider_type);
    try std.testing.expectEqualStrings("abc123", cfg.client_id);
    try std.testing.expectEqualStrings("s3cr3t", cfg.client_secret);
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", cfg.token_url);
    try std.testing.expectEqualStrings("https://openidconnect.googleapis.com/v1/userinfo", cfg.userinfo_url);
    try std.testing.expectEqualStrings("https://idp.local/cb", cfg.redirect_uri);

    // Missing required fields / non-JSON -> InvalidConfig.
    try std.testing.expectError(error.InvalidConfig, svc.parseConfig("{\"name\":\"x\"}"));
    try std.testing.expectError(error.InvalidConfig, svc.parseConfig("not json"));

    // Old link-only configs still parse; network fields default to empty.
    const legacy = try svc.parseConfig("{\"authorize_url\":\"https://a/auth\",\"client_id\":\"c\",\"redirect_uri\":\"https://a/cb\"}");
    defer svc.freeConfig(legacy);
    try std.testing.expectEqualStrings("", legacy.token_url);
    try std.testing.expectEqualStrings("", legacy.userinfo_url);
    try std.testing.expectEqualStrings("oidc", legacy.provider_type);

    const url = try svc.buildAuthorizeUrl(sample_config, "st1", null);
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=st1") != null);
}

test "mfa idp: state accepts fresh, rejects unknown/expired/replayed" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = persist.MfaStore.init(allocator, env.client);
    var svc = idp.IdpService.init(allocator, &store);

    const id = try svc.create(1, "Google", "oidc", sample_config, 100);

    // Pure validation for all three rejection modes.
    try std.testing.expectError(error.UnknownState, idp.validateStateRow(null, 100));
    const used = persist.FederatedStateRow{ .id = 1, .tenant_id = 1, .provider_id = id, .state = "s", .redirect_to = "", .expires_at = 1000, .used = true };
    try std.testing.expectError(error.ReusedState, idp.validateStateRow(used, 100));
    const expired = persist.FederatedStateRow{ .id = 2, .tenant_id = 1, .provider_id = id, .state = "s", .redirect_to = "", .expires_at = 100, .used = false };
    try std.testing.expectError(error.ExpiredState, idp.validateStateRow(expired, 100));

    // Unknown state via the store-backed consumer.
    try std.testing.expectError(error.UnknownState, svc.consumeState(id, "nope", 100));

    // startLogin persists a TTL-bounded, unused state and an authorize URL.
    const started = try svc.startLogin(std.testing.io, 1, id, "", 100, 600);
    defer started.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, started.authorize_url, "state=") != null);
    const row = (try store.findFederatedState(started.state)).?;
    defer row.free(allocator);
    try std.testing.expectEqual(@as(i64, 700), row.expires_at);
    try std.testing.expect(!row.used);

    // Fresh consume succeeds and is single-use.
    const consumed = try svc.consumeState(id, started.state, 101);
    defer consumed.free(allocator);
    try std.testing.expectEqual(id, consumed.provider_id);
    try std.testing.expectError(error.ReusedState, svc.consumeState(id, started.state, 102));

    // Expired state rejected at the boundary.
    _ = try store.createFederatedState(1, id, "expired-state", "", 200, 100);
    try std.testing.expectError(error.ExpiredState, svc.consumeState(id, "expired-state", 200));

    // A state minted for this provider is rejected when presented at another.
    const other = try svc.create(1, "GitHub", "oauth", sample_config, 100);
    const started2 = try svc.startLogin(std.testing.io, 1, id, "", 300, 600);
    defer started2.deinit(allocator);
    try std.testing.expectError(error.UnknownState, svc.consumeState(other, started2.state, 301));
}

test "mfa idp: userinfo JSON -> (sub,email) extraction" {
    const allocator = std.testing.allocator;
    const info = try idp.parseUserInfoJson(allocator, "{\"sub\":\"u-123\",\"email\":\"a@b.c\",\"name\":\"Alice\"}");
    defer info.free(allocator);
    try std.testing.expectEqualStrings("u-123", info.subject);
    try std.testing.expectEqualStrings("a@b.c", info.email);
    try std.testing.expectEqualStrings("Alice", info.name);

    // Aliases: id + preferred_username; missing email -> empty.
    const alt = try idp.parseUserInfoJson(allocator, "{\"id\":\"42\",\"preferred_username\":\"bob\"}");
    defer alt.free(allocator);
    try std.testing.expectEqualStrings("42", alt.subject);
    try std.testing.expectEqualStrings("bob", alt.name);
    try std.testing.expectEqualStrings("", alt.email);

    try std.testing.expectError(error.MissingSubject, idp.parseUserInfoJson(allocator, "{\"email\":\"x@y.z\"}"));
    try std.testing.expectError(error.UserInfoFailed, idp.parseUserInfoJson(allocator, "[]"));

    // id_token claims are the base64url-decoded JWT payload.
    const payload = "{\"sub\":\"oidc-1\",\"email\":\"o@x.y\"}";
    const enc = std.base64.url_safe_no_pad.Encoder;
    const b64 = try allocator.alloc(u8, enc.calcSize(payload.len));
    defer allocator.free(b64);
    _ = enc.encode(b64, payload);
    var jwt = std.ArrayList(u8).empty;
    defer jwt.deinit(allocator);
    try jwt.appendSlice(allocator, "header.");
    try jwt.appendSlice(allocator, b64);
    try jwt.appendSlice(allocator, ".sig");
    const claims = try idp.parseIdTokenClaims(allocator, jwt.items);
    defer claims.free(allocator);
    try std.testing.expectEqualStrings("oidc-1", claims.subject);
    try std.testing.expectEqualStrings("o@x.y", claims.email);

    // Malformed id_token is rejected, not crashed on.
    try std.testing.expectError(error.UserInfoFailed, idp.parseIdTokenClaims(allocator, "not-a-jwt"));
}

test "mfa idp: find-or-create + identity link (in-memory store)" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = persist.MfaStore.init(allocator, env.client);
    var user_store = user_mod.persistence.UserStore.init(allocator, env.client);
    var svc = idp.IdpService.init(allocator, &store);

    const id = try svc.create(1, "Google", "oidc", sample_config, 100);

    // Pure decision table.
    try std.testing.expectEqual(idp.ProvisionAction.reuse_link, idp.decideProvision(7, 9));
    try std.testing.expectEqual(idp.ProvisionAction.link_existing, idp.decideProvision(null, 9));
    try std.testing.expectEqual(idp.ProvisionAction.create_user, idp.decideProvision(null, null));

    // New subject -> a local account is created and linked.
    const info = idp.UserInfo{ .subject = "sub-1", .email = "new@example.com", .name = "New User" };
    const uid1 = try svc.resolveLocalUser(1, id, info, 200);
    const link = (try store.findIdentityLink(id, "sub-1")).?;
    defer link.free(allocator);
    try std.testing.expectEqual(uid1, link.user_id);
    try std.testing.expectEqualStrings("new@example.com", link.email);
    const created = (try user_store.getUserById(uid1)).?;
    defer created.free(allocator);
    try std.testing.expectEqualStrings("new@example.com", created.email);
    try std.testing.expectEqualStrings("New User", created.name);
    try std.testing.expect(created.verified);

    // Same subject again -> the link is reused, no duplicate user.
    const uid1_again = try svc.resolveLocalUser(1, id, info, 201);
    try std.testing.expectEqual(uid1, uid1_again);
    const links = try store.listIdentityLinksByUser(uid1);
    defer {
        for (links) |l| l.free(allocator);
        allocator.free(links);
    }
    try std.testing.expectEqual(@as(usize, 1), links.len);

    // Different subject + matching email -> linked to the existing account.
    const existing_uid = try user_store.createUser("Existing", "existing@example.com", "hash", true, false, 1, 210);
    const info2 = idp.UserInfo{ .subject = "sub-2", .email = "existing@example.com", .name = "Existing" };
    const uid2 = try svc.resolveLocalUser(1, id, info2, 211);
    try std.testing.expectEqual(existing_uid, uid2);
    const link2 = (try store.findIdentityLink(id, "sub-2")).?;
    defer link2.free(allocator);
    try std.testing.expectEqual(existing_uid, link2.user_id);

    // No email from the provider -> a synthetic local account is still made.
    const info3 = idp.UserInfo{ .subject = "sub-3", .email = "", .name = "NoMail" };
    const uid3 = try svc.resolveLocalUser(1, id, info3, 220);
    const link3 = (try store.findIdentityLink(id, "sub-3")).?;
    defer link3.free(allocator);
    try std.testing.expectEqual(uid3, link3.user_id);
    try std.testing.expectEqualStrings("", link3.email);
    const anon = (try user_store.getUserById(uid3)).?;
    defer anon.free(allocator);
    try std.testing.expect(std.mem.startsWith(u8, anon.email, "federated+"));
}

test "mfa idp: form encoding escapes reserved characters" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try idp.appendFormValue(allocator, &buf, "a b&c=d/e?f");
    try std.testing.expectEqualStrings("a+b%26c%3Dd%2Fe%3Ff", buf.items);
}
