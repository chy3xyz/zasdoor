export { WEBAUTHN_PATH, credentialPath } from './path';
export {
  beginPasskeyLogin,
  beginPasskeyRegistration,
  deletePasskey,
  finishPasskeyLogin,
  finishPasskeyRegistration,
  listPasskeys,
} from './query';
export type {
  PasskeyCredential,
  PasskeyLoginBeginRequest,
  PasskeyLoginFinishRequest,
  PasskeyLoginResult,
  PasskeyLoginUser,
  PasskeyRegistrationFinishRequest,
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialDescriptorJSON,
  PublicKeyCredentialRequestOptionsJSON,
} from './types';
