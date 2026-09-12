# Security Policy

Zasdoor is an identity and access management platform, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, report privately:

- Open a draft security advisory on the repository (Security → Advisories → *Report a vulnerability*), or
- Email the maintainers with a description, the affected version/commit, and reproduction steps.

Please include:

- A description of the issue and its impact.
- The affected component (e.g. `src/modules/oauth`, `src/modules/mfa`, `src/modules/web3`).
- Reproduction steps or a proof of concept.
- Any suggested remediation.

We aim to acknowledge reports within a few business days and to ship a fix or mitigation as quickly as the severity warrants. Please give us a reasonable window to release a fix before public disclosure.

## Supported versions

Security fixes are applied to the `main` branch. Release tags are cut from `main`; older tags are not maintained.

## Deployment hardening checklist

Zasdoor fails closed in production, but a secure deployment still depends on configuration:

- Set `ZASDOOR_JWT_SECRET` explicitly (required when using PostgreSQL; the process refuses to start with the dev default).
- Set `ZASDOOR_AI_KEY_SECRET` if you use the AI assistant — provider API keys are encrypted at rest with it.
- Restrict `/metrics` with `ZASDOOR_METRICS_ALLOW_IPS`.
- Restrict `ZASDOOR_CORS_ORIGINS` to your admin origin instead of `*`.
- Configure SMTP so verification and password-reset links are delivered over a trusted channel.
- Terminate TLS at your reverse proxy; never expose the API over plain HTTP to untrusted networks.
- Back up the database and the upload directory — see [docs/backup.md](docs/backup.md).

## Scope

In scope: authentication and session handling, OAuth2/OIDC authorization and token endpoints, MFA, SIWE/wallet binding, the authorization kernel, multi-tenant isolation, file upload handling, and the admin API.

Out of scope: issues that require an already-compromised host or database, missing hardening headers on the bundled development server, and vulnerabilities in third-party dependencies that should be reported upstream (zigmodu, zent).