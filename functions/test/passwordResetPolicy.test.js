const assert = require("node:assert/strict");
const test = require("node:test");
const {
	isOperatorManagedPasswordReset,
} = require("../lib/passwordResetPolicy");

test("review password resets are operator managed", () => {
	assert.equal(
		isOperatorManagedPasswordReset(" review@betterkeep.app "),
		true,
	);
	assert.equal(
		isOperatorManagedPasswordReset("REVIEW@BETTERKEEP.APP"),
		true,
	);
	assert.equal(
		isOperatorManagedPasswordReset("ordinary@example.com"),
		false,
	);
	assert.equal(isOperatorManagedPasswordReset(undefined), false);
});
