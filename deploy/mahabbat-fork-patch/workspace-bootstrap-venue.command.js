"use strict";
// Mahabbat fork: headless venue bootstrap (compiled JS, injected into the
// upstream twenty:v2.29.0 dist at docker build time).
// Mirrors workspace-bootstrap-venue.command.ts: user -> workspace ->
// activation -> ru-RU locale -> admin API key. Idempotent, machine output.
Object.defineProperty(exports, "__esModule", { value: true });
Object.defineProperty(exports, "BootstrapVenueCommand", { enumerable: true, get: function () { return BootstrapVenueCommand; } });
const common_1 = require("@nestjs/common");
const typeorm_1 = require("@nestjs/typeorm");
const nest_commander_1 = require("nest-commander");
const typeorm_2 = require("typeorm");
const workspace_type_1 = require("../../engine/core-modules/workspace/types/workspace.type");
const workspace_entity_1 = require("../../engine/core-modules/workspace/workspace.entity");
const workspace_service_1 = require("../../engine/core-modules/workspace/services/workspace.service");
const sign_in_up_service_1 = require("../../engine/core-modules/auth/services/sign-in-up.service");
const user_service_1 = require("../../engine/core-modules/user/services/user.service");
const user_workspace_service_1 = require("../../engine/core-modules/user-workspace/user-workspace.service");
const api_key_service_1 = require("../../engine/core-modules/api-key/services/api-key.service");
const api_key_role_service_1 = require("../../engine/core-modules/api-key/services/api-key-role.service");
const auth_util_1 = require("../../engine/core-modules/auth/auth.util");
const role_entity_1 = require("../../engine/metadata-modules/role/role.entity");
const inject_workspace_scoped_repository_decorator_1 = require("../../engine/twenty-orm/workspace-scoped-repository/inject-workspace-scoped-repository.decorator");
function _ts_decorate(decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
}
function _ts_param(paramIndex, decorator) {
    return function (target, key) { decorator(target, key, paramIndex); };
}
const NEVER_EXPIRE_MS = 100 * 365 * 24 * 3600 * 1000;
let BootstrapVenueCommand = class BootstrapVenueCommand extends nest_commander_1.CommandRunner {
    constructor(workspaceRepository, roleRepository, signInUpService, userService, userWorkspaceService, workspaceService, apiKeyService, apiKeyRoleService) {
        super();
        this.workspaceRepository = workspaceRepository;
        this.roleRepository = roleRepository;
        this.signInUpService = signInUpService;
        this.userService = userService;
        this.userWorkspaceService = userWorkspaceService;
        this.workspaceService = workspaceService;
        this.apiKeyService = apiKeyService;
        this.apiKeyRoleService = apiKeyRoleService;
        this.logger = new common_1.Logger(BootstrapVenueCommand.name);
    }
    parseEmail(value) { return value; }
    parsePassword(value) { return value; }
    parseWorkspaceName(value) { return value; }
    parseLocale(value) { return value; }
    parseSubdomain(value) { return value; }
    async run(_passedParams, options) {
        const email = ((options.email || process.env.MAHABBAT_VENUE_EMAIL || "").trim().toLowerCase());
        const password = (options.password || process.env.MAHABBAT_VENUE_PASSWORD || "");
        const workspaceName = ((options.workspaceName || process.env.MAHABBAT_VENUE_NAME || "").trim());
        const locale = ((options.locale || process.env.MAHABBAT_VENUE_LOCALE || "ru-RU").trim());
        const subdomain = ((options.subdomain || process.env.MAHABBAT_VENUE_SUBDOMAIN || "").trim()) || undefined;
        const apiKeyName = (process.env.MAHABBAT_VENUE_API_KEY_NAME || "Mahabbat venue key");
        if (!email || !email.includes("@")) throw new Error("A valid email is required (--email or MAHABBAT_VENUE_EMAIL).");
        if (password.length < 8 || password.length > 50) throw new Error("Password must be 8-50 characters (--password or MAHABBAT_VENUE_PASSWORD).");
        if (!workspaceName) throw new Error("A workspace name is required (--workspace-name or MAHABBAT_VENUE_NAME).");
        if (!(0, utils_1.isValidLocale)(locale)) throw new Error(`Unsupported locale: ${locale}.`);
        const available = await this.userWorkspaceService.findAvailableWorkspacesByEmail(email);
        let user = await this.userService.findUserByEmail(email);
        let workspace = available?.[0]?.workspace;
        if (!user) {
            user = await this.signInUpService.signUpWithoutWorkspace({ email, locale }, { provider: workspace_type_1.AuthProviderEnum.Password, password });
            await this.userService.markEmailAsVerified(user.id);
            this.logger.log(`Created venue owner ${email}.`);
        }
        else if (!user.passwordHash) { throw new Error(`Existing user ${email} has no password credential (SSO-created?). Refusing to silently reuse — reset the password first.`); }
        else {
            const matches = await auth_util_1.compareHash(password, user.passwordHash);
            if (!matches) { user.passwordHash = await auth_util_1.hashPassword(password); await this.userService.saveUserForBootstrapVenue(user); this.logger.log(`Rotated password for reused user ${email}.`); }
            else { this.logger.log(`Reusing existing user ${email} (password verified).`); }
        }
        if (!workspace) {
            const created = await this.signInUpService.signUpOnNewWorkspace({ type: "existingUser", existingUser: user }, { displayName: workspaceName, subdomain });
            workspace = created.workspace;
            this.logger.log(`Created workspace ${workspace.id}.`);
        }
        else { this.logger.log(`Reusing workspace ${workspace.id}.`); }
        const active = await this.workspaceService.activateWorkspace({ id: user.id, email: user.email }, workspace);
        await this.workspaceRepository.update(active.id, { isPublicInviteLinkEnabled: false });
        const ownerUserWorkspace = await this.userWorkspaceService.getUserWorkspaceForUserOrThrow({ userId: user.id, workspaceId: active.id });
        await this.userWorkspaceService.updateUserWorkspaceLocaleForUserWorkspace({ locale, userWorkspaceId: ownerUserWorkspace.id });
        const existing = (await this.apiKeyService.findActiveByWorkspaceId(active.id)).filter((k) => !k.revokedAt && k.expiresAt > new Date());
        const adminRoleForReuse = await this.roleRepository.findOne(active.id, { where: { universalIdentifier: standard_role_constant_1.STANDARD_ROLE.admin.universalIdentifier } });
        const rolesByKey = adminRoleForReuse ? await this.apiKeyRoleService.getRolesByApiKeys({ apiKeyIds: existing.map((k) => k.id), workspaceId: active.id }) : new Map();
        const adminKeys = existing.filter((k) => rolesByKey.get(k.id)?.id === (adminRoleForReuse && adminRoleForReuse.id)).sort((a, b) => +new Date(b.createdAt) - +new Date(a.createdAt));
        let token; let keyId;
        if (adminKeys.length > 0) {
            keyId = adminKeys[0].id;
            const minted = await this.apiKeyService.generateApiKeyToken(active.id, keyId);
            token = minted?.token;
            this.logger.log("Reusing existing active admin API key (newest first).");
        }
        if (!token) {
            const adminRole = await this.roleRepository.findOne(active.id, { where: { universalIdentifier: standard_role_constant_1.STANDARD_ROLE.admin.universalIdentifier } });
            if (!adminRole) throw new Error(`No Admin role found for workspace ${active.id}. Activation may have failed.`);
            const apiKey = await this.apiKeyService.create({ name: apiKeyName, expiresAt: new Date(Date.now() + NEVER_EXPIRE_MS), workspaceId: active.id, roleId: adminRole.id });
            const minted = await this.apiKeyService.generateApiKeyToken(active.id, apiKey.id);
            if (!minted?.token) throw new Error("Failed to mint the venue API token.");
            token = minted.token; keyId = apiKey.id;
            this.logger.log("Created new venue API key.");
        }
        this.logger.log(`MAHABBAT_WORKSPACE_ID=${active.id}`);
        this.logger.log(`MAHABBAT_API_KEY_ID=${keyId}`);
        this.logger.log(`MAHABBAT_API_KEY=${token}`);
    }
};
BootstrapVenueCommand = _ts_decorate([
    (0, nest_commander_1.Command)({ name: "workspace:bootstrap:venue", description: "Mahabbat: create or reuse the venue owner, workspace, activation, ru-RU locale and admin API key." }),
    _ts_param(0, (0, typeorm_1.InjectRepository)(workspace_entity_1.WorkspaceEntity)),
    _ts_param(1, (0, inject_workspace_scoped_repository_decorator_1.InjectWorkspaceScopedRepository)(role_entity_1.RoleEntity)),
    _ts_metadata("design:type", Function),
    _ts_metadata("design:paramtypes", [typeof typeorm_2.Repository === "undefined" ? Object : typeorm_2.Repository, Object, typeof sign_in_up_service_1.SignInUpService === "undefined" ? Object : sign_in_up_service_1.SignInUpService, typeof user_service_1.UserService === "undefined" ? Object : user_service_1.UserService, typeof user_workspace_service_1.UserWorkspaceService === "undefined" ? Object : user_workspace_service_1.UserWorkspaceService, typeof workspace_service_1.WorkspaceService === "undefined" ? Object : workspace_service_1.WorkspaceService, typeof api_key_service_1.ApiKeyService === "undefined" ? Object : api_key_service_1.ApiKeyService, typeof api_key_role_service_1.ApiKeyRoleService === "undefined" ? Object : api_key_role_service_1.ApiKeyRoleService])
], BootstrapVenueCommand);
function _ts_metadata(k, v) { if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v); }
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-e, --email <email>", description: "Venue owner email (required, or MAHABBAT_VENUE_EMAIL)", required: false }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], BootstrapVenueCommand.prototype, "parseEmail", Object.getOwnPropertyDescriptor(BootstrapVenueCommand.prototype, "parseEmail"));
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-p, --password <password>", description: "Venue owner password 8-50 chars (required, or MAHABBAT_VENUE_PASSWORD)", required: false }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], BootstrapVenueCommand.prototype, "parsePassword", Object.getOwnPropertyDescriptor(BootstrapVenueCommand.prototype, "parsePassword"));
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-n, --workspace-name <name>", description: "Workspace display name (required, or MAHABBAT_VENUE_NAME)", required: false }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], BootstrapVenueCommand.prototype, "parseWorkspaceName", Object.getOwnPropertyDescriptor(BootstrapVenueCommand.prototype, "parseWorkspaceName"));
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-l, --locale <locale>", description: "Shell locale (default ru-RU, or MAHABBAT_VENUE_LOCALE)", required: false }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], BootstrapVenueCommand.prototype, "parseLocale", Object.getOwnPropertyDescriptor(BootstrapVenueCommand.prototype, "parseLocale"));
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-s, --subdomain <subdomain>", description: "Optional workspace subdomain (or MAHABBAT_VENUE_SUBDOMAIN)", required: false }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], BootstrapVenueCommand.prototype, "parseSubdomain", Object.getOwnPropertyDescriptor(BootstrapVenueCommand.prototype, "parseSubdomain"));
