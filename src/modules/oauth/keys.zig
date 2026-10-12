//! Deterministic asymmetric signing keys for OIDC.
//!
//! Third-party clients verify ID tokens against the public JWKS, so the
//! signing key must be stable across process restarts. Rather than adding a
//! new config knob, the Ed25519 key is derived deterministically from the
//! platform JWT secret with HKDF-SHA256: same secret -> same key, forever.
//!
//! The key identifier ("kid") is the first 8 bytes of SHA-256 over the public
//! key, hex encoded. Private material is never rendered as a JWK.

const std = @import("std");
const jwt = @import("jwt.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

/// Fixed HKDF info string; changing it rotates every derived key.
pub const eddsa_info = "zasdoor-oidc-ed25519-signing-key-v1";

pub const Error = error{
    OutOfMemory,
};

/// A deterministic Ed25519 signer plus its public JWK metadata.
pub const Signer = struct {
    key_pair: Ed25519.KeyPair,
    alg: jwt.SigningAlg = .EdDSA,
    kid_buf: [16]u8,

    /// Hex key id (16 chars = first 8 bytes of SHA-256(public key)).
    pub fn kid(self: *const Signer) []const u8 {
        return self.kid_buf[0..];
    }

    /// Sign a serialized JSON payload into a compact EdDSA JWT.
    pub fn sign(self: *const Signer, allocator: std.mem.Allocator, payload_json: []const u8) ![]const u8 {
        return jwt.signEdDsa(allocator, self.key_pair, self.kid(), payload_json);
    }

    /// Verify a compact EdDSA JWT and return the owned payload bytes.
    pub fn verify(self: *const Signer, allocator: std.mem.Allocator, token: []const u8) jwt.Error![]const u8 {
        return jwt.verifyEdDsa(allocator, self.key_pair.public_key, token);
    }

    /// The raw 32-byte Ed25519 public key.
    pub fn publicKeyBytes(self: *const Signer) [Ed25519.PublicKey.encoded_length]u8 {
        return self.key_pair.public_key.toBytes();
    }

    /// Render the public JWK (never includes private material).
    pub fn publicJwkJson(self: *const Signer, allocator: std.mem.Allocator) ![]const u8 {
        return ed25519PublicJwkJson(allocator, self.publicKeyBytes(), self.kid());
    }

    /// Render the complete JWKS document: {"keys":[ <public JWK> ]}.
    pub fn jwksJson(self: *const Signer, allocator: std.mem.Allocator) ![]const u8 {
        const jwk = try self.publicJwkJson(allocator);
        defer allocator.free(jwk);
        return std.fmt.allocPrint(allocator, "{{\"keys\":[{s}]}}", .{jwk});
    }
};

/// Derive the deterministic signer from the platform JWT secret.
pub fn derive(secret: []const u8) Signer {
    var seed: [32]u8 = undefined;
    deriveSeed(secret, eddsa_info, &seed);
    return fromSeed(seed);
}

/// Maximum number of keys in the ring (current + previous for rotation).
pub const max_keys = 4;

/// A ring of Ed25519 signers for key rotation.
///
/// Index 0 is the *current* signing key; every key in the ring is published in
/// the JWKS and accepted for verification. Rotating therefore means prepending
/// the new secret and keeping the old one for at least one token lifetime, so
/// tokens signed before the rotation still verify during the overlap window.
pub const KeyRing = struct {
    signers: [max_keys]Signer = undefined,
    count: usize = 0,

    /// The key used for new signatures.
    pub fn current(self: *const KeyRing) *const Signer {
        return &self.signers[0];
    }

    /// Signing algorithm advertised by the current key.
    pub fn alg(self: *const KeyRing) jwt.SigningAlg {
        return self.signers[0].alg;
    }

    /// Sign with the current key.
    pub fn sign(self: *const KeyRing, allocator: std.mem.Allocator, payload_json: []const u8) ![]const u8 {
        return self.signers[0].sign(allocator, payload_json);
    }

    /// Verify against every key in the ring (rotation overlap).
    pub fn verify(self: *const KeyRing, allocator: std.mem.Allocator, token: []const u8) jwt.Error![]const u8 {
        var last_err: jwt.Error = error.InvalidSignature;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.signers[i].verify(allocator, token)) |payload| {
                return payload;
            } else |err| {
                last_err = err;
            }
        }
        return last_err;
    }

    /// Render the complete JWKS document with every public key in the ring.
    pub fn jwksJson(self: *const KeyRing, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"keys\":[");
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (i > 0) try buf.append(allocator, ',');
            const jwk = try self.signers[i].publicJwkJson(allocator);
            defer allocator.free(jwk);
            try buf.appendSlice(allocator, jwk);
        }
        try buf.appendSlice(allocator, "]}");
        return buf.toOwnedSlice(allocator);
    }
};

