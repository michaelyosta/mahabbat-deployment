// Mahabbat fork injector: runs at docker build time inside twentycrm/twenty.
// 1. Copies the pre-compiled bootstrap command into dist.
// 2. Registers it in database-command.module.js (fail-closed anchors).
// 3. Adds --allow-production to generate-api-key.command.js (fail-closed).
import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';

const DIST = '/app/packages/twenty-server/dist';
const fail = (msg) => { console.error(`fork-inject FAILED: ${msg}`); process.exit(1); };

// 1. Compiled command into dist.
copyFileSync(
  '/tmp/mahabbat-fork-patch/workspace-bootstrap-venue.command.js',
  `${DIST}/database/commands/workspace-bootstrap-venue.command.js`,
);

// 2. Register in the database command module.
const modPath = `${DIST}/database/commands/database-command.module.js`;
let mod = readFileSync(modPath, 'utf8');
const requireAnchor = 'const _dataseeddevworkspacecommand = require("./data-seed-dev-workspace.command");';
if (!mod.includes(requireAnchor)) fail('module require anchor missing');
mod = mod.replace(
  requireAnchor,
  `${requireAnchor}\nconst _bootstrapvenuecommand = require("./workspace-bootstrap-venue.command");`,
);
const providerAnchor = '_dataseeddevworkspacecommand.DataSeedWorkspaceCommand,';
mod = mod.replace(
  providerAnchor,
  `${providerAnchor}\n            _bootstrapvenuecommand.BootstrapVenueCommand,`,
);
if (!mod.includes('_bootstrapvenuecommand.BootstrapVenueCommand')) fail('module provider not injected');
// Imports: AuthModule (SignInUpService), UserModule (UserService + new
// saveUserForBootstrapVenue seam), UserWorkspaceModule
// (UserWorkspaceService). WorkspaceModule + ApiKeyModule (ApiKeyService +
// ApiKeyRoleService) are already imported upstream.
const importAnchors = [
  ['const _apikeymodule = require("../../engine/core-modules/api-key/api-key.module");',
   'const _authmodule = require("../../engine/core-modules/auth/auth.module");\nconst _usermodule = require("../../engine/core-modules/user/user.module");\nconst _userworkspacemodule = require("../../engine/core-modules/user-workspace/user-workspace.module");'],
];
for (const [anchor, addition] of importAnchors) {
  if (!mod.includes(anchor)) fail(`module import anchor missing: ${anchor.slice(0, 60)}`);
  if (!mod.includes('_authmodule.AuthModule')) {
    mod = mod.replace(anchor, `${anchor}\n${addition}`);
  }
}
// Add to imports: [...] array — anchor on ApiKeyModule entry.
const importsAnchor = '_apikeymodule.ApiKeyModule,';
if (!mod.includes(importsAnchor)) fail('module imports anchor missing');
if (!mod.includes('_authmodule.AuthModule')) {
  mod = mod.replace(
    importsAnchor,
    `${importsAnchor}\n            _authmodule.AuthModule,\n            _usermodule.UserModule,\n            _userworkspacemodule.UserWorkspaceModule,`,
  );
}
if (!mod.includes('_authmodule.AuthModule')) fail('module imports not injected');
writeFileSync(modPath, mod);

// 3. --allow-production for the API key command.
const keyPath = `${DIST}/engine/core-modules/api-key/commands/generate-api-key.command.js`;
let key = readFileSync(keyPath, 'utf8');
// 3a0. Fix the upstream _ts_decorate helper typo (=== instead of =)
// so method decorators receive the property descriptor.
key = key.replace(
  'desc === null ? desc === Object.getOwnPropertyDescriptor(target, key) : desc',
  'desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc',
);
// 3a. Register the --allow-production option (upstream dist has only
// workspace-id/name/expires-in decorators).
const expiresAnchor = '], GenerateApiKeyCommand.prototype, "parseExpiresIn", null);';
if (!key.includes(expiresAnchor)) fail('api-key expires anchor missing');
if (!key.includes('"parseAllowProduction"')) {
  key = key.replace(
    expiresAnchor,
    `${expiresAnchor}
GenerateApiKeyCommand.prototype.parseAllowProduction = function () { return true; };
_ts_decorate([(0, _nestcommander.Option)({ flags: '--allow-production', description: 'Mahabbat: permit this command in production (required outside dev/test).' }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", []), _ts_metadata("design:returntype", Boolean)], GenerateApiKeyCommand.prototype, "parseAllowProduction", Object.getOwnPropertyDescriptor(GenerateApiKeyCommand.prototype, "parseAllowProduction"));`,
  );
}
// 3b. Relax the dev/test-only guard when --allow-production is passed.
const guardAnchor = "throw new Error('This command is only available in development or test environments');";
if (!key.includes(guardAnchor)) fail('api-key guard anchor missing');
if (!key.includes('options.allowProduction')) {
  key = key.replace(
    `if (nodeEnv !== _nodeenvironmentinterface.NodeEnvironment.DEVELOPMENT && nodeEnv !== _nodeenvironmentinterface.NodeEnvironment.TEST) {\n            ${guardAnchor}`,
    `if (nodeEnv !== _nodeenvironmentinterface.NodeEnvironment.DEVELOPMENT && nodeEnv !== _nodeenvironmentinterface.NodeEnvironment.TEST && options.allowProduction !== true) {\n            throw new Error('This command is only available in development or test environments (or production with --allow-production)');`,
  );
}
if (!key.includes('options.allowProduction')) fail('api-key guard not patched');
writeFileSync(keyPath, key);

