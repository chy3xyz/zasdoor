//! OAuth2 / OIDC module test suite: asymmetric signing, JWKS, discovery
//! consistency and the consent gate. Pure unit tests plus one in-memory
//! store-backed consent flow test.
const std = @import("std");
const zigmodu = @import("zigmodu");
const db_mod = @import("../../db.zig");
const schema = @import("../../schema.zig");
const tenant = @import("../tenant/root.zig");
const user = @import("../user/root.zig");
const iam = @import("../iam/root.zig");
const keys = @import("keys.zig");
const jwt = @import("jwt.zig");
const service = @import("service.zig");
const api = @import("api.zig");

const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

fn p256KeyPair(seed_byte: u8) !EcdsaP256Sha256.KeyPair {
    var seed: [32]u8 = undefined;
    @memset(&seed, seed_byte);
    return EcdsaP256Sha256.KeyPair.generateDeterministic(seed);
}

/// Flip a bit in the payload segment (keeps base64 padding valid) so the
/// signature no longer matches while the JWS still parses structurally.
fn tamperPayload(token: []u8) void {
    const first_dot = std.mem.indexOfScalar(u8, token, '.').?;
    const idx = first_dot + 1;
    token[idx] = if (token[idx] == 'A') 'B' else 'A';
}

// ── Symmetric regression + deterministic derivation ───────────────────────

test "oauth keys: derivation is deterministic and kid is stable" {
    const a = keys.derive("stable-secret");
    const b = keys.derive("stable-secret");
    const c = keys.derive("different-secret");
    try std.testing.expectEqualStrings(a.kid(), b.kid());
    try std.testing.expect(!std.mem.eql(u8, a.kid(), c.kid()));

    const pa = a.publicKeyBytes();
    const pb = b.publicKeyBytes();
    const pc = c.publicKeyBytes();
    try std.testing.expectEqualSlices(u8, &pa, &pb);
    try std.testing.expect(!std.mem.eql(u8, &pa, &pc));
    try std.testing.expectEqual(jwt.SigningAlg.EdDSA, a.alg);
}

// ── Asymmetric sign / verify ──────────────────────────────────────────────

test "oauth jwt: EdDSA sign/verify round trip rejects tampering" {
    const allocator = std.testing.allocator;
    const signer = keys.derive("eddsa-secret");
    const token = try signer.sign(allocator, "{\"sub\":\"42\",\"iss\":\"https://idp.example\"}");
    defer allocator.free(token);

    const payload = try signer.verify(allocator, token);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"sub\":\"42\"") != null);
    try std.testing.expectEqual(jwt.SigningAlg.EdDSA, jwt.peekHeaderAlg(allocator, token).?);

    const tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    tamperPayload(tampered);
    try std.testing.expectError(error.InvalidSignature, signer.verify(allocator, tampered));

    const other = keys.derive("other-secret");
    try std.testing.expectError(error.InvalidSignature, other.verify(allocator, token));
}

test "oauth jwt: ES256 sign/verify round trip rejects tampering" {
    const allocator = std.testing.allocator;
    const kp = try p256KeyPair(9);
    const token = try jwt.signEs256(allocator, kp, "kid-es256", "{\"sub\":\"es256\"}");
    defer allocator.free(token);

    const payload = try jwt.verifyEs256(allocator, kp.public_key, token);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "es256") != null);
    try std.testing.expectEqual(jwt.SigningAlg.ES256, jwt.peekHeaderAlg(allocator, token).?);

    const tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    tamperPayload(tampered);
    try std.testing.expectError(error.InvalidSignature, jwt.verifyEs256(allocator, kp.public_key, tampered));
}

// ── JWKS / discovery ──────────────────────────────────────────────────────

test "oauth keys: JWKS exposes the public key and no private material" {
    const allocator = std.testing.allocator;
    const signer = keys.derive("jwks-secret");
    const json = try signer.jwksJson(allocator);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("keys").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const jwk = arr.items[0].object;
    try std.testing.expectEqualStrings("OKP", jwk.get("kty").?.string);
    try std.testing.expectEqualStrings("Ed25519", jwk.get("crv").?.string);
    try std.testing.expectEqualStrings("EdDSA", jwk.get("alg").?.string);
    try std.testing.expectEqualStrings("sig", jwk.get("use").?.string);
    try std.testing.expectEqualStrings(signer.kid(), jwk.get("kid").?.string);
    try std.testing.expect(jwk.get("x").?.string.len > 0);
    try std.testing.expect(jwk.get("d") == null);
    try std.testing.expect(jwk.get("k") == null);

    // The published "x" is exactly the base64url of the signer public key.
    const enc = std.base64.url_safe_no_pad.Encoder;
    const pk = signer.publicKeyBytes();
    var buf: [64]u8 = undefined;
    const n = enc.calcSize(pk.len);
    _ = enc.encode(buf[0..n], &pk);
    try std.testing.expectEqualStrings(buf[0..n], jwk.get("x").?.string);
}