/// Build a key ring: the primary secret is the current signer, then up to
/// max_keys-1 extra secrets from a comma-separated list (older keys, kept for
/// verification during rotation).
pub fn deriveRing(primary: []const u8, extra_csv: []const u8) KeyRing {
    var ring = KeyRing{};
    ring.signers[0] = derive(primary);
    ring.count = 1;
    var it = std.mem.splitScalar(u8, extra_csv, ',');
    while (it.next()) |raw| {
        if (ring.count >= max_keys) break;
        const s = std.mem.trim(u8, raw, " \t");
        if (s.len == 0) continue;
        ring.signers[ring.count] = derive(s);
        ring.count += 1;
    }
    return ring;
}

/// HKDF-SHA256(secret) -> 32-byte seed.
pub fn deriveSeed(secret: []const u8, info: []const u8, out: *[32]u8) void {
    const prk = HkdfSha256.extract("", secret);
    HkdfSha256.expand(out, info, prk);
}

fn fromSeed(seed: [32]u8) Signer {
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch blk: {
        // Practically unreachable: the derived public key would have to be the
        // identity point. Re-derive from a distinct info string and accept it.
        var retry_seed: [32]u8 = undefined;
        deriveSeed(&seed, eddsa_info ++ ":retry", &retry_seed);
        break :blk Ed25519.KeyPair.generateDeterministic(retry_seed) catch unreachable;
    };
    const pk_bytes = kp.public_key.toBytes();
    return .{ .key_pair = kp, .kid_buf = kidFromPublicKey(pk_bytes) };
}

fn kidFromPublicKey(pk_bytes: [32]u8) [16]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(&pk_bytes, &digest, .{});
    const hex = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (digest[0..8], 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

/// Render an Ed25519 public JWK: {"kty":"OKP","crv":"Ed25519",...}.
pub fn ed25519PublicJwkJson(
    allocator: std.mem.Allocator,
    public_key: [Ed25519.PublicKey.encoded_length]u8,
    kid: []const u8,
) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    var xbuf: [64]u8 = undefined;
    const n = enc.calcSize(public_key.len);
    _ = enc.encode(xbuf[0..n], &public_key);
    return std.fmt.allocPrint(
        allocator,
        "{{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"{s}\",\"use\":\"sig\",\"alg\":\"EdDSA\",\"kid\":\"{s}\"}}",
        .{ xbuf[0..n], kid },
    );
}

/// Render an ES256 public JWK using the uncompressed SEC-1 point.
pub fn es256PublicJwkJson(
    allocator: std.mem.Allocator,
    public_key: EcdsaP256Sha256.PublicKey,
    kid: []const u8,
) ![]const u8 {
    const sec1 = public_key.toUncompressedSec1();
    const enc = std.base64.url_safe_no_pad.Encoder;
    var xbuf: [64]u8 = undefined;
    var ybuf: [64]u8 = undefined;
    const n = enc.calcSize(32);
    _ = enc.encode(xbuf[0..n], sec1[1..33]);
    _ = enc.encode(ybuf[0..n], sec1[33..65]);
    return std.fmt.allocPrint(
        allocator,
        "{{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"{s}\",\"y\":\"{s}\",\"use\":\"sig\",\"alg\":\"ES256\",\"kid\":\"{s}\"}}",
        .{ xbuf[0..n], ybuf[0..n], kid },
    );
}
