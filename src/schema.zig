//! Shared zent schema graph for the whole application.
//!
//! Every module registers its schemas here so a single `StoreEnv` can
//! migrate the full schema and expose one type-safe client to all stores
//! (zigmodu + zent best practice: one client, schema-as-code in one place).

const zent = @import("zent");

const user_model = @import("modules/user/model.zig");
const task_model = @import("modules/task/model.zig");
const file_model = @import("modules/file/model.zig");
const notify_model = @import("modules/notify/model.zig");
const tenant_model = @import("modules/tenant/model.zig");
const audit_model = @import("modules/audit/model.zig");
const mail_template_model = @import("modules/mail_template/model.zig");

// zent's `buildGraph` comptime edge-resolution has a per-call branch quota;
// keeping the graph small avoids it, so the app schema and the standalone
// mail-template table are built as two graphs and their types merged.
const graph = zent.codegen.graph.buildGraph(&.{
    tenant_model.Tenant,
    user_model.User,
    user_model.PasswordToken,
    user_model.EmailVerification,
    task_model.Task,
    file_model.File,
    notify_model.Notification,
    audit_model.AuditLog,
});
const template_graph = zent.codegen.graph.buildGraph(&.{mail_template_model.EmailTemplate});

pub const infos = graph.types ++ template_graph.types;
pub const Client = zent.codegen.client.Client(infos);
