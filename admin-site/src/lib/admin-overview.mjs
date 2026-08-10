export const ADMIN_OVERVIEW_SCHEMA_VERSION = 2;

const PROVIDER_COUNT_FIELDS = [
  'entitled',
  'renewing',
  'cancelledWithAccess',
  'grace',
  'suspended',
  'unmatched'
];

export class AdminOverviewContractError extends Error {
  constructor(message) {
    super(`Admin overview response is incompatible: ${message}`);
    this.name = 'AdminOverviewContractError';
    this.code = 'admin/overview-contract';
  }
}

function record(value, path, optional = false) {
  if (optional && (value === undefined || value === null)) return {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new AdminOverviewContractError(`${path} must be an object.`);
  }
  return value;
}

function requiredString(value, path) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new AdminOverviewContractError(`${path} must be a non-empty string.`);
  }
  return value;
}

function optionalString(value, path) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') {
    throw new AdminOverviewContractError(`${path} must be a string or null.`);
  }
  return value;
}

function requiredCount(value, path) {
  const numeric = Number(value);
  if (!Number.isSafeInteger(numeric) || numeric < 0) {
    throw new AdminOverviewContractError(`${path} must be a non-negative integer.`);
  }
  return numeric;
}

function optionalCount(value, path) {
  return value === undefined || value === null ? 0 : requiredCount(value, path);
}

function moneyList(value, path) {
  if (!Array.isArray(value)) {
    throw new AdminOverviewContractError(`${path} must be a money list.`);
  }
  return value
    .map((entry, index) => {
      const item = record(entry, `${path}[${index}]`);
      const currency = requiredString(item.currency, `${path}[${index}].currency`)
        .trim()
        .toUpperCase();
      const rawAmount = item.amountMicros;
      const amountMicros = typeof rawAmount === 'number' && Number.isSafeInteger(rawAmount)
        ? String(rawAmount)
        : typeof rawAmount === 'string' && /^-?\d+$/.test(rawAmount)
          ? BigInt(rawAmount).toString()
          : null;
      if (amountMicros === null) {
        throw new AdminOverviewContractError(
          `${path}[${index}].amountMicros must be an integer.`
        );
      }
      return { currency, amountMicros };
    })
    .sort((left, right) => left.currency.localeCompare(right.currency));
}

function revenuePeriod(value, path) {
  if (Array.isArray(value)) {
    const gross = moneyList(value, path);
    return {
      gross,
      refunds: [],
      net: gross.map((entry) => ({ ...entry }))
    };
  }
  const period = record(value, path);
  return {
    gross: moneyList(period.gross, `${path}.gross`),
    refunds: moneyList(period.refunds, `${path}.refunds`),
    net: moneyList(period.net, `${path}.net`)
  };
}

function providerCounts(value) {
  const providers = record(value, 'subscriptions.byProvider', true);
  return Object.fromEntries(
    Object.entries(providers)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([provider, rawCounts]) => {
        const counts = record(rawCounts, `subscriptions.byProvider.${provider}`);
        return [
          provider,
          Object.fromEntries(
            PROVIDER_COUNT_FIELDS.map((field) => [
              field,
              optionalCount(counts[field], `subscriptions.byProvider.${provider}.${field}`)
            ])
          )
        ];
      })
  );
}

function revenueCoverage(value) {
  const coverage = record(value, 'revenue.coverage', true);
  return Object.fromEntries(
    Object.entries(coverage)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([provider, rawStatus]) => {
        const status = record(rawStatus, `revenue.coverage.${provider}`);
        return [
          provider,
          {
            startedAt: optionalString(status.startedAt, `revenue.coverage.${provider}.startedAt`),
            lastRecordedAt: optionalString(
              status.lastRecordedAt,
              `revenue.coverage.${provider}.lastRecordedAt`
            )
          }
        ];
      })
  );
}

function providerStatuses(value) {
  const providers = record(value, 'revenuePipeline.providers', true);
  return Object.fromEntries(
    Object.entries(providers)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([provider, rawStatus]) => {
        const status = record(rawStatus, `revenuePipeline.providers.${provider}`);
        return [
          provider,
          {
            ...(typeof status.status === 'string' ? { status: status.status } : {}),
            updatedAt: optionalString(
              status.updatedAt,
              `revenuePipeline.providers.${provider}.updatedAt`
            )
          }
        ];
      })
  );
}

/**
 * Converts the current overview response and the known legacy revenue response
 * into one strict, deterministic shape. Unknown financial shapes fail closed.
 */
export function normalizeAdminOverview(value) {
  const overview = record(value, 'overview');
  if (
    overview.schemaVersion !== undefined &&
    overview.schemaVersion !== 1 &&
    overview.schemaVersion !== ADMIN_OVERVIEW_SCHEMA_VERSION
  ) {
    throw new AdminOverviewContractError(
      `schema version ${String(overview.schemaVersion)} is unsupported.`
    );
  }
  const subscriptions = record(overview.subscriptions, 'subscriptions', true);
  const revenue = record(overview.revenue, 'revenue');
  const pipeline = record(overview.revenuePipeline, 'revenuePipeline', true);

  return {
    schemaVersion: ADMIN_OVERVIEW_SCHEMA_VERSION,
    generatedAt: requiredString(overview.generatedAt, 'generatedAt'),
    totalUsersUpdatedAt: optionalString(overview.totalUsersUpdatedAt, 'totalUsersUpdatedAt'),
    revenueUpdatedAt: optionalString(overview.revenueUpdatedAt, 'revenueUpdatedAt'),
    totalUsers: requiredCount(overview.totalUsers, 'totalUsers'),
    paidUsers: requiredCount(overview.paidUsers, 'paidUsers'),
    cancelledUsers: requiredCount(overview.cancelledUsers, 'cancelledUsers'),
    subscriptions: {
      updatedAt: optionalString(subscriptions.updatedAt, 'subscriptions.updatedAt'),
      byProvider: providerCounts(subscriptions.byProvider)
    },
    revenue: {
      currentMonth: requiredString(revenue.currentMonth, 'revenue.currentMonth'),
      timezone: typeof revenue.timezone === 'string' && revenue.timezone
        ? revenue.timezone
        : 'UTC',
      lifetime: revenuePeriod(revenue.lifetime, 'revenue.lifetime'),
      monthly: revenuePeriod(revenue.monthly, 'revenue.monthly'),
      coverage: revenueCoverage(revenue.coverage)
    },
    revenuePipeline: {
      pending: optionalCount(pipeline.pending, 'revenuePipeline.pending'),
      retrying: optionalCount(pipeline.retrying, 'revenuePipeline.retrying'),
      deadLetter: optionalCount(pipeline.deadLetter, 'revenuePipeline.deadLetter'),
      excludedTransactions: optionalCount(
        pipeline.excludedTransactions,
        'revenuePipeline.excludedTransactions'
      ),
      unmatchedSubscriptions: optionalCount(
        pipeline.unmatchedSubscriptions,
        'revenuePipeline.unmatchedSubscriptions'
      ),
      providers: providerStatuses(pipeline.providers)
    }
  };
}
