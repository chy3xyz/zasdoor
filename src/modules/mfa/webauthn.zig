//! WebAuthn / passkey ceremonies (WebAuthn Level 2, ES256, attestation "none").
//!
//! Registration and assertion verification are implemented against the raw
//! CBOR/COSE structures a browser sends. The relying party id/origin come from
//! config and must match the browser's clientData exactly.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");
const user_svc = @import("../user/service.zig");
const cbor = @import("cbor.zig");

const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

// Authenticator data flags.
const flag_up = 0x01; // user present
const flag_at = 0x40; // attested credential data included
const flag_ed = 0x80; // extension data included (unsupported here)

pub const Config = struct {
    rp_id: []const u8,
    rp_name: []const u8,
    origin: []const u8,
    challenge_ttl_seconds: i64 = 300,
};

pub const Error = error{
    UserNotFound,
    NoCredentials,
    InvalidClientData,
    InvalidChallenge,
    InvalidOrigin,
    InvalidRpId,
    InvalidAttestation,
    InvalidPublicKey,
    InvalidSignature,
    SignCountRegression,
    DuplicateCredential,
    CredentialNotFound,
    OutOfMemory,
    Unexpected,
};

/// A credential descriptor returned to the browser (transports omitted: they
/// are optional and the browser will probe).
pub const RegistrationOptions = struct {
    challenge: []const u8,
    user_id: []const u8,
    user_name: []const u8,
    user_display_name: []const u8,
    exclude_ids: [][]const u8,
    timeout_ms: u32,
};

pub const LoginOptions = struct {
    challenge: []const u8,
    allow_ids: [][]const u8,
    timeout_ms: u32,
};

pub const FinishRegistration = struct {
    credential_id: []const u8,
    client_data_json: []const u8,
    attestation_object: []const u8,
    name: []const u8,
};

pub const FinishLogin = struct {
    credential_id: []const u8,
    client_data_json: []const u8,
    authenticator_data: []const u8,
    signature: []const u8,
};

pub const CredentialInfo = struct {
    id: i64,
    name: []const u8,
    credential_id: []const u8,
    last_used_at: i64,
};

