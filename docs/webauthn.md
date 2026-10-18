# WebAuthn / Passkey (ES256)

Status: MVP — registration and assertion verification with attestation
`none`. Implemented in `src/modules/mfa/webauthn.zig` (ceremonies),
`webauthn_api.zig` (HTTP), and `cbor.zig` (minimal CBOR decoder).

## Configuration

| Env | Default | Meaning |
| --- | --- | --- |
| `ZASDOOR_WEBAUTHN_RP_ID` | `localhost` | Relying-party id (domain only, no scheme/port) |
| `ZASDOOR_WEBAUTHN_RP_NAME` | `zasdoor` | Display name in the browser prompt |
| `ZASDOOR_WEBAUTHN_ORIGIN` | `http://localhost:3001` | Must equal the browser's `clientData.origin` exactly |
| `ZASDOOR_WEBAUTHN_CHALLENGE_TTL` | `300` | Challenge lifetime (seconds) |

## Endpoints

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| POST | `/api/v1/mfa/webauthn/login/begin` | public (rate-limited) | `{email}` → PublicKeyCredentialRequestOptions |
| POST | `/api/v1/mfa/webauthn/login/finish` | public (rate-limited) | assertion → `{token, user}` |
| POST | `/api/v1/mfa/webauthn/register/begin` | JWT | → PublicKeyCredentialCreationOptions |
| POST | `/api/v1/mfa/webauthn/register/finish` | JWT | `{credential_id, client_data_json, attestation_object, name?}` |
| GET | `/api/v1/mfa/webauthn/credentials` | JWT | list the caller's passkeys |
| DELETE | `/api/v1/mfa/webauthn/credentials/{id}` | JWT | delete a passkey |

The `begin` responses are raw WebAuthn option objects (not the
`{code,msg,data}` envelope) so they can be passed straight to
`navigator.credentials.create/get`. Binary fields (ids, signatures,
client data, attestation) are base64url without padding.

## Verification performed

- `clientDataJSON`: `type` (`webauthn.create` / `webauthn.get`),
  `origin` (exact), `challenge` (single-use, TTL, ceremony kind).
- Authenticator data: `rpIdHash == SHA256(rp_id)`, UP flag set, AT/ED flags
  consistent with the ceremony.
- Registration: attestation `fmt` must be `none`; the COSE key must be
  EC2/P-256/ES256 (`kty=2`, `crv=1`, `alg=-7`). The public key is stored as
  base64url of the uncompressed SEC-1 point.
- Assertion: ES256 over `authenticatorData || SHA256(clientDataJSON)`, DER
  signature, sign-count regression rejected when the counter is non-zero.
- Public login failures return a uniform 401 (no user/credential oracle).

## Limitations

- Only attestation format `none` is accepted; packed/TPM/Apple
  attestation is not verified (rejected).
- Extension data (`ED` flag) is unsupported.
- User verification is requested as `preferred`; no per-tenant policy yet.
- `login/begin` creates a challenge even for unknown emails (anti-enumeration),
  bounded by per-IP rate limiting and the scheduled challenge purge.