const authPath = `${DIST}/engine/core-modules/auth/auth.module.js`;
let auth = readFileSync(authPath, 'utf8');
const exportAnchor = 'exports: [';
if (!auth.includes(exportAnchor)) fail('auth-module exports anchor missing');
if (!auth.includes('_signinupservice.SignInUpService')) fail('auth-module SignInUpService ref missing');
// Insert into the exports: [...] array (last occurrence = module decorator).
const expIdx = auth.lastIndexOf(exportAnchor);
const afterAnchor = expIdx + exportAnchor.length;
if (!auth.includes('_signinupservice.SignInUpService,', expIdx)) {
  auth = auth.slice(0, afterAnchor) + '\n            _signinupservice.SignInUpService,' + auth.slice(afterAnchor);
}
if (!auth.includes('_signinupservice.SignInUpService,')) fail('auth-module export not injected');
writeFileSync(authPath, auth);

// 5. Mahabbat: disable public self-registration. Unknown emails get
// SIGNUP_DISABLED instead of a verification-email dead end.
const signupPath = `${DIST}/engine/core-modules/auth/auth.resolver.js`;
let signup = readFileSync(signupPath, 'utf8');
const signupAnchor = 'async signUp(signUpInput, context) {';
if (!signup.includes(signupAnchor)) fail('auth-resolver signup anchor missing');
if (!signup.includes('Self-registration is disabled')) {
  signup = signup.replace(
    signupAnchor,
    `async signUp(signUpInput, context) {
        throw new (require("./auth.exception").AuthException)(
          'Self-registration is disabled. Ask the venue owner to create your account.',
          require("./auth.exception").AuthExceptionCode.SIGNUP_DISABLED,
        );`,
  );
}
if (!signup.includes('Self-registration is disabled')) fail('signup disable not injected');
writeFileSync(signupPath, signup);

