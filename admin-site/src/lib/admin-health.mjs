const STALE_AFTER_MILLIS = {
  accounts: 8 * 60 * 60 * 1000,
  subscriptions: 8 * 60 * 60 * 1000,
  revenue: 26 * 60 * 60 * 1000
};

function freshness(label, value, threshold, now) {
  const timestamp = value ? Date.parse(value) : Number.NaN;
  return {
    label,
    value: value ?? null,
    stale: !Number.isFinite(timestamp) || now - timestamp > threshold
  };
}

const PROVIDER_LABELS = {
  play_store: 'Google Play',
  app_store: 'App Store',
  razorpay: 'Razorpay'
};

function revenueFreshness(providers, fallback, now) {
  const entries = Object.entries(providers).sort(([left], [right]) =>
    left.localeCompare(right)
  );
  if (entries.length === 0) {
    return [freshness('Revenue', fallback, STALE_AFTER_MILLIS.revenue, now)];
  }
  return entries.map(([provider, status]) => freshness(
    `Revenue · ${PROVIDER_LABELS[provider] ?? provider}`,
    status.updatedAt ?? null,
    STALE_AFTER_MILLIS.revenue,
    now
  ));
}

export function adminHealthSummary(overview, now = Date.now()) {
  const actionable = overview.health.actionable;
  const quarantined = overview.health.quarantined;
  const degradedProviders = Object.entries(overview.health.providers)
    .filter(([, status]) => status.status && status.status !== 'ready')
    .map(([provider]) => provider);
  return {
    actionableCount: actionable.pendingRevenue + actionable.retryingRevenue +
      actionable.deadLetterRevenue + actionable.subscriptionIssues + degradedProviders.length,
    quarantinedCount: quarantined.revenueTransactions + quarantined.subscriptionIssues,
    degradedProviders,
    freshness: [
      freshness('Accounts', overview.totalUsersUpdatedAt, STALE_AFTER_MILLIS.accounts, now),
      freshness('Subscriptions', overview.subscriptions.updatedAt, STALE_AFTER_MILLIS.subscriptions, now),
      ...revenueFreshness(overview.health.providers, overview.revenueUpdatedAt, now)
    ]
  };
}
