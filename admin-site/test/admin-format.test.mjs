import assert from 'node:assert/strict';
import test from 'node:test';
import {
  formatMoneyMicros,
  subscriptionLabel,
  subscriptionTone,
  userInitials
} from '../src/lib/admin-format.mjs';

test('formats integer micros without mixing currencies', () => {
  assert.match(formatMoneyMicros('2990000', 'USD'), /2\.99/);
  assert.match(formatMoneyMicros('230000000', 'INR'), /230/);
});

test('summarizes subscription and user display states', () => {
  assert.equal(
    subscriptionLabel({ subscriptionClass: 'paid', renewalState: 'cancelled' }),
    'Paid · ends soon'
  );
  assert.equal(
    subscriptionTone({ disabled: true, subscriptionClass: 'paid', renewalState: 'renewing' }),
    'danger'
  );
  assert.equal(userInitials('Ajit Kumar', 'a@example.com'), 'AK');
  assert.equal(userInitials(null, 'admin@betterkeep.app'), 'AD');
});
