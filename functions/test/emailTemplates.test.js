const assert = require("node:assert/strict");
const test = require("node:test");
const {
	generateTransactionalEmail,
	generateOtpEmailHtml,
	generateOtpEmailText,
	formatEmailDate,
} = require("../lib/email_templates");

test("email dates stay UTC-labelled across host time zones and midnight boundaries", () => {
	const previous = process.env.TZ;
	try {
		for (const zone of ["UTC", "Asia/Kolkata", "America/Los_Angeles"]) {
			process.env.TZ = zone;
			assert.equal(formatEmailDate(new Date("2026-11-24T00:15:00Z")), "24 Nov 2026 (UTC)");
			assert.equal(formatEmailDate(new Date("2026-11-24T23:45:00Z")), "24 Nov 2026 (UTC)");
		}
		assert.equal(formatEmailDate(new Date("invalid")), "N/A");
	} finally {
		if (previous === undefined) delete process.env.TZ;
		else process.env.TZ = previous;
	}
});

test("transactional content is escaped in HTML and preserved in plain text", () => {
	const input = '<img src=x onerror="alert(1)"> & Ada';
	const { html, text } = generateTransactionalEmail({
		title: input,
		paragraphs: [input],
		details: [{ label: "Trial ends", value: input }],
		list: { title: "Included", items: [input] },
		notice: { title: "Security", text: input },
		action: { label: "Manage subscription", url: "https://betterkeep.app?a=1&b=2" },
	});
	assert.ok(!html.includes(input));
	assert.ok(html.includes("&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; Ada"));
	assert.ok(text.includes(input));
	assert.ok(html.includes('href="https://betterkeep.app?a=1&amp;b=2"'));
	assert.ok(text.includes("Manage subscription: https://betterkeep.app?a=1&b=2"));
	assert.ok(text.includes("Trial ends:"));
	assert.ok(text.includes("support@betterkeep.app"));
});

test("OTP variants retain the complete code, expiry and security warning", () => {
	for (const theme of ["primary", "warning", "danger"]) {
		const config = {
			title: "Confirm your request",
			description: "Enter this code in Better Keep.",
			otp: "012345",
			theme,
			securityNote: "Encrypted notes will become permanently inaccessible.",
			expiresInMinutes: 5,
		};
		for (const content of [generateOtpEmailHtml(config), generateOtpEmailText(config)]) {
			assert.ok(content.includes("012345"));
			assert.ok(content.includes("5 minutes"));
			assert.ok(content.includes(config.securityNote));
		}
		const { securityNote, expiresInMinutes, ...minimal } = config;
		assert.ok(generateOtpEmailText(minimal).includes("10 minutes"));
		assert.ok(!generateOtpEmailHtml(minimal).includes("Security note"));
	}
});

test("unsafe action schemes are rejected; support email actions work", () => {
	assert.throws(() => generateTransactionalEmail({
		title: "Update", paragraphs: [], action: { label: "Open", url: "javascript:alert(1)" },
	}), /HTTPS or mailto/);
	const email = generateTransactionalEmail({
		title: "Need help?", paragraphs: [],
		action: { label: "Contact support", url: "mailto:support@betterkeep.app" },
	});
	assert.ok(email.html.includes('href="mailto:support@betterkeep.app"'));
	assert.ok(email.text.includes("Contact support: mailto:support@betterkeep.app"));
});