test "oauth keys: ES256 JWK renders x and y with no private scalars" {
    const allocator = std.testing.allocator;
    const kp = try p256KeyPair(3);
    const json = try keys.es256PublicJwkJson(allocator, kp.public_key, "abcd1234abcd1234");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const jwk = parsed.value.object;
    try std.testing.expectEqualStrings("EC", jwk.get("kty").?.string);
    try std.testing.expectEqualStrings("P-256", jwk.get("crv").?.string);
    try std.testing.expectEqualStrings("ES256", jwk.get("alg").?.string);
    try std.testing.expect(jwk.get("x").?.string.len > 0);
    try std.testing.expect(jwk.get("y").?.string.len > 0);
    try std.testing.expect(jwk.get("d") == null);
    try std.testing.expect(jwk.get("k") == null);
}

test "oauth discovery: advertised alg matches the signer/JWKS alg" {
    const allocator = std.testing.allocator;
    const signer = keys.derive("discovery-secret");
    const jwks = try signer.jwksJson(allocator);
    defer allocator.free(jwks);
    const parsed_jwks = try std.json.parseFromSlice(std.json.Value, allocator, jwks, .{});
    defer parsed_jwks.deinit();
    const jwk_alg = parsed_jwks.value.object.get("keys").?.array.items[0].object.get("alg").?.string;

    const json = try api.discoveryJson(allocator, "https://idp.example", signer.alg.name());
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const algs = parsed.value.object.get("id_token_signing_alg_values_supported").?.array;
    try std.testing.expectEqual(@as(usize, 1), algs.items.len);
    try std.testing.expectEqualStrings(signer.alg.name(), algs.items[0].string);
    try std.testing.expectEqualStrings(jwk_alg, algs.items[0].string);
}

// ── Consent coverage (pure) ───────────────────────────────────────────────

test "oauth consent: scope coverage is exact-token based" {
    try std.testing.expect(service.scopesCovered("openid profile email", "openid"));
    try std.testing.expect(service.scopesCovered("openid profile email", "profile email"));
    try std.testing.expect(!service.scopesCovered("openid", "openid profile"));
    try std.testing.expect(!service.scopesCovered("openid", "open"));
    try std.testing.expect(!service.scopesCovered("", "openid"));
    try std.testing.expect(service.scopesCovered("openid", ""));
}

// ── Consent flow (in-memory store) ────────────────────────────────────────

fn openMemory(allocator: std.mem.Allocator) !db_mod.StoreEnv(schema.infos, .{
    tenant.persistence.infos,
    user.persistence.infos,
    iam.persistence.infos,
}) {
    return db_mod.StoreEnv(schema.infos, .{
        tenant.persistence.infos,
        user.persistence.infos,
        iam.persistence.infos,
    }).open(allocator, .sqlite, ":memory:");
}

test "oauth consent: authorize requires consent, then issues after grant" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "consent-secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    const uid = try user_store.createUser("Carol", "carol@example.com", "hash", false, true, 1, 100);

    const pid = try iam_svc.createProject(1, 0, "P", "");
    var creds = try iam_svc.createApplication(1, pid, "ConsentApp", "web", "[\"https://app.example/cb\"]", "[]", "[]", "[\"authorization_code\"]", "[\"code\"]", "openid profile email", 3600, 0, false);
    defer creds.deinit(allocator);

    var oauth_svc = service.OAuthService.init(allocator, std.testing.io, &iam_svc, &user_svc, &sec, "http://localhost:8080");
    const scope = "openid profile";

    // No stored consent -> consent_required, and no code is minted.
    const first = try oauth_svc.authorizeWithConsent(creds.client_id, "https://app.example/cb", "code", scope, "st", null, null, null, uid, false);
    switch (first) {
        .consent_required => |cr| {
            defer allocator.free(cr.scopes);
            try std.testing.expectEqualStrings(scope, cr.scopes);
        },
        .issued => |res| {
            allocator.free(res.code);
            allocator.free(res.redirect_uri);
            if (res.state) |st| allocator.free(st);
            return error.TestUnexpectedResult;
        },
    }

    // Explicit grant -> consent upserted and code issued.
    const second = try oauth_svc.authorizeWithConsent(creds.client_id, "https://app.example/cb", "code", scope, "st", null, null, null, uid, true);
    switch (second) {
        .consent_required => return error.TestUnexpectedResult,
        .issued => |res| {
            defer allocator.free(res.code);
            defer allocator.free(res.redirect_uri);
            defer if (res.state) |st| allocator.free(st);
            try std.testing.expect(res.code.len > 0);
        },
    }

    // Consent persisted: a later request needs no grant flag.
    const third = try oauth_svc.authorizeWithConsent(creds.client_id, "https://app.example/cb", "code", scope, null, null, null, null, uid, false);
    switch (third) {
        .consent_required => return error.TestUnexpectedResult,
        .issued => |res| {
            defer allocator.free(res.code);
            defer allocator.free(res.redirect_uri);
            defer if (res.state) |st| allocator.free(st);
        },
    }

    // A broader scope is not covered by the narrower stored consent.
    const fourth = try oauth_svc.authorizeWithConsent(creds.client_id, "https://app.example/cb", "code", "openid profile email", null, null, null, null, uid, false);
    switch (fourth) {
        .consent_required => |cr| allocator.free(cr.scopes),
        .issued => |res| {
            allocator.free(res.code);
            allocator.free(res.redirect_uri);
            if (res.state) |st| allocator.free(st);
            return error.TestUnexpectedResult;
        },
    }
}
