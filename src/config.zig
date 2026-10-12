//! Runtime configuration for zasdoor — read from environment variables.
//! Env var prefix: ZASDOOR_.

const std = @import("std");

pub const Config = struct {
    http_port: u16 = 8000,
    /// "sqlite" | "postgres" — which driver to open for the data store.
    db_driver: []const u8 = "sqlite",
    sqlite_path: []const u8 = "zasdoor.db",
    pg_conninfo: []const u8 = "host=localhost port=5432 dbname=zasdoor user=postgres password=postgres sslmode=prefer connect_timeout=10",
    /// HMAC key for JWT signing.
    jwt_secret: []const u8 = "dev-secret-change-me",
    /// True when ZASDOOR_JWT_SECRET was explicitly set (fail-closed in prod).
    jwt_secret_explicit: bool = false,
    /// Comma-separated IP allow-list for /metrics (empty = all; use in prod).
    metrics_allow_ips: []const u8 = "",
    /// JWT lifetime in seconds.
    token_expiry_seconds: i64 = 24 * 3600,
    /// Password reset token lifetime in seconds.
    password_token_expiration_seconds: i64 = 3600,
    /// Public base URL used to build absolute links (e.g. reset links).
    /// Points at the SPA (dev server) by default so reset links open the
    /// frontend page, which then calls the API.
    app_host: []const u8 = "http://localhost:3001",
    /// Comma-separated CORS allow-list. "*" allows any origin (dev only);
    /// set e.g. `ZASDOOR_CORS_ORIGINS=https://admin.example.com` in prod.
    cors_origins: []const u8 = "*",
    /// Mail transport. Empty host => console/log sink (dev). When set, SMTP
    /// is used (with STARTTLS when `smtp_starttls` is true).
    smtp_host: []const u8 = "",
    smtp_port: u16 = 587,
    smtp_username: []const u8 = "",
    smtp_password: []const u8 = "",
    smtp_from: []const u8 = "zasdoor@localhost",
    smtp_starttls: bool = true,
    /// Also log every outbound email at info level (useful in dev).
    mail_console: bool = true,
    /// Email verification token lifetime in seconds.
    verification_token_expiration_seconds: i64 = 24 * 3600,
    /// Upload directory (created on startup). Files are served from /files.
    upload_dir: []const u8 = "uploads",
    upload_max_bytes: usize = 10 * 1024 * 1024,
    /// In-memory cache capacity / TTL.
    cache_max_entries: usize = 1024,
    cache_ttl_seconds: u64 = 300,
    /// Background task dispatcher.
    task_max_attempts: i64 = 3,
    task_retry_interval_seconds: i64 = 60,
    /// Master key used to encrypt AI provider API keys at rest
    /// (ZASDOOR_AI_KEY_SECRET). Providers cannot be saved without it.
    ai_key_secret: []const u8 = "",
    /// Max agent runs per user per rolling 24h.
    ai_daily_run_limit: i64 = 100,
    /// 审计日志保留天数;超出部分由每日定时任务清理。
    audit_retention_days: i64 = 180,
    /// 并发连接上限(accept 背压:超限即时 503,防 fd/内存耗尽)。
    http_max_connections: usize = 1024,
    /// 请求超时(毫秒,0 = 不限制)。
    http_request_timeout_ms: u32 = 30000,
    /// 运行环境标识(ZASDOOR_ENV=development|production)。
    env: []const u8 = "development",
    /// OIDC 密钥环:额外的历史签名密钥(逗号分隔),仅用于轮换期间验签。
    /// 当前签名密钥始终由 ZASDOOR_JWT_SECRET 派生。
    oidc_key_secrets: []const u8 = "",

    pub fn fromEnv(environ: *const std.process.Environ.Map) Config {
        var cfg: Config = .{};
        cfg.http_port = parsePort(environ.get("ZASDOOR_HTTP_PORT") orelse "8000");
        cfg.db_driver = environ.get("ZASDOOR_DB_DRIVER") orelse "sqlite";
        cfg.sqlite_path = environ.get("ZASDOOR_SQLITE_PATH") orelse "zasdoor.db";
        cfg.pg_conninfo = environ.get("ZASDOOR_PG_CONNINFO") orelse cfg.pg_conninfo;
        cfg.jwt_secret_explicit = environ.get("ZASDOOR_JWT_SECRET") != null;
        cfg.jwt_secret = environ.get("ZASDOOR_JWT_SECRET") orelse "dev-secret-change-me";
        cfg.token_expiry_seconds = parseInt64(environ.get("ZASDOOR_TOKEN_EXPIRY") orelse "86400", 86400);
        cfg.password_token_expiration_seconds = parseInt64(environ.get("ZASDOOR_PASSWORD_TOKEN_EXPIRATION") orelse "3600", 3600);
        cfg.app_host = environ.get("ZASDOOR_APP_HOST") orelse "http://localhost:3001";
        cfg.cors_origins = environ.get("ZASDOOR_CORS_ORIGINS") orelse "*";
        cfg.smtp_host = environ.get("ZASDOOR_SMTP_HOST") orelse "";
        cfg.smtp_port = parsePort(environ.get("ZASDOOR_SMTP_PORT") orelse "587");
        cfg.smtp_username = environ.get("ZASDOOR_SMTP_USERNAME") orelse "";
        cfg.smtp_password = environ.get("ZASDOOR_SMTP_PASSWORD") orelse "";
        cfg.smtp_from = environ.get("ZASDOOR_SMTP_FROM") orelse "zasdoor@localhost";
        cfg.smtp_starttls = parseBool(environ.get("ZASDOOR_SMTP_STARTTLS") orelse "true", true);
        cfg.mail_console = parseBool(environ.get("ZASDOOR_MAIL_CONSOLE") orelse "true", true);
        cfg.verification_token_expiration_seconds = parseInt64(environ.get("ZASDOOR_VERIFICATION_TOKEN_EXPIRATION") orelse "86400", 86400);
        cfg.upload_dir = environ.get("ZASDOOR_UPLOAD_DIR") orelse "uploads";
        cfg.upload_max_bytes = parseIntUsize(environ.get("ZASDOOR_UPLOAD_MAX_BYTES") orelse "10485760", 10 * 1024 * 1024);
        cfg.cache_max_entries = parseIntUsize(environ.get("ZASDOOR_CACHE_MAX_ENTRIES") orelse "1024", 1024);
        cfg.cache_ttl_seconds = @intCast(parseInt64(environ.get("ZASDOOR_CACHE_TTL_SECONDS") orelse "300", 300));
        cfg.task_max_attempts = parseInt64(environ.get("ZASDOOR_TASK_MAX_ATTEMPTS") orelse "3", 3);
        cfg.task_retry_interval_seconds = parseInt64(environ.get("ZASDOOR_TASK_RETRY_INTERVAL_SECONDS") orelse "60", 60);
        cfg.ai_key_secret = environ.get("ZASDOOR_AI_KEY_SECRET") orelse "";
        cfg.ai_daily_run_limit = parseInt64(environ.get("ZASDOOR_AI_DAILY_RUN_LIMIT") orelse "100", 100);
        cfg.metrics_allow_ips = environ.get("ZASDOOR_METRICS_ALLOW_IPS") orelse "";
        cfg.audit_retention_days = parseInt64(environ.get("ZASDOOR_AUDIT_RETENTION_DAYS") orelse "180", 180);
        cfg.http_max_connections = parseIntUsize(environ.get("ZASDOOR_HTTP_MAX_CONNECTIONS") orelse "1024", 1024);
        cfg.http_request_timeout_ms = @intCast(parseIntUsize(environ.get("ZASDOOR_HTTP_REQUEST_TIMEOUT_MS") orelse "30000", 30000));
        cfg.env = environ.get("ZASDOOR_ENV") orelse "development";
        cfg.oidc_key_secrets = environ.get("ZASDOOR_OIDC_KEY_SECRETS") orelse "";
        return cfg;
    }

    /// 生产判定:显式 production,或任何"类生产"后端(postgres)。用于启动
    /// 预检 fail-closed——默认密钥/默认 CORS 在生产形态下拒绝启动而非降级。
    pub fn isProdLike(self: *const Config) bool {
        return std.mem.eql(u8, self.env, "production") or std.mem.eql(u8, self.db_driver, "postgres");
    }
};

fn parsePort(s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 10) catch 8000;
}

fn parseInt64(s: []const u8, default: i64) i64 {
    return std.fmt.parseInt(i64, s, 10) catch default;
}

fn parseIntUsize(s: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, s, 10) catch default;
}

fn parseBool(s: []const u8, default: bool) bool {
    if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no")) return false;
    return default;
}
