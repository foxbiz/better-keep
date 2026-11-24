const assert = require("node:assert/strict");
const test = require("node:test");

const { deliverEmail, wasEmailDelivered } = require("../lib/emailDelivery");

test("emulator email logs complete plaintext without SMTP or secret access", async () => {
	const smtpKeys = [
		"EMAIL_HOST",
		"EMAIL_PORT",
		"EMAIL_SECURE",
		"EMAIL_USER",
		"EMAIL_PASSWORD",
		"EMAIL_FROM",
		"EMAIL_NAME",
	];
	const previous = new Map(smtpKeys.map((key) => [key, process.env[key]]));
	for (const key of smtpKeys) delete process.env[key];

	const logs = [];
	let transporterAccesses = 0;

	try {
		const result = await deliverEmail(
			{
				from: "sender@example.test",
				to: "recipient@example.test",
				subject: "Emulator subject",
				text: "Complete emulator plaintext body",
			},
			{
				isEmulator: true,
				createTransporter: () => {
					transporterAccesses++;
					throw new Error("SMTP/secret access is forbidden in the emulator");
				},
				log: (...values) => logs.push(values.join(" ")),
			},
		);

		assert.equal(result, "logged");
		assert.equal(transporterAccesses, 0);
		assert.match(logs.join("\n"), /sender@example\.test/);
		assert.match(logs.join("\n"), /recipient@example\.test/);
		assert.match(logs.join("\n"), /Emulator subject/);
		assert.match(logs.join("\n"), /Complete emulator plaintext body/);
	} finally {
		for (const [key, value] of previous) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	}
});

test("production email fails without exposing SMTP recipient details to caller logs", async () => {
	const failure = Object.assign(new Error("550 rejected recipient@example.test"), {
		code: "EENVELOPE", response: "Rejected recipient@example.test",
	});

	await assert.rejects(
		deliverEmail(
			{
				from: "sender@example.test",
				to: "recipient@example.test",
				subject: "Production subject",
				text: "Body",
			},
			{
				isEmulator: false,
				createTransporter: () => ({
					sendMail: async () => {
						throw failure;
					},
				}),
			},
		),
		(error) => {
			assert.equal(error.message, "Email delivery failed (EENVELOPE)");
			assert.ok(!JSON.stringify(error).includes("recipient@example.test"));
			assert.ok(!error.stack.includes("recipient@example.test"));
			assert.equal(error.cause, undefined);
			return true;
		},
	);
});

test("only sent and logged deliveries are eligible for welcome-email flags", () => {
	assert.equal(wasEmailDelivered("sent"), true);
	assert.equal(wasEmailDelivered("logged"), true);
	assert.equal(wasEmailDelivered("skipped"), false);
});
