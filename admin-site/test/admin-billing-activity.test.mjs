import assert from 'node:assert/strict';
import test from 'node:test';
import {
  AdminBillingActivityContractError,
  billingActivityLabel,
  billingActivityTone,
  normalizeAdminBillingActivity
} from '../src/lib/admin-billing-activity.mjs';

test('normalizes paginated activity without mixing currencies', () => {
  const result = normalizeAdminBillingActivity({
    activities: [
      {
        id: 'one',
        provider: 'play_store',
        eventType: 'renewal',
        occurredAt: '2026-08-15T10:00:00.000Z',
        origin: 'live',
        amountMicros: '2990000',
        currency: 'eur',
        customer: { uid: 'user-one', email: 'a@example.com', displayName: null }
      },
      {
        id: 'two',
        provider: 'app_store',
        eventType: 'purchase',
        occurredAt: '2026-08-15T09:00:00.000Z',
        origin: 'historical',
        amountMicros: '2990000',
        currency: 'usd',
        customer: null
      }
    ],
    nextCursor: 'cursor'
  });

  assert.equal(result.activities[0].currency, 'EUR');
  assert.equal(result.activities[1].currency, 'USD');
  assert.equal(result.activities[1].origin, 'historical');
  assert.equal(result.nextCursor, 'cursor');
});

test('distinguishes new purchases and renewals in labels', () => {
  assert.equal(billingActivityLabel('purchase'), 'New purchase');
  assert.equal(billingActivityLabel('renewal'), 'Renewal');
  assert.equal(billingActivityTone('refund'), 'danger');
});

test('rejects unsupported providers, event types, and partial money values', () => {
  const base = {
    id: 'one',
    provider: 'play_store',
    eventType: 'purchase',
    occurredAt: '2026-08-15T10:00:00.000Z',
    amountMicros: null,
    currency: null,
    customer: null
  };
  assert.throws(
    () => normalizeAdminBillingActivity({ activities: [{ ...base, provider: 'other' }] }),
    AdminBillingActivityContractError
  );
  assert.throws(
    () => normalizeAdminBillingActivity({ activities: [{ ...base, eventType: 'unknown' }] }),
    AdminBillingActivityContractError
  );
  assert.throws(
    () => normalizeAdminBillingActivity({ activities: [{ ...base, currency: 'EUR' }] }),
    /amount and currency/
  );
  assert.throws(
    () => normalizeAdminBillingActivity({ activities: [{ ...base, occurredAt: 'not-a-date' }] }),
    /must be an ISO date/
  );
  assert.throws(
    () => normalizeAdminBillingActivity({ activities: [{ ...base, origin: 'replayed' }] }),
    /origin is unsupported/
  );
});
