//! Web3 wallet identity model (dev.md V4).
//!
//! A Wallet is a chain-scoped public address that can be bound to a user
//! after SIWE (Sign-In With Ethereum) proof of ownership.

const zent = @import("zent");
const field = zent.core.field;
const Schema = zent.core.schema.Schema;

pub const Wallet = Schema("Wallet", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.Int("user_id").Default(0),
        field.String("chain").Default("evm"),
        field.String("address").Unique(),
        field.Bool("verified").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

pub const SiweNonce = Schema("SiweNonce", .{
    .fields = &.{
        field.Int("tenant_id").Default(1),
        field.String("nonce"),
        field.String("domain"),
        field.String("address"),
        field.Int("expires_at"),
        field.Bool("used").Default(false),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});
