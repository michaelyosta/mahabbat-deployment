import assert from 'node:assert/strict';
import test from 'node:test';
import { parsePlanCounts, parseSeedPreview } from '../app/preview-counts.mjs';

test('fresh install reports all 1346 additions from the actual Twenty CLI summary', () => {
  assert.deepEqual(parsePlanCounts(['# navigationMenuItem will be created', 'Plan: 1346 to add, 0 to change, 0 to destroy.']),
    { create: 1346, update: 0, remove: 0, found: true });
});
test('removals remain visible, including colored CLI output', () => {
  assert.deepEqual(parsePlanCounts(['\x1b[32mPlan: 3 to add, 2 to change, 7 to destroy.\x1b[0m']),
    { create: 3, update: 2, remove: 7, found: true });
});
test('unknown output cannot be mistaken for a safe zero-change plan', () => {
  assert.deepEqual(parsePlanCounts(['Unrecognized plan output']),
    { create: null, update: null, remove: null, found: false });
});
test('a recognized no-op plan is distinct from unknown output', () => {
  assert.equal(parsePlanCounts(['Plan: 0 to add, 0 to change, 0 to destroy.']).found, true);
});
test('seed preview recognizes the venue counts used for installation', () => {
  assert.deepEqual(parseSeedPreview(['3 zones, 11 tables, 30 menu items, 2 payment methods, 2 POS staff']),
    { zones: 3, tables: 11, dishes: 30, staff: 2, found: true });
});
test('seed output without a summary does not authorize a fabricated preview', () => {
  assert.equal(parseSeedPreview(['Seed output unavailable']).found, false);
});
