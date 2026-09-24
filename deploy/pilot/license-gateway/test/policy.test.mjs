import assert from 'node:assert/strict';
import test from 'node:test';
import { isRestrictedRequestAllowed } from '../src/policy.mjs';

const restricted = (surface, method, pathname, { body, query } = {}) => isRestrictedRequestAllowed({
  surface,
  method,
  pathname,
  body: body === undefined ? undefined : Buffer.from(body),
  searchParams: new URLSearchParams(query ? { query } : {}),
});

test('expired CRM allows GraphQL queries and ordinary reads', () => {
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'query { people { edges { node { id } } } }' }) }), true);
  assert.equal(restricted('crm', 'GET', '/rest/people'), true);
  assert.equal(restricted('crm', 'GET', '/graphql', { query: 'query { people { totalCount } }' }), true);
});

test('expired CRM blocks record mutations and non-GraphQL writes', () => {
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'mutation { createPerson(input: {}) { id } }' }) }), false);
  assert.equal(restricted('crm', 'PATCH', '/rest/people/1'), false);
  assert.equal(restricted('crm', 'POST', '/rest/people/export'), false);
});

test('expired CRM permits only explicitly listed authentication mutations', () => {
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'mutation SignIn { signIn(login: "a", password: "b") { tokens { accessToken } } }' }) }), true);
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'mutation { signIn(login: "a", password: "b") { tokens { accessToken } } updatePerson(input: {}) { id } }' }) }), false);
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'mutation { generateApiKeyToken { token } }' }) }), false);
});

test('expired CRM fails closed on ambiguous, malformed, or fragment-hidden mutation operations', () => {
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'mutation { createPerson { id } } fragment Hidden on Mutation { signIn(login: "a", password: "b") { tokens { accessToken } } }' }) }), false);
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'mutation { signIn(login: "a", password: "b") { tokens { accessToken } } ...Hidden } fragment Hidden on Mutation { createPerson { id } }' }) }), false);
  assert.equal(restricted('crm', 'POST', '/graphql', { body: JSON.stringify({ query: 'query A { people { totalCount } } mutation B { createPerson { id } }' }) }), false);
  assert.equal(restricted('crm', 'POST', '/graphql', { body: 'not-json' }), false);
});

test('expired POS allows read-only access and login but blocks POS commands', () => {
  assert.equal(restricted('pos', 'GET', '/api/pos/rest/posOrders'), true);
  assert.equal(restricted('pos', 'GET', '/'), true);
  assert.equal(restricted('pos', 'POST', '/api/pos/auth'), true);
  assert.equal(restricted('pos', 'POST', '/api/pos/command', { body: '{}' }), false);
  assert.equal(restricted('pos', 'DELETE', '/api/pos/rest/posOrders/1'), false);
});
