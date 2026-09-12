# Zasdoor documentation

Start with the [project README](../README.md). These documents go deeper on individual areas:

| Document | Contents |
| --- | --- |
| [iam.md](iam.md) | Organizations, projects, applications, roles, sessions, the authorization endpoint |
| [oauth.md](oauth.md) | OAuth2 / OIDC: grants, PKCE, EdDSA signing, public JWKS, consent, discovery, introspection, revocation |
| [mfa.md](mfa.md) | TOTP enrollment and verification, recovery codes, per-tenant MFA policy, federated (social) login |
| [auth.md](auth.md) | Password policy and per-account login lockout |
| [web3.md](web3.md) | Sign-In With Ethereum: EIP-4361 messages, nonces, wallet binding |
| [agent.md](agent.md) | Machine identities: capabilities, scopes, and the per-period budget ledger |
| [authz.md](authz.md) | Authorization kernel: roles, permissions, wildcards, deny-by-default |
| [eventstore.md](eventstore.md) | Append-only domain events |
| [development-guide.md](development-guide.md) | How to add a business module (zent / zigmodu conventions, transactions, security, testing) |
| [backup.md](backup.md) | Backup and restore playbook |
| [streaming.md](streaming.md) | Streaming chat contract (SSE) for the AI assistant |

See also [SECURITY.md](../SECURITY.md) for the vulnerability-reporting process and a deployment hardening checklist.