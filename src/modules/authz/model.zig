//! Authorization policy model: explicit allow/deny rules layered over RBAC.
//!
//! Evaluation is deny-overrides: any matching enabled deny wins; otherwise a
//! matching allow is returned; otherwise authorization falls back to the role
//! permission set.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Policy = Schema("Policy", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.String("name"),
        // allow | deny
        field.String("effect").Default("allow"),
        // "*" | "user:<id>" | "role:<role key>"
        field.String("subject").Default("*"),
        // resource pattern: exact or "*"
        field.String("resource").Default("*"),
        // action pattern: exact or "*"
        field.String("action").Default("*"),
        // Optional JSON object of integer attribute constraints, e.g.
        // {"project_id":42,"org_id":7}. Empty means "always applies".
        field.Text("condition").Default(""),
        // higher priority is evaluated first (informational; deny always wins)
        field.Int("priority").Default(0),
        field.Bool("enabled").Default(true),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

/// One recorded authorization decision, for audit and troubleshooting.
/// policy_id is 0 when the decision came from role fallback or was unknown.
pub const AuthzDecision = Schema("AuthzDecision", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("subject_id"),
        field.String("resource"),
        field.String("action"),
        field.String("decision").Default("unknown"), // allow | deny | unknown
        field.String("source").Default("none"), // none | role | policy
        field.Int("policy_id").Default(0),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
