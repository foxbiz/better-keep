export const BILLING_ACTIVITY_TYPES = [
  'purchase',
  'renewal',
  'recovery',
  'restart',
  'cancellation',
  'grace',
  'hold',
  'pause',
  'deferred',
  'plan_change',
  'revocation',
  'expiration',
  'charge',
  'refund',
  'state_change'
];

export const BILLING_PROVIDERS = ['play_store', 'app_store', 'razorpay'];

const EVENT_LABELS = {
  purchase: 'New purchase',
  renewal: 'Renewal',
  recovery: 'Recovered',
  restart: 'Restarted',
  cancellation: 'Cancelled',
  grace: 'Grace period',
  hold: 'On hold',
  pause: 'Paused',
  deferred: 'Deferred',
  plan_change: 'Plan changed',
  revocation: 'Revoked',
  expiration: 'Expired',
  charge: 'Charge',
  refund: 'Refund',
  state_change: 'State updated'
};

const PROVIDER_LABELS = {
  play_store: 'Google Play',
  app_store: 'App Store',
  razorpay: 'Razorpay'
};

export class AdminBillingActivityContractError extends Error {
  constructor(message) {
    super(`Admin billing activity response is incompatible: ${message}`);
    this.name = 'AdminBillingActivityContractError';
    this.code = 'admin/billing-activity-contract';
  }
}

function record(value, path) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new AdminBillingActivityContractError(`${path} must be an object.`);
  }
  return value;
}

function requiredString(value, path) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new AdminBillingActivityContractError(`${path} must be a non-empty string.`);
  }
  return value;
}

function optionalString(value, path) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') {
    throw new AdminBillingActivityContractError(`${path} must be a string or null.`);
  }
  return value;
}

function oneOf(value, allowed, path) {
  const result = requiredString(value, path);
  if (!allowed.includes(result)) {
    throw new AdminBillingActivityContractError(`${path} is unsupported.`);
  }
  return result;
}

function requiredDate(value, path) {
  const result = requiredString(value, path);
  if (!Number.isFinite(Date.parse(result))) {
    throw new AdminBillingActivityContractError(`${path} must be an ISO date.`);
  }
  return result;
}

function activity(value, index) {
  const path = `activities[${index}]`;
  const item = record(value, path);
  const customer = item.customer === null || item.customer === undefined
    ? null
    : record(item.customer, `${path}.customer`);
  const rawAmount = item.amountMicros;
  const amountMicros = rawAmount === null || rawAmount === undefined
    ? null
    : typeof rawAmount === 'string' && /^\d+$/.test(rawAmount)
      ? BigInt(rawAmount).toString()
      : null;
  if (rawAmount !== null && rawAmount !== undefined && amountMicros === null) {
    throw new AdminBillingActivityContractError(`${path}.amountMicros must be a non-negative integer string or null.`);
  }
  const rawCurrency = optionalString(item.currency, `${path}.currency`);
  const currency = rawCurrency?.trim().toUpperCase() ?? null;
  if ((amountMicros === null) !== (currency === null)) {
    throw new AdminBillingActivityContractError(`${path} amount and currency must be supplied together.`);
  }
  if (currency !== null && !/^[A-Z]{3}$/.test(currency)) {
    throw new AdminBillingActivityContractError(`${path}.currency must be an ISO currency code.`);
  }
  if (item.origin !== undefined && item.origin !== 'live' && item.origin !== 'historical') {
    throw new AdminBillingActivityContractError(`${path}.origin is unsupported.`);
  }
  return {
    id: requiredString(item.id, `${path}.id`),
    provider: oneOf(item.provider, BILLING_PROVIDERS, `${path}.provider`),
    eventType: oneOf(item.eventType, BILLING_ACTIVITY_TYPES, `${path}.eventType`),
    occurredAt: requiredDate(item.occurredAt, `${path}.occurredAt`),
    origin: item.origin === 'historical' ? 'historical' : 'live',
    billingPeriod: optionalString(item.billingPeriod, `${path}.billingPeriod`),
    environment: optionalString(item.environment, `${path}.environment`) ?? 'unknown',
    subscriptionState: optionalString(item.subscriptionState, `${path}.subscriptionState`),
    entitlementState: optionalString(item.entitlementState, `${path}.entitlementState`),
    amountMicros,
    currency,
    revenueKind: optionalString(item.revenueKind, `${path}.revenueKind`),
    revenueStatus: optionalString(item.revenueStatus, `${path}.revenueStatus`),
    customer: customer
      ? {
          uid: requiredString(customer.uid, `${path}.customer.uid`),
          email: optionalString(customer.email, `${path}.customer.email`),
          displayName: optionalString(customer.displayName, `${path}.customer.displayName`)
        }
      : null
  };
}

export function normalizeAdminBillingActivity(value) {
  const response = record(value, 'response');
  if (!Array.isArray(response.activities)) {
    throw new AdminBillingActivityContractError('activities must be an array.');
  }
  return {
    activities: response.activities.map(activity),
    nextCursor: optionalString(response.nextCursor, 'nextCursor')
  };
}

export function billingActivityLabel(eventType) {
  return EVENT_LABELS[eventType] ?? 'Billing update';
}

export function billingProviderLabel(provider) {
  return PROVIDER_LABELS[provider] ?? 'Billing provider';
}

export function billingActivityTone(eventType) {
  if (['purchase', 'renewal', 'recovery', 'restart', 'charge'].includes(eventType)) return 'success';
  if (['cancellation', 'grace', 'hold', 'pause', 'deferred'].includes(eventType)) return 'warning';
  if (['revocation', 'expiration', 'refund'].includes(eventType)) return 'danger';
  return 'info';
}
