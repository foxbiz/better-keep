import { product } from '../data/product.ts';
import { loadPublicUserMetric } from './public-stats.ts';

// Runs while the site is built, never in the browser, so the count is part of
// the HTML. It refreshes with each website deploy.
export const buildUserMetric = loadPublicUserMetric({
  endpoint: product.publicStatsUrl,
  timeoutMs: 4000,
  // A cold start or network blip would otherwise hide the count until the next deploy.
  maxAttempts: 2
}).then(({ metric }) => {
  if (!metric) console.warn('User count unavailable; building the homepage without it.');
  return metric;
});
