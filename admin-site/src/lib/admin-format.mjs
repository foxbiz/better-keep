export function formatMoneyMicros(amountMicros, currency) {
  const numeric = Number(amountMicros);
  if (!Number.isFinite(numeric)) return '—';
  try {
    return new Intl.NumberFormat('en', {
      style: 'currency',
      currency,
      maximumFractionDigits: 2
    }).format(numeric / 1_000_000);
  } catch {
    return `${currency} ${(numeric / 1_000_000).toFixed(2)}`;
  }
}

export function formatAdminDate(value, includeTime = false) {
  if (!value) return 'Never';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'Unknown';
  return new Intl.DateTimeFormat('en', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    ...(includeTime
      ? { hour: '2-digit', minute: '2-digit', timeZoneName: 'short' }
      : {})
  }).format(date);
}

export function userInitials(displayName, email) {
  const source = String(displayName || email || '?').trim();
  const parts = source.split(/\s+/).filter(Boolean);
  if (parts.length > 1) return `${parts[0][0]}${parts.at(-1)[0]}`.toUpperCase();
  return source.slice(0, 2).toUpperCase();
}

export function subscriptionLabel(user) {
  if (user.subscriptionClass === 'paid') {
    return user.renewalState === 'cancelled' ? 'Paid · ends soon' : 'Paid · renewing';
  }
  if (user.subscriptionClass === 'trial') return 'Pro trial';
  return 'Free';
}

export function subscriptionTone(user) {
  if (user.disabled) return 'danger';
  if (user.subscriptionClass === 'paid' && user.renewalState === 'cancelled') {
    return 'warning';
  }
  if (user.subscriptionClass === 'paid') return 'success';
  if (user.subscriptionClass === 'trial') return 'info';
  return 'neutral';
}
