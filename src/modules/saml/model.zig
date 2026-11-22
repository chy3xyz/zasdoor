//! SAML SP state tables.
const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const SamlAssertionReplay = Schema("SamlAssertionReplay", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("provider_id"),
        field.String("assertion_id").Unique(),
        field.Int("expires_at"),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

pub const SamlLoginTicket = Schema("SamlLoginTicket", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("provider_id"),
        field.String("ticket").Unique(),
        field.Int("user_id"),
        field.String("redirect_to").Default(""),
        field.Int("expires_at"),
        field.Bool("used").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
