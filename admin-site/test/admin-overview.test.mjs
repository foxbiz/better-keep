import assert from 'node:assert/strict';
import test from 'node:test';
import {
  AdminOverviewContractError,
  normalizeAdminOverview
} from '../src/lib/admin-overview.mjs';

function baseOverview(overrides = {}) {
  return {
    schemaVersion: 2,
    generatedAt: '2026-08-09T04:20:00.000Z',
    totalUsersUpdatedAt: null,
    revenueUpdatedAt: null,
    totalUsers: 10,
    paidUsers: 4,
    cancelledUsers: 1,
    subscriptions: { byProvider: {}, updatedAt: null },
    revenue: {
      currentMonth: '2026-08',
      timezone: 'UTC',
      lifetime: { gross: [], refunds: [], net: [] },
      monthly: { gross: [], refunds: [], net: [] },
      coverage: {}
    },
    revenuePipeline: {},
    ...overrides
  };
}

test('normalizes the current overview contract and sorts currencies deterministically', () => {
  const overview = baseOverview();
  overview.revenue.monthly.gross = [
    { currency: 'usd', amountMicros: '2990000' },
    { currency: 'INR', amountMicros: 230000000 }
  ];
  overview.revenue.monthly.refunds = [{ currency: 'USD', amountMicros: '19990000' }];
  overview.revenue.monthly.net = [{ currency: 'USD', amountMicros: '-17000000' }];

  const normalized = normalizeAdminOverview(overview);

  assert.equal(normalized.schemaVersion, 2);
  assert.deepEqual(normalized.revenue.monthly.gross, [
    { currency: 'INR', amountMicros: '230000000' },
    { currency: 'USD', amountMicros: '2990000' }
  ]);
  assert.deepEqual(normalized.revenue.monthly.net, [
    { currency: 'USD', amountMicros: '-17000000' }
  ]);
});

test('translates the known legacy revenue arrays without mixing currencies', () => {
  const overview = baseOverview({ schemaVersion: 1 });
  const monthly = [{ currency: 'USD', amountMicros: '2990000' }];
  const lifetime = [{ currency: 'INR', amountMicros: '1855000000' }];
  overview.revenue = {
    currentMonth: '2026-08',
    timezone: 'UTC',
    monthly,
    lifetime,
    coverage: {}
  };

  const normalized = normalizeAdminOverview(overview);

  assert.deepEqual(normalized.revenue.monthly, {
    gross: monthly,
    refunds: [],
    net: monthly
  });
  assert.deepEqual(normalized.revenue.lifetime, {
    gross: lifetime,
    refunds: [],
    net: lifetime
  });
  assert.notEqual(normalized.revenue.monthly.gross, normalized.revenue.monthly.net);
});

test('defaults missing optional subscription and pipeline fields', () => {
  const normalized = normalizeAdminOverview(baseOverview({
    subscriptions: {
      byProvider: { play_store: { entitled: 4 } }
    },
    revenuePipeline: undefined
  }));

  assert.deepEqual(normalized.subscriptions.byProvider.play_store, {
    entitled: 4,
    renewing: 0,
    cancelledWithAccess: 0,
    grace: 0,
    suspended: 0,
    unmatched: 0
  });
  assert.deepEqual(normalized.revenuePipeline, {
    pending: 0,
    retrying: 0,
    deadLetter: 0,
    excludedTransactions: 0,
    unmatchedSubscriptions: 0,
    providers: {}
  });
});

test('rejects unknown financial shapes with an actionable contract error', () => {
  const overview = baseOverview();
  overview.revenue.monthly = { currencies: { USD: 2990000 } };

  assert.throws(
    () => normalizeAdminOverview(overview),
    (error) => error instanceof AdminOverviewContractError &&
      /revenue\.monthly\.gross must be a money list/.test(error.message)
  );
});

test('rejects unsupported overview schema versions', () => {
  assert.throws(
    () => normalizeAdminOverview(baseOverview({ schemaVersion: 3 })),
    /schema version 3 is unsupported/
  );
});
