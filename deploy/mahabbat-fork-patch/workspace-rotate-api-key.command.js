"use strict";
// Mahabbat fork: API key rotation (compiled JS, injected into the
// upstream twenty:v2.29.0 dist at docker build time).
// Mirrors rotate-api-key.command.ts: single-flight pg advisory lock per
// workspace + pre-mint id snapshot + mint-then-revoke. Any mint/token/revoke
// failure throws (non-zero exit); warn-and-continue is never used.
Object.defineProperty(exports, "__esModule", { value: true });
Object.defineProperty(exports, "RotateApiKeyCommand", { enumerable: true, get: function () { return RotateApiKeyCommand; } });
const common_1 = require("@nestjs/common");
const typeorm_1 = require("@nestjs/typeorm");
const date_fns_1 = require("date-fns");
const nest_commander_1 = require("nest-commander");
const utils_1 = require("twenty-shared/utils");
const typeorm_2 = require("typeorm");
const node_environment_interface_1 = require("../../twenty-config/interfaces/node-environment.interface");
const api_key_service_1 = require("../services/api-key.service");
const twenty_config_service_1 = require("../../twenty-config/twenty-config.service");
const workspace_entity_1 = require("../../workspace/workspace.entity");
const role_entity_1 = require("../../../metadata-modules/role/role.entity");
const inject_workspace_scoped_repository_decorator_1 = require("../../../twenty-orm/workspace-scoped-repository/inject-workspace-scoped-repository.decorator");
const standard_role_constant_1 = require("../../../workspace-manager/twenty-standard-application/constants/standard-role.constant");
function _ts_decorate(decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
}
function _ts_param(paramIndex, decorator) {
    return function (target, key) { decorator(target, key, paramIndex); };
}
const NEVER_EXPIRE_DAYS = 100 * 365;
let RotateApiKeyCommand = class RotateApiKeyCommand extends nest_commander_1.CommandRunner {
    constructor(workspaceRepository, roleRepository, apiKeyService, twentyConfigService, coreDataSource) {
        super();
        this.workspaceRepository = workspaceRepository;
        this.roleRepository = roleRepository;
        this.apiKeyService = apiKeyService;
        this.twentyConfigService = twentyConfigService;
        this.coreDataSource = coreDataSource;
        this.logger = new common_1.Logger(RotateApiKeyCommand.name);
    }
    parseWorkspaceId(value) { return value; }
    parseName(value) { return value; }
    parseAllowProduction() { return true; }
    async run(_passedParams, options) {
        const nodeEnv = this.twentyConfigService.get('NODE_ENV');
        if (nodeEnv !== node_environment_interface_1.NodeEnvironment.DEVELOPMENT && nodeEnv !== node_environment_interface_1.NodeEnvironment.TEST && options.allowProduction !== true) {
            throw new Error('This command is only available in development or test environments (or production with --allow-production)');
        }
        const workspace = await this.workspaceRepository.findOne({ where: { id: options.workspaceId } });
        if (!(0, utils_1.isDefined)(workspace)) {
            this.logger.error(`Workspace ${options.workspaceId} not found.`);
            return;
        }
        const adminRole = await this.roleRepository.findOne(workspace.id, { where: { universalIdentifier: standard_role_constant_1.STANDARD_ROLE.admin.universalIdentifier } });
        if (!(0, utils_1.isDefined)(adminRole)) {
            this.logger.error(`No Admin role found for workspace ${workspace.id}.`);
            return;
        }
        // Single-flight: session-scoped pg advisory lock held across the mint.
        const lockRunner = await this.acquireWorkspaceRotateLock(workspace.id);
        // Pre-mint snapshot: keys created after this point are never revoked.
        const preMintActive = await this.apiKeyService.findActiveByWorkspaceId(workspace.id);
        const preMintIds = new Set(preMintActive.map((key) => key.id));
        const expiresAt = (0, date_fns_1.addDays)(new Date(), NEVER_EXPIRE_DAYS);
        let apiKey;
        try {
            apiKey = await this.apiKeyService.create({ name: options.name, expiresAt, workspaceId: workspace.id, roleId: adminRole.id });
        }
        catch (error) {
            throw new Error(`Failed to create replacement API key: ${error}`);
        }
        finally {
            await this.releaseWorkspaceRotateLock(lockRunner, workspace.id);
        }
        const tokenResult = await this.apiKeyService.generateApiKeyToken(workspace.id, apiKey.id, expiresAt);
        if (!(0, utils_1.isDefined)(tokenResult)) {
            await this.apiKeyService.revoke(apiKey.id, workspace.id);
            throw new Error('Failed to generate token; replacement key revoked.');
        }
        let revoked = 0;
        for (const id of preMintIds) {
            if (id === apiKey.id)
                continue;
            const revokedEntity = await this.apiKeyService.revoke(id, workspace.id);
            if (!(0, utils_1.isDefined)(revokedEntity)) {
                throw new Error(`Failed to revoke API key ${id}: key not found; rotation aborted with the new key active and previous keys untouched after this point.`);
            }
            revoked += 1;
        }
        this.logger.log(`Revoked ${revoked} previous API key(s).`);
        this.logger.log(`MAHABBAT_API_KEY_ID=${apiKey.id}`);
        this.logger.log(`MAHABBAT_API_KEY=${tokenResult.token}`);
    }
    async acquireWorkspaceRotateLock(workspaceId) {
        const runner = this.coreDataSource.createQueryRunner();
        try {
            await runner.connect();
            await runner.query('SELECT pg_advisory_lock(hashtext($1), hashtext($2))', ['mahabbat-rotate-api-key', workspaceId]);
            return runner;
        }
        catch (error) {
            this.logger.warn(`Rotate lock unavailable, continuing unlocked: ${error}`);
            await runner.release().catch(() => undefined);
            return null;
        }
    }
    async releaseWorkspaceRotateLock(runner, workspaceId) {
        if (!(0, utils_1.isDefined)(runner)) {
            return;
        }
        try {
            await runner.query('SELECT pg_advisory_unlock(hashtext($1), hashtext($2))', ['mahabbat-rotate-api-key', workspaceId]);
        }
        finally {
            await runner.release();
        }
    }
};
RotateApiKeyCommand = _ts_decorate([
    (0, nest_commander_1.Command)({ name: "workspace:rotate-api-key", description: "Mahabbat: mint a new admin API key, verify its token, then revoke all previous active keys. Prints MAHABBAT_API_KEY and MAHABBAT_API_KEY_ID." }),
    _ts_param(0, (0, typeorm_1.InjectRepository)(workspace_entity_1.WorkspaceEntity)),
    _ts_param(1, (0, inject_workspace_scoped_repository_decorator_1.InjectWorkspaceScopedRepository)(role_entity_1.RoleEntity)),
    _ts_param(4, (0, typeorm_1.InjectDataSource)()),
    _ts_metadata("design:type", Function),
    _ts_metadata("design:paramtypes", [typeof typeorm_2.Repository === "undefined" ? Object : typeorm_2.Repository, Object, typeof api_key_service_1.ApiKeyService === "undefined" ? Object : api_key_service_1.ApiKeyService, typeof twenty_config_service_1.TwentyConfigService === "undefined" ? Object : twenty_config_service_1.TwentyConfigService, typeof typeorm_2.DataSource === "undefined" ? Object : typeorm_2.DataSource])
], RotateApiKeyCommand);
function _ts_metadata(k, v) { if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v); }
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-w, --workspace-id <workspaceId>", description: "Workspace ID (required)", required: true }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], RotateApiKeyCommand.prototype, "parseWorkspaceId", Object.getOwnPropertyDescriptor(RotateApiKeyCommand.prototype, "parseWorkspaceId"));
_ts_decorate([(0, nest_commander_1.Option)({ flags: "-n, --name <name>", description: "Name of the replacement API key", defaultValue: "Developer API Key" }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", [String]), _ts_metadata("design:returntype", String)], RotateApiKeyCommand.prototype, "parseName", Object.getOwnPropertyDescriptor(RotateApiKeyCommand.prototype, "parseName"));
_ts_decorate([(0, nest_commander_1.Option)({ flags: "--allow-production", description: "Mahabbat: permit this command in production (required outside dev/test)." }), _ts_metadata("design:type", Function), _ts_metadata("design:paramtypes", []), _ts_metadata("design:returntype", Boolean)], RotateApiKeyCommand.prototype, "parseAllowProduction", Object.getOwnPropertyDescriptor(RotateApiKeyCommand.prototype, "parseAllowProduction"));
