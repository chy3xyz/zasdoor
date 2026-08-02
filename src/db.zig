//! Database store lifecycle: open driver (sqlite | postgres) → migrate
//! schema-as-code → make zent client. Driver choice is driven by config
//! at runtime so the same binary works against a local sqlite file or a
//! production Postgres instance.

const std = @import("std");
const zent = @import("zent");

pub const DriverKind = enum {
    sqlite,
    postgres,
};

/// RAII wrapper over the shared zent store: owns the driver, exposes the
/// generated client for the module's `infos`.
///
/// The driver lives on the heap: `makeClient` captures `driver.asDriver()`
/// which is a pointer, so the driver must outlive `open`'s frame (a value
/// copy of `Self` is returned). Heap allocation keeps that pointer stable.
pub fn StoreEnv(comptime Infos: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        kind: DriverKind,
        sqlite: ?*zent.sql_sqlite.SQLiteDriver = null,
        pg: ?*zent.sql_postgres.PostgresDriver = null,
        client: zent.codegen.client.Client(Infos),

        const Self = @This();

        pub fn open(allocator: std.mem.Allocator, kind: DriverKind, dsn: []const u8) !Self {
            var self: Self = .{
                .allocator = allocator,
                .kind = kind,
                .client = undefined,
            };
            switch (kind) {
                .sqlite => {
                    const driver = try allocator.create(zent.sql_sqlite.SQLiteDriver);
                    errdefer allocator.destroy(driver);
                    driver.* = try zent.sql_sqlite.SQLiteDriver.open(allocator, dsn);
                    errdefer driver.close();
                    try zent.sql_schema.migrateSchema(allocator, driver.asDriver(), Infos);
                    self.sqlite = driver;
                    self.client = zent.codegen.client.makeClient(Infos, allocator, driver.asDriver());
                },
                .postgres => {
                    const driver = try allocator.create(zent.sql_postgres.PostgresDriver);
                    errdefer allocator.destroy(driver);
                    driver.* = try zent.sql_postgres.PostgresDriver.connect(allocator, dsn);
                    errdefer driver.close();
                    try zent.sql_schema.migrateSchema(allocator, driver.asDriver(), Infos);
                    self.pg = driver;
                    self.client = zent.codegen.client.makeClient(Infos, allocator, driver.asDriver());
                },
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            switch (self.kind) {
                .sqlite => {
                    if (self.sqlite) |d| {
                        d.close();
                        self.allocator.destroy(d);
                    }
                },
                .postgres => {
                    if (self.pg) |d| {
                        d.close();
                        self.allocator.destroy(d);
                    }
                },
            }
            self.* = undefined;
        }
    };
}