// 5b. Mahabbat P1: single-venue personal-invite gate. checkAccessForSignIn
// denies a bare public invite-hash link unless a personal invitation is
// present (fail-closed; literal 'false' disables). Trusted approved-domains
// still bypass (unchanged, above). Mirrors auth.service.ts patch 3.
const svcPath = `${DIST}/engine/core-modules/auth/services/auth.service.js`;
let svc = readFileSync(svcPath, 'utf8');
const gateAnchor = "if (hasPublicInviteLink && !hasPersonalInvitation && workspace && !workspace.isPublicInviteLinkEnabled) {";
if (!svc.includes(gateAnchor)) fail('auth-service gate anchor missing');
if (!svc.includes('A personal invitation is required to join this workspace')) {
  svc = svc.replace(
    gateAnchor,
    `if (hasPublicInviteLink && !hasPersonalInvitation && workspace && process.env.MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP !== 'false') {
            throw new _authexception.AuthException('A personal invitation is required to join this workspace', _authexception.AuthExceptionCode.FORBIDDEN_EXCEPTION);
        }
        ${gateAnchor}`,
  );
}
if (!svc.includes('A personal invitation is required to join this workspace')) fail('personal-invite gate not injected');
// 5c. Helpers (fail-closed flag reads + catch-all domain predicate), attached
// next to checkAccessForSignIn. Mirrors auth.service.ts Mahabbat helpers.
if (!svc.includes('mahabbatPasswordSignupRequiresPersonalInvite')) {
  const helperAnchor = 'async checkAccessForSignIn(';
  if (!svc.includes(helperAnchor)) fail('auth-service helper anchor missing');
  svc = svc.replace(
    helperAnchor,
    `mahabbatPasswordSignupRequiresPersonalInvite() { return process.env.MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP !== 'false'; }
    mahabbatSocialSsoSignupRequiresPersonalInvite() { return process.env.MAHABBAT_SSO_SIGNUP_INVITE_MODE !== 'personal-or-public' && this.mahabbatPasswordSignupRequiresPersonalInvite(); }
    static mahabbatIsCatchAllSignupDomain(domain) { return ['gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'yahoo.com', 'yandex.ru', 'yandex.com', 'mail.ru', 'bk.ru', 'list.ru', 'inbox.ru', 'icloud.com', 'proton.me', 'protonmail.com'].includes(String(domain).trim().toLowerCase()); }
    ${helperAnchor}`,
  );
}
if (!svc.includes('mahabbatPasswordSignupRequiresPersonalInvite')) fail('gate helpers not injected');
// 5d. SSO gate (Google/Microsoft): same personal-invite requirement on a bare
// public link; explicit 'personal-or-public' relaxes. Mirrors patch 3.
const ssoAnchor = 'const currentWorkspace = await this.findWorkspaceForSignInUp({';
if (!svc.includes(ssoAnchor)) fail('auth-service sso anchor missing');
if (!svc.includes('MAHABBAT_SSO_SIGNUP_INVITE_MODE')) {
  svc = svc.replace(
    'await this.checkAccessForSignIn({',
    `if (workspaceInviteHash && !invitation && currentWorkspace && process.env.MAHABBAT_SSO_SIGNUP_INVITE_MODE !== 'personal-or-public' && process.env.MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP !== 'false') {
                throw new _authexception.AuthException('A personal invitation is required to join this workspace', _authexception.AuthExceptionCode.FORBIDDEN_EXCEPTION);
            }
            await this.checkAccessForSignIn({`,
  );
}
if (!svc.includes('MAHABBAT_SSO_SIGNUP_INVITE_MODE')) fail('sso gate not injected');
writeFileSync(svcPath, svc);

// 5e. Mahabbat P1: public invite links default OFF (single-venue).
// Mirrors workspace.entity.ts patch 5.
const wsEntPath = `${DIST}/engine/core-modules/workspace/workspace.entity.js`;
let wsEnt = readFileSync(wsEntPath, 'utf8');
const wsDefaultAnchor = `(0, _typeorm.Column)({
        default: true
    })`;
if (!wsEnt.includes(wsDefaultAnchor)) fail('workspace-entity default anchor missing');
if (!wsEnt.includes('isPublicInviteLinkEnabled", void 0')) fail('workspace-entity field anchor missing');
wsEnt = wsEnt.replace(
  wsDefaultAnchor,
  `(0, _typeorm.Column)({
        default: false
    })`,
);
if (!wsEnt.includes('default: false')) fail('public-link default not patched');
writeFileSync(wsEntPath, wsEnt);
// 6. Mahabbat: workspace:rotate-api-key (mint-then-revoke rotation).
copyFileSync(
  '/tmp/mahabbat-fork-patch/workspace-rotate-api-key.command.js',
  `${DIST}/engine/core-modules/api-key/commands/rotate-api-key.command.js`,
);
mod = readFileSync(modPath, 'utf8');
const rotateRequireAnchor = 'engine/core-modules/api-key/commands/generate-api-key.command';
if (!mod.includes(rotateRequireAnchor)) fail('rotate require anchor missing');
if (!mod.includes('rotate-api-key.command");')) {
  const genRequireLine = mod.split('\n').find((line) => line.includes(rotateRequireAnchor));
  if (!genRequireLine) fail('rotate generate require line missing');
  mod = mod.replace(
    genRequireLine,
    `${genRequireLine}\nconst _rotateapikeycommand = require("../../engine/core-modules/api-key/commands/rotate-api-key.command");`,
  );
}
const rotateProviderAnchor = 'GenerateApiKeyCommand,';
if (!mod.includes(rotateProviderAnchor)) fail('rotate provider anchor missing');
if (!mod.includes('_rotateapikeycommand.RotateApiKeyCommand,')) {
  mod = mod.replace(
    rotateProviderAnchor,
    `${rotateProviderAnchor}\n            _rotateapikeycommand.RotateApiKeyCommand,`,
  );
}
if (!mod.includes('_rotateapikeycommand.RotateApiKeyCommand,')) fail('rotate command not injected');
writeFileSync(modPath, mod);
