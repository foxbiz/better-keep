import assert from 'node:assert/strict';
import test from 'node:test';
import { adminHealthSummary } from '../src/lib/admin-health.mjs';

test('keeps actionable, quarantined, and stale health separate', () => {
  const now = Date.parse('2026-08-15T12:00:00.000Z');
  const result = adminHealthSummary({
    totalUsersUpdatedAt: '2026-08-15T10:00:00.000Z',
    revenueUpdatedAt: '2026-08-13T10:00:00.000Z',
    subscriptions: { updatedAt: '2026-08-15T09:00:00.000Z' },
    health: {
      actionable: {
        pendingRevenue: 0,
        retryingRevenue: 1,
        deadLetterRevenue: 0,
        subscriptionIssues: 2
      },
      quarantined: { revenueTransactions: 10, subscriptionIssues: 26 },
      providers: {
        play_store: { status: 'ready', updatedAt: '2026-08-15T11:00:00.000Z' },
        razorpay: { status: 'failed' }
      }
    }
  }, now);

  assert.equal(result.actionableCount, 4);
  assert.equal(result.quarantinedCount, 36);
  assert.deepEqual(result.degradedProviders, ['razorpay']);
  assert.equal(
    result.freshness.find((item) => item.label === 'Revenue · Google Play').stale,
    false
  );
  assert.equal(
    result.freshness.find((item) => item.label === 'Revenue · Razorpay').stale,
    true
  );
  assert.equal(result.freshness.find((item) => item.label === 'Subscriptions').stale, false);
});

test('marks missing or old reconciliation timestamps as stale', () => {
  const result = adminHealthSummary({
    totalUsersUpdatedAt: null,
    revenueUpdatedAt: '2026-08-13T10:00:00.000Z',
    subscriptions: { updatedAt: '2026-08-13T10:00:00.000Z' },
    health: {
      actionable: {
        pendingRevenue: 0,
        retryingRevenue: 0,
        deadLetterRevenue: 0,
        subscriptionIssues: 0
      },
      quarantined: { revenueTransactions: 0, subscriptionIssues: 0 },
      providers: {}
    }
  }, Date.parse('2026-08-15T12:00:00.000Z'));

  assert.equal(result.freshness.every((item) => item.stale), true);
});
