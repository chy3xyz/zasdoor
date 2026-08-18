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
const ai_model = @import("modules/ai/model.zig");
const iam_model = @import("modules/iam/model.zig");
const eventstore_model = @import("modules/eventstore/model.zig");
const mfa_model = @import("modules/mfa/model.zig");
const web3_model = @import("modules/web3/model.zig");
const agent_model = @import("modules/agent/model.zig");

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
const ai_graph = zent.codegen.graph.buildGraph(&.{
    ai_model.AiProvider,
    ai_model.AiSession,
    ai_model.AiMessage,
    ai_model.AiApproval,
    ai_model.AiRun,
});
const iam_graph = zent.codegen.graph.buildGraph(&.{
    iam_model.Organization,
    iam_model.Project,
    iam_model.Application,
    iam_model.Role,
    iam_model.RoleAssignment,
    iam_model.Session,
    iam_model.AuthorizationCode,
    iam_model.RefreshToken,
    iam_model.Consent,
});

const eventstore_graph = zent.codegen.graph.buildGraph(&.{
    eventstore_model.Event,
    eventstore_model.EventPosition,
    eventstore_model.ProjectionState,
});

const mfa_graph = zent.codegen.graph.buildGraph(&.{
    mfa_model.TotpCredential,
    mfa_model.RecoveryCode,
    mfa_model.IdentityProvider,
    mfa_model.MfaPolicy,
});

const web3_graph = zent.codegen.graph.buildGraph(&.{
    web3_model.Wallet,
});
const agent_graph = zent.codegen.graph.buildGraph(&.{
    agent_model.Agent,
});

pub const infos = graph.types ++ template_graph.types ++ ai_graph.types ++ iam_graph.types ++ eventstore_graph.types ++ mfa_graph.types ++ web3_graph.types ++ agent_graph.types;
pub const Client = zent.codegen.client.Client(infos);