pub const WebauthnService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.MfaStore,
    users: *user_svc.UserService,
    cfg: Config,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.MfaStore, users: *user_svc.UserService, cfg: Config) WebauthnService {
        return .{ .allocator = allocator, .io = io, .store = store, .users = users, .cfg = cfg };
    }

    pub fn now(self: *WebauthnService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }

    fn randomB64(self: *WebauthnService, n: usize) Error![]const u8 {
        const buf = self.allocator.alloc(u8, n) catch return error.OutOfMemory;
        defer self.allocator.free(buf);
        var file = std.Io.Dir.cwd().openFile(self.io, "/dev/urandom", .{}) catch return error.Unexpected;
        defer file.close(self.io);
        const read = file.readPositionalAll(self.io, buf, 0) catch return error.Unexpected;
        if (read != buf.len) return error.Unexpected;
        return b64Encode(self.allocator, buf) catch return error.OutOfMemory;
    }

    fn challengeFor(self: *WebauthnService, tenant_id: i64, user_id: i64, kind: []const u8, login_email: []const u8) Error![]const u8 {
        const ch = try self.randomB64(32);
        errdefer self.allocator.free(ch);
        self.store.createWebauthnChallenge(tenant_id, user_id, ch, kind, login_email, self.now() + self.cfg.challenge_ttl_seconds, self.now()) catch return error.Unexpected;
        return ch;
    }

    pub fn beginRegistration(self: *WebauthnService, user_id: i64) Error!RegistrationOptions {
        const row_opt = self.users.getUserById(user_id) catch return error.Unexpected;
        const user = row_opt orelse return error.UserNotFound;
        defer user.free(self.users.store.allocator);

        const challenge = try self.challengeFor(user.tenant_id, user_id, "register", "");
        errdefer self.allocator.free(challenge);

        const id_str = std.fmt.allocPrint(self.allocator, "{d}", .{user_id}) catch return error.OutOfMemory;
        defer self.allocator.free(id_str);
        const user_id_b64 = b64Encode(self.allocator, id_str) catch return error.OutOfMemory;
        errdefer self.allocator.free(user_id_b64);

        var exclude: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (exclude.items) |id| self.allocator.free(id);
            exclude.deinit(self.allocator);
        }
        const creds = self.store.listWebauthnCredentials(user_id) catch return error.Unexpected;
        defer {
            for (creds) |c| c.free(self.store.allocator);
            self.store.allocator.free(creds);
        }
        for (creds) |c| {
            const dup = self.allocator.dupe(u8, c.credential_id) catch return error.OutOfMemory;
            exclude.append(self.allocator, dup) catch {
                self.allocator.free(dup);
                return error.OutOfMemory;
            };
        }
        const user_name = self.allocator.dupe(u8, user.email) catch return error.OutOfMemory;
        errdefer self.allocator.free(user_name);
        const display_name = self.allocator.dupe(u8, user.name) catch return error.OutOfMemory;
        errdefer self.allocator.free(display_name);
        const ids = exclude.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{
            .challenge = challenge,
            .user_id = user_id_b64,
            .user_name = user_name,
            .user_display_name = display_name,
            .exclude_ids = ids,
            .timeout_ms = 60000,
        };
    }

    pub fn freeRegistrationOptions(self: *WebauthnService, o: RegistrationOptions) void {
        self.allocator.free(o.challenge);
        self.allocator.free(o.user_id);
        self.allocator.free(o.user_name);
        self.allocator.free(o.user_display_name);
        for (o.exclude_ids) |id| self.allocator.free(id);
        self.allocator.free(o.exclude_ids);
    }

    pub fn beginLogin(self: *WebauthnService, email: []const u8) Error!LoginOptions {
        const norm = std.ascii.allocLowerString(self.allocator, email) catch return error.OutOfMemory;
        defer self.allocator.free(norm);

        const user_opt = self.users.getUserByEmail(self.allocator, norm) catch return error.Unexpected;
        var user_id: i64 = 0;
        var tenant_id: i64 = 1;
        if (user_opt) |u| {
            user_id = u.id;
            tenant_id = u.tenant_id;
            u.free(self.users.store.allocator);
        }

        const challenge = try self.challengeFor(tenant_id, user_id, "login", norm);
        errdefer self.allocator.free(challenge);

        var allow: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (allow.items) |id| self.allocator.free(id);
            allow.deinit(self.allocator);
        }
        if (user_id != 0) {
            const creds = self.store.listWebauthnCredentials(user_id) catch return error.Unexpected;
            defer {
                for (creds) |c| c.free(self.store.allocator);
                self.store.allocator.free(creds);
            }
            for (creds) |c| {
                const dup = self.allocator.dupe(u8, c.credential_id) catch return error.OutOfMemory;
                allow.append(self.allocator, dup) catch {
                    self.allocator.free(dup);
                    return error.OutOfMemory;
                };
            }
        }
        const ids = allow.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{ .challenge = challenge, .allow_ids = ids, .timeout_ms = 60000 };
    }

    pub fn freeLoginOptions(self: *WebauthnService, o: LoginOptions) void {
        self.allocator.free(o.challenge);
        for (o.allow_ids) |id| self.allocator.free(id);
        self.allocator.free(o.allow_ids);
    }

    pub fn registrationOptionsJson(self: *WebauthnService, allocator: std.mem.Allocator, o: RegistrationOptions) Error![]const u8 {
        const Desc = struct { type: []const u8 = "public-key", id: []const u8 };
        var excl = allocator.alloc(Desc, o.exclude_ids.len) catch return error.OutOfMemory;
        defer allocator.free(excl);
        for (o.exclude_ids, 0..) |id, i| excl[i] = .{ .id = id };
        const Param = struct { type: []const u8 = "public-key", alg: i32 = -7 };
        const params = [_]Param{.{}};
        return std.json.Stringify.valueAlloc(allocator, .{
            .rp = .{ .id = self.cfg.rp_id, .name = self.cfg.rp_name },
            .user = .{ .id = o.user_id, .name = o.user_name, .displayName = o.user_display_name },
            .challenge = o.challenge,
            .pubKeyCredParams = params,
            .timeout = o.timeout_ms,
            .attestation = "none",
            .excludeCredentials = excl,
        }, .{}) catch return error.OutOfMemory;
    }

    pub fn loginOptionsJson(self: *WebauthnService, allocator: std.mem.Allocator, o: LoginOptions) Error![]const u8 {
        const Desc = struct { type: []const u8 = "public-key", id: []const u8 };
        var allow = allocator.alloc(Desc, o.allow_ids.len) catch return error.OutOfMemory;
        defer allocator.free(allow);
        for (o.allow_ids, 0..) |id, i| allow[i] = .{ .id = id };
        return std.json.Stringify.valueAlloc(allocator, .{
            .challenge = o.challenge,
            .rpId = self.cfg.rp_id,
            .timeout = o.timeout_ms,
            .allowCredentials = allow,
            .userVerification = "preferred",
        }, .{}) catch return error.OutOfMemory;
    }

    pub fn finishRegistration(self: *WebauthnService, user_id: i64, body: FinishRegistration) Error!void {
        const user_opt = self.users.getUserById(user_id) catch return error.Unexpected;
        const user = user_opt orelse return error.UserNotFound;
        defer user.free(self.users.store.allocator);

        const client_json = b64Decode(self.allocator, body.client_data_json) catch return error.InvalidClientData;
        defer self.allocator.free(client_json);
        const cd = std.json.parseFromSlice(ClientData, self.allocator, client_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidClientData;
        defer cd.deinit();

        if (!std.mem.eql(u8, cd.value.type, "webauthn.create")) return error.InvalidClientData;
        if (!std.mem.eql(u8, cd.value.origin, self.cfg.origin)) return error.InvalidOrigin;

        const chal_opt = self.store.consumeWebauthnChallenge(cd.value.challenge, "register", self.now()) catch return error.Unexpected;
        const chal = chal_opt orelse return error.InvalidChallenge;
        defer chal.free(self.store.allocator);
        if (chal.user_id != user_id) return error.InvalidChallenge;

        const att_bytes = b64Decode(self.allocator, body.attestation_object) catch return error.InvalidAttestation;
        defer self.allocator.free(att_bytes);
        const att = cbor.decode(self.allocator, att_bytes) catch return error.InvalidAttestation;
        defer cbor.deinit(self.allocator, att);
        const att_map = switch (att) {
            .map => |m| m,
            else => return error.InvalidAttestation,
        };

        const fmt = mapText(att_map, "fmt") orelse return error.InvalidAttestation;
        if (!std.mem.eql(u8, fmt, "none")) return error.InvalidAttestation; // no attestation verification for other formats
        const auth = mapBytes(att_map, "authData") orelse return error.InvalidAttestation;

        self.verifyAuthData(auth, true) catch |err| return err;

        if (auth.len < 55) return error.InvalidAttestation;
        const aaguid = auth[37..53];
        const cred_len = readU16BE(auth[53..55]);
        if (auth.len < 55 + cred_len) return error.InvalidAttestation;
        const cred_id = auth[55 .. 55 + cred_len];
        const cose_bytes = auth[55 + cred_len ..];
        if (cose_bytes.len == 0) return error.InvalidAttestation;

        const cose = cbor.decode(self.allocator, cose_bytes) catch return error.InvalidPublicKey;
        defer cbor.deinit(self.allocator, cose);
        const cose_map = switch (cose) {
            .map => |m| m,
            else => return error.InvalidPublicKey,
        };
        if ((mapInt(cose_map, 1) orelse return error.InvalidPublicKey) != 2) return error.InvalidPublicKey; // kty EC2
        if ((mapInt(cose_map, 3) orelse return error.InvalidPublicKey) != -7) return error.InvalidPublicKey; // alg ES256
        if ((mapInt(cose_map, -1) orelse return error.InvalidPublicKey) != 1) return error.InvalidPublicKey; // crv P-256
        const x = mapBytesInt(cose_map, -2) orelse return error.InvalidPublicKey;
        const y = mapBytesInt(cose_map, -3) orelse return error.InvalidPublicKey;
        if (x.len != 32 or y.len != 32) return error.InvalidPublicKey;

        var sec1: [65]u8 = undefined;
        sec1[0] = 0x04;
        @memcpy(sec1[1..33], x);
        @memcpy(sec1[33..65], y);
        _ = EcdsaP256Sha256.PublicKey.fromSec1(&sec1) catch return error.InvalidPublicKey;

        const cred_b64 = b64Encode(self.allocator, cred_id) catch return error.OutOfMemory;
        defer self.allocator.free(cred_b64);
        if (body.credential_id.len > 0 and !std.mem.eql(u8, body.credential_id, cred_b64)) return error.InvalidAttestation;

        const sec1_b64 = b64Encode(self.allocator, &sec1) catch return error.OutOfMemory;
        defer self.allocator.free(sec1_b64);
        const aaguid_b64 = b64Encode(self.allocator, aaguid) catch return error.OutOfMemory;
        defer self.allocator.free(aaguid_b64);

        // Registration signCount is stored as 0; assertions advance it.
        _ = self.store.createWebauthnCredential(user.tenant_id, user_id, cred_b64, sec1_b64, body.name, "[]", aaguid_b64, self.now()) catch return error.DuplicateCredential;
    }

    pub fn finishLogin(self: *WebauthnService, email: []const u8, body: FinishLogin) Error!user_svc.Session {
        const norm = std.ascii.allocLowerString(self.allocator, email) catch return error.OutOfMemory;
        defer self.allocator.free(norm);

        const client_json = b64Decode(self.allocator, body.client_data_json) catch return error.InvalidClientData;
        defer self.allocator.free(client_json);
        const cd = std.json.parseFromSlice(ClientData, self.allocator, client_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidClientData;
        defer cd.deinit();

        if (!std.mem.eql(u8, cd.value.type, "webauthn.get")) return error.InvalidClientData;
        if (!std.mem.eql(u8, cd.value.origin, self.cfg.origin)) return error.InvalidOrigin;

        const chal_opt = self.store.consumeWebauthnChallenge(cd.value.challenge, "login", self.now()) catch return error.Unexpected;
        const chal = chal_opt orelse return error.InvalidChallenge;
        defer chal.free(self.store.allocator);
        if (!std.mem.eql(u8, chal.login_email, norm)) return error.InvalidChallenge;

        const user_opt = self.users.getUserByEmail(self.allocator, norm) catch return error.Unexpected;
        const user = user_opt orelse return error.UserNotFound;
        defer user.free(self.users.store.allocator);

        const cred_opt = self.store.getWebauthnCredentialByCredentialId(body.credential_id) catch return error.Unexpected;
        const cred = cred_opt orelse return error.CredentialNotFound;
        defer cred.free(self.store.allocator);
        if (cred.user_id != user.id) return error.CredentialNotFound;

        const auth = b64Decode(self.allocator, body.authenticator_data) catch return error.InvalidSignature;
        defer self.allocator.free(auth);
        self.verifyAuthData(auth, false) catch |err| return err;

        var client_hash: [32]u8 = undefined;
        Sha256.hash(client_json, &client_hash, .{});

        const msg = self.allocator.alloc(u8, auth.len + client_hash.len) catch return error.OutOfMemory;
        defer self.allocator.free(msg);
        @memcpy(msg[0..auth.len], auth);
        @memcpy(msg[auth.len..], &client_hash);

        const sig_der = b64Decode(self.allocator, body.signature) catch return error.InvalidSignature;
        defer self.allocator.free(sig_der);
        const sec1 = b64Decode(self.allocator, cred.public_key) catch return error.InvalidPublicKey;
        defer self.allocator.free(sec1);

        const pk = EcdsaP256Sha256.PublicKey.fromSec1(sec1) catch return error.InvalidPublicKey;
        const sig = EcdsaP256Sha256.Signature.fromDer(sig_der) catch return error.InvalidSignature;
        sig.verify(msg, pk) catch return error.InvalidSignature;

        const new_count: i64 = @intCast(readU32BE(auth[33..37]));
        if (cred.sign_count != 0 and new_count != 0 and new_count <= cred.sign_count) return error.SignCountRegression;
        if (new_count != 0) {
            self.store.updateWebauthnSignCount(cred.id, new_count, self.now()) catch return error.Unexpected;
        }

        return self.users.issueSessionForUser(self.allocator, user.id) catch return error.Unexpected;
    }

    fn verifyAuthData(self: *WebauthnService, auth: []const u8, expect_attested: bool) Error!void {
        if (auth.len < 37) return error.InvalidAttestation;
        var rp_hash: [32]u8 = undefined;
        Sha256.hash(self.cfg.rp_id, &rp_hash, .{});
        if (!std.mem.eql(u8, auth[0..32], &rp_hash)) return error.InvalidRpId;
        const flags = auth[32];
        if ((flags & flag_up) == 0) return error.InvalidAttestation;
        if ((flags & flag_ed) != 0) return error.InvalidAttestation; // extensions unsupported
        const has_attested = (flags & flag_at) != 0;
        if (expect_attested and !has_attested) return error.InvalidAttestation;
        if (!expect_attested and has_attested) return error.InvalidAttestation;
    }

    pub fn listCredentials(self: *WebauthnService, allocator: std.mem.Allocator, user_id: i64) Error![]CredentialInfo {
        const creds = self.store.listWebauthnCredentials(user_id) catch return error.Unexpected;
        defer {
            for (creds) |c| c.free(self.store.allocator);
            self.store.allocator.free(creds);
        }
        var out = allocator.alloc(CredentialInfo, creds.len) catch return error.OutOfMemory;
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |c| {
                allocator.free(c.name);
                allocator.free(c.credential_id);
            }
            allocator.free(out);
        }
        for (creds) |c| {
            const name_dup = allocator.dupe(u8, c.name) catch return error.OutOfMemory;
            errdefer allocator.free(name_dup);
            const cred_dup = allocator.dupe(u8, c.credential_id) catch return error.OutOfMemory;
            out[i] = .{
                .id = c.id,
                .name = name_dup,
                .credential_id = cred_dup,
                .last_used_at = c.last_used_at,
            };
            i += 1;
        }
        return out;
    }

    pub fn freeCredentialInfos(self: *WebauthnService, allocator: std.mem.Allocator, items: []CredentialInfo) void {
        _ = self;
        for (items) |c| {
            allocator.free(c.name);
            allocator.free(c.credential_id);
        }
        allocator.free(items);
    }

    pub fn deleteCredential(self: *WebauthnService, user_id: i64, id: i64) Error!bool {
        return self.store.deleteWebauthnCredential(id, user_id) catch return error.Unexpected;
    }
};

