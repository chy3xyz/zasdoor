//! SIWE (Sign-In With Ethereum) - secp256k1 ECDSA public-key recovery and
//! Ethereum address derivation.
//!
//! Given a signature (r, s, v) over a Keccak-256 message hash, we recover the
//! signer's public key and derive the 20-byte Ethereum address (last 20 bytes
//! of Keccak-256 of the 64-byte uncompressed point).

const std = @import("std");
const Secp256k1 = std.crypto.ecc.Secp256k1;

pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8, // recovery id (0 or 1)
};

/// Parse a 65-byte compact signature (r || s || v), removing the 27/28 offset.
pub fn parseCompact(sig: [65]u8) Signature {
    var s = Signature{ .r = undefined, .s = undefined, .v = 0 };
    @memcpy(s.r[0..32], sig[0..32]);
    @memcpy(s.s[0..32], sig[32..64]);
    const raw_v = sig[64];
    s.v = if (raw_v >= 27) raw_v - 27 else raw_v & 1;
    return s;
}

/// Derive the 20-byte Ethereum address from a sec1-encoded public key
/// (65-byte uncompressed or 33-byte compressed).
pub fn addressFromPublicKey(sec1: []const u8, out: *[20]u8) bool {
    if (sec1.len == 65 and sec1[0] == 0x04) {
        return addressFromXY(sec1[1..33], sec1[33..65], out);
    }
    if (sec1.len == 33) {
        const p = Secp256k1.fromSec1(sec1) catch return false;
        const aff = p.affineCoordinates();
        var xs: [32]u8 = undefined;
        var ys: [32]u8 = undefined;
        xs = aff.x.toBytes(.big);
        ys = aff.y.toBytes(.big);
        return addressFromXY(&xs, &ys, out);
    }
    return false;
}

fn addressFromXY(x: []const u8, y: []const u8, out: *[20]u8) bool {
    if (x.len != 32 or y.len != 32) return false;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], x);
    @memcpy(buf[32..64], y);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&buf, &hash, .{});
    @memcpy(out, hash[12..32]);
    return true;
}

/// Recover the signer's Ethereum address from a message hash + compact
/// signature. Returns false when the signature is invalid.
pub fn recoverAddress(digest: [32]u8, sig: Signature, out: *[20]u8) bool {
    secp256k1_scalar.rejectNonCanonical(sig.r, .big) catch return false;
    secp256k1_scalar.rejectNonCanonical(sig.s, .big) catch return false;

    const r_fe = Secp256k1.Fe.fromBytes(sig.r, .big) catch return false;
    const rec_id: u1 = if (sig.v >= 27) @intCast(sig.v - 27) else @intCast(sig.v & 1);
    const r_y = Secp256k1.recoverY(r_fe, rec_id == 1) catch return false;
    const R = Secp256k1.fromAffineCoordinates(.{ .x = r_fe, .y = r_y }) catch return false;

    const sR = R.mul(sig.s, .big) catch return false;
    const eG = Secp256k1.basePoint.mul(digest, .big) catch return false;
    const sR_minus_eG = sR.sub(eG);

    var r_scalar = Secp256k1.scalar.Scalar.fromBytes(sig.r, .big) catch return false;
    const rInv = r_scalar.invert();
    const rInv_bytes = rInv.toBytes(.big);

    const Q = sR_minus_eG.mul(rInv_bytes, .big) catch return false;
    const uncompressed = Q.toUncompressedSec1();
    return addressFromPublicKey(&uncompressed, out);
}

const secp256k1_scalar = struct {
    pub const rejectNonCanonical = Secp256k1.scalar.rejectNonCanonical;
};

/// EIP-191 "personal_sign" digest: the message is prefixed with the standard
/// \\x19Ethereum Signed Message:\\n<len> header before Keccak-256. This is what
/// most wallets (MetaMask etc.) sign for SIWE-style login.
pub fn personalSignDigest(message: []const u8, out: *[32]u8) !void {
    const prefix = "\x19Ethereum Signed Message:\n";
    var len_buf: [24]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{message.len});
    var data = std.ArrayList(u8).empty;
    defer data.deinit(std.heap.page_allocator);
    try data.appendSlice(std.heap.page_allocator, prefix);
    try data.appendSlice(std.heap.page_allocator, len_str);
    try data.appendSlice(std.heap.page_allocator, message);
    std.crypto.hash.sha3.Keccak256.hash(data.items, out, .{});
}
