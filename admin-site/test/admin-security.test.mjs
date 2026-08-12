import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

function luminance(hex) {
  const channels = hex.match(/[0-9a-f]{2}/gi).map((value) => Number.parseInt(value, 16) / 255);
  const linear = channels.map((value) =>
    value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
  );
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(left, right) {
  const values = [luminance(left), luminance(right)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test('login helper text meets normal-text WCAG contrast', () => {
  assert.ok(contrast('#9b9b94', '#090a0c') >= 4.5);
});

test('admin source has no personal identifier, analytics, or local persistence', async () => {
  const [component, script] = await Promise.all([
    readFile('src/components/AdminDashboard.astro', 'utf8'),
    readFile('src/scripts/admin-dashboard.ts', 'utf8')
  ]);
  const source = `${component}\n${script}`;
  assert.doesNotMatch(source, /dellevenjack/i);
  assert.doesNotMatch(source, /plausible\.io/i);
  assert.doesNotMatch(source, /browserLocalPersistence/);
  assert.doesNotMatch(component, /name=["'](?:email|password)["']/i);
  assert.match(script, /browserSessionPersistence/);
  assert.match(script, /TotpMultiFactorGenerator/);
  assert.match(script, /initializeAppCheck/);
  assert.match(
    script,
    /const token = await getAppCheckToken\(appCheck, true\)/,
    'startup must verify App Check before creating callable clients'
  );
  assert.match(
    script,
    /enterDashboard\(user\)\.catch\(\(error\) => handleAuthenticatedFailure\(error, user\)\)/
  );
  assert.match(
    script,
    /if \(resolution\.ok\) \{[\s\S]{0,80}pendingMfaResolver = null;[\s\S]{0,100}else \{[\s\S]{0,80}mfaMessage\.textContent/
  );
});
