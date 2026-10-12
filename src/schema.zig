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

// One graph for every table. zent raised `buildGraph`'s comptime branch quota
// with v0.29.4 (1M branches; ~400 tables measured per call — zent
// docs/UPGRADING.md §7a), so the older "split the graph to stay under the
// quota" guidance is stale. A single graph also permits cross-table `WithEdge`
// within one client. See docs/development-guide.md §2.2.
const graph = zent.codegen.graph.buildGraph(&.{
    tenant_model.Tenant,
    user_model.User,
    user_model.PasswordToken,
    user_model.EmailVerification,
    user_model.LoginAttempt,
    task_model.Task,
    file_model.File,
    notify_model.Notification,
    audit_model.AuditLog,
    mail_template_model.EmailTemplate,
    ai_model.AiProvider,
    ai_model.AiSession,
    ai_model.AiMessage,
    ai_model.AiApproval,
    ai_model.AiRun,
    iam_model.Organization,
    iam_model.Project,
    iam_model.Application,
    iam_model.Role,
    iam_model.RoleAssignment,
    iam_model.Session,
    iam_model.AuthorizationCode,
    iam_model.RefreshToken,
    iam_model.Consent,
    iam_model.DeviceCode,
    eventstore_model.Event,
    eventstore_model.EventPosition,
    eventstore_model.ProjectionState,
    mfa_model.TotpCredential,
    mfa_model.RecoveryCode,
    mfa_model.IdentityProvider,
    mfa_model.MfaPolicy,
    mfa_model.IdentityLink,
    mfa_model.FederatedState,
    web3_model.Wallet,
    web3_model.SiweNonce,
    agent_model.Agent,
    agent_model.AgentUsage,
});

pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);