const ClientData = struct {
    type: []const u8,
    challenge: []const u8,
    origin: []const u8,
};

fn b64Decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const len = try b64.Decoder.calcSizeForSlice(s);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try b64.Decoder.decode(out, s);
    return out;
}

fn b64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = b64.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

fn readU16BE(b: []const u8) usize {
    return (@as(usize, b[0]) << 8) | b[1];
}

fn readU32BE(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn mapEntry(entries: []const cbor.Entry, key: []const u8) ?cbor.Value {
    for (entries) |e| {
        switch (e.key) {
            .text => |t| if (std.mem.eql(u8, t, key)) return e.value,
            else => {},
        }
    }
    return null;
}

fn mapText(entries: []const cbor.Entry, key: []const u8) ?[]const u8 {
    const v = mapEntry(entries, key) orelse return null;
    return switch (v) {
        .text => |t| t,
        else => null,
    };
}

fn mapBytes(entries: []const cbor.Entry, key: []const u8) ?[]const u8 {
    const v = mapEntry(entries, key) orelse return null;
    return switch (v) {
        .bytes => |b| b,
        else => null,
    };
}

fn mapBytesInt(entries: []const cbor.Entry, key: i64) ?[]const u8 {
    for (entries) |e| {
        const k = switch (e.key) {
            .uint => |u| std.math.cast(i64, u) orelse continue,
            .nint => |n| n,
            else => continue,
        };
        if (k != key) continue;
        return switch (e.value) {
            .bytes => |b| b,
            else => null,
        };
    }
    return null;
}

fn mapInt(entries: []const cbor.Entry, key: i64) ?i64 {
    for (entries) |e| {
        const k = switch (e.key) {
            .uint => |u| std.math.cast(i64, u) orelse continue,
            .nint => |n| n,
            else => continue,
        };
        if (k != key) continue;
        return switch (e.value) {
            .uint => |u| std.math.cast(i64, u),
            .nint => |n| n,
            else => null,
        };
    }
    return null;
}
