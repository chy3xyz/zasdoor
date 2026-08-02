//! Runtime configuration for zenaipa — read from environment variables.
//! Env var prefix: ZENAIPA_.

const std = @import("std");

pub const Config = struct {
    http_port: u16 = 8000,
    /// "sqlite" | "postgres" — which driver to open for the data store.
    db_driver: []const u8 = "sqlite",
    sqlite_path: []const u8 = "zenaipa.db",
    pg_conninfo: []const u8 = "host=localhost port=5432 dbname=zenaipa user=postgres password=postgres sslmode=prefer connect_timeout=10",
    /// HMAC key for JWT signing.
    jwt_secret: []const u8 = "dev-secret-change-me",
    /// JWT lifetime in seconds.
    token_expiry_seconds: i64 = 24 * 3600,
    /// Password reset token lifetime in seconds.
    password_token_expiration_seconds: i64 = 3600,
    /// Public base URL used to build absolute links (e.g. reset links).
    /// Points at the SPA (dev server) by default so reset links open the
    /// frontend page, which then calls the API.
    app_host: []const u8 = "http://localhost:3001",
    /// Comma-separated CORS allow-list. "*" allows any origin (dev only);
    /// set e.g. `ZENAIPA_CORS_ORIGINS=https://admin.example.com` in prod.
    cors_origins: []const u8 = "*",

    pub fn fromEnv(environ: *const std.process.Environ.Map) Config {
        var cfg: Config = .{};
        cfg.http_port = parsePort(environ.get("ZENAIPA_HTTP_PORT") orelse "8000");
        cfg.db_driver = environ.get("ZENAIPA_DB_DRIVER") orelse "sqlite";
        cfg.sqlite_path = environ.get("ZENAIPA_SQLITE_PATH") orelse "zenaipa.db";
        cfg.pg_conninfo = environ.get("ZENAIPA_PG_CONNINFO") orelse cfg.pg_conninfo;
        cfg.jwt_secret = environ.get("ZENAIPA_JWT_SECRET") orelse "dev-secret-change-me";
        cfg.token_expiry_seconds = parseInt64(environ.get("ZENAIPA_TOKEN_EXPIRY") orelse "86400", 86400);
        cfg.password_token_expiration_seconds = parseInt64(environ.get("ZENAIPA_PASSWORD_TOKEN_EXPIRATION") orelse "3600", 3600);
        cfg.app_host = environ.get("ZENAIPA_APP_HOST") orelse "http://localhost:3001";
        cfg.cors_origins = environ.get("ZENAIPA_CORS_ORIGINS") orelse "*";
        return cfg;
    }
};

fn parsePort(s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 10) catch 8000;
}

fn parseInt64(s: []const u8, default: i64) i64 {
    return std.fmt.parseInt(i64, s, 10) catch default;
}
