import { Kind, parse } from 'graphql';

const AUTH_MUTATIONS = new Set([
  'getLoginTokenFromCredentials',
  'signIn',
  'verifyEmailAndGetLoginToken',
  'verifyEmailAndGetWorkspaceAgnosticToken',
  'getAuthTokensFromOTP',
  'signUp',
  'signUpInWorkspace',
  'signUpInNewWorkspace',
  'getAuthTokensFromLoginToken',
  'getAuthTokensFromSSOExchangeToken',
  'renewToken',
  'signOut',
  'emailPasswordResetLink',
  'updatePasswordViaResetToken',
]);

const safeMethod = (method) => ['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase());

const graphQlDocumentAllowed = (query, operationName) => {
  if (typeof query !== 'string' || query.length === 0 || query.length > 2 * 1024 * 1024) return false;
  try {
    const document = parse(query, { noLocation: true });
    const operations = document.definitions.filter((definition) => definition.kind === Kind.OPERATION_DEFINITION);
    let selected;
    if (operationName) {
      selected = operations.filter((operation) => operation.name?.value === operationName);
    } else if (operations.length === 1) {
      selected = operations;
    } else {
      return false;
    }
    if (selected.length !== 1) return false;
    const operation = selected[0];
    if (operation.operation === 'query') return true;
    if (operation.operation !== 'mutation') return false;
    if (operation.selectionSet.selections.some((selection) => selection.kind !== Kind.FIELD)) return false;
    const rootFields = operation.selectionSet.selections;
    return rootFields.length > 0 && rootFields.every((field) => AUTH_MUTATIONS.has(field.name.value));
  } catch {
    return false;
  }
};

const fromHttpBody = (body) => {
  if (!body || body.length === 0) return false;
  try {
    const input = JSON.parse(body.toString('utf8'));
    const requests = Array.isArray(input) ? input : [input];
    return requests.length > 0 && requests.every((request) =>
      request && typeof request === 'object' && graphQlDocumentAllowed(request.query, request.operationName),
    );
  } catch {
    return false;
  }
};

export function isRestrictedRequestAllowed({ method, pathname, searchParams, body, surface }) {
  const verb = method.toUpperCase();
  if (surface === 'pos') {
    if (safeMethod(verb)) return true;
    return verb === 'POST' && pathname === '/api/pos/auth';
  }

  if (pathname === '/graphql') {
    if (verb === 'GET') {
      return graphQlDocumentAllowed(searchParams.get('query'), searchParams.get('operationName'));
    }
    if (verb !== 'POST') return false;
    return fromHttpBody(body);
  }

  if (safeMethod(verb)) return true;
  return false;
}

export const describeRestrictedMessage = (state) => {
  if (state.status === 'LICENSE_EXPIRED') {
    return 'Лицензия Mahabbat истекла. Доступен просмотр данных и создание резервной копии; рабочие изменения заблокированы.';
  }
  if (state.status === 'CLOCK_ROLLBACK') {
    return 'Проверьте дату и время компьютера. Рабочие изменения временно заблокированы.';
  }
  if (state.status === 'ACTIVE') return '';
  return 'Лицензия Mahabbat не активна. Доступен ограниченный режим; рабочие изменения заблокированы.';
};
