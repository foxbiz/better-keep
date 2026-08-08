import assert from "node:assert/strict";
import {access, readFile, readdir} from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import {webcrypto} from "node:crypto";
import {
	SHARE_STATES,
	classifyRequestRecord,
	classifyShareRecord,
	createByteBudget,
	createSingleFlight,
	decodeBase64,
	decryptShareBytes,
	decryptShareText,
	detectPlatform,
	getLocalPreviewState,
	isSafeAttachmentPath,
	loadShareRequestState,
	mapWithConcurrency,
	parseShareLocation,
	readResponseBytesWithLimit,
} from "../site/src/lib/share-viewer.mjs";

const repositoryRoot = process.cwd();
const siteSource = path.join(repositoryRoot, "site", "src");

function toBase64Url(bytes) {
	return Buffer.from(bytes)
		.toString("base64")
		.replaceAll("+", "-")
		.replaceAll("/", "_")
		.replace(/=+$/, "");
}

async function importEncryptionKey(bytes) {
	return webcrypto.subtle.importKey("raw", bytes, {name: "AES-GCM"}, false, [
		"encrypt",
	]);
}

test("shared-note URLs keep the share ID and fragment key contract", () => {
	assert.deepEqual(
		parseShareLocation({pathname: "/s/A1b2C3", hash: "#secret_key-1"}),
		{shareId: "A1b2C3", shareKey: "secret_key-1"},
	);
	assert.deepEqual(parseShareLocation({pathname: "/s/A1b2C3/", hash: ""}), {
		shareId: "A1b2C3",
		shareKey: null,
	});
	assert.deepEqual(parseShareLocation({pathname: "/s/invalid-id", hash: "#key"}), {
		shareId: null,
		shareKey: "key",
	});
	assert.deepEqual(parseShareLocation({pathname: "/s/", hash: "#key"}), {
		shareId: null,
		shareKey: "key",
	});
});

test("base64url keys decode exactly and reject malformed input", () => {
	const bytes = Uint8Array.from([251, 255, 0, 17, 34]);
	assert.deepEqual(decodeBase64(toBase64Url(bytes)), bytes);
	assert.deepEqual(decodeBase64("-_8AESI="), bytes);
	assert.throws(() => decodeBase64("not base64!"), /Invalid base64/);
	assert.throws(() => decodeBase64("AQ", 32), /Expected 32 decoded bytes/);
});

test("AES-GCM note text remains compatible with URL-fragment keys", async () => {
	const keyBytes = webcrypto.getRandomValues(new Uint8Array(32));
	const nonce = webcrypto.getRandomValues(new Uint8Array(12));
	const key = await importEncryptionKey(keyBytes);
	const plaintext = "# Private note\n\nEncrypted ✓";
	const ciphertext = new Uint8Array(
		await webcrypto.subtle.encrypt(
			{name: "AES-GCM", iv: nonce},
			key,
			new TextEncoder().encode(plaintext),
		),
	);

	assert.equal(
		await decryptShareText(
			toBase64Url(ciphertext),
			toBase64Url(nonce),
			toBase64Url(keyBytes),
			webcrypto,
		),
		plaintext,
	);
	await assert.rejects(
		decryptShareText("AQ", toBase64Url(nonce), toBase64Url(keyBytes), webcrypto),
		/malformed/,
	);
});

test("AES-GCM attachments retain nonce-prefixed binary compatibility", async () => {
	const keyBytes = webcrypto.getRandomValues(new Uint8Array(32));
	const nonce = webcrypto.getRandomValues(new Uint8Array(12));
	const key = await importEncryptionKey(keyBytes);
	const plaintext = Uint8Array.from([0, 1, 2, 127, 128, 254, 255]);
	const ciphertext = new Uint8Array(
		await webcrypto.subtle.encrypt(
			{name: "AES-GCM", iv: nonce},
			key,
			plaintext,
		),
	);
	const payload = new Uint8Array(nonce.length + ciphertext.length);
	payload.set(nonce);
	payload.set(ciphertext, nonce.length);

	assert.deepEqual(
		await decryptShareBytes(payload, toBase64Url(keyBytes), webcrypto),
		plaintext,
	);
	await assert.rejects(
		decryptShareBytes(new Uint8Array(28), toBase64Url(keyBytes), webcrypto),
		/malformed/,
	);
});

test("share and access-request records classify every supported state", () => {
	const now = new Date("2026-08-05T12:00:00Z");
	assert.equal(
		classifyShareRecord({status: "active", expires_at: "2026-08-06T00:00:00Z"}, now),
		"active",
	);
	assert.equal(
		classifyShareRecord(
			{status: "active", expires_at: {toDate: () => new Date("2026-08-04T00:00:00Z")}},
			now,
		),
		"expired",
	);
	assert.equal(classifyShareRecord({status: "expired"}, now), "expired");
	assert.equal(classifyShareRecord({status: "revoked"}, now), "revoked");
	assert.equal(classifyShareRecord({status: "active"}, now), "invalid");
	assert.equal(classifyShareRecord(null, now), "invalid");

	for (const status of ["approved", "denied", "pending"]) {
		assert.equal(classifyRequestRecord({status}), status);
	}
	assert.equal(classifyRequestRecord(null), "missing");
	assert.equal(classifyRequestRecord({status: "deleted"}), "invalid");
});

test("platform, preview, and attachment helpers reject unsafe variants", () => {
	assert.equal(detectPlatform("Mozilla Android"), "android");
	assert.equal(detectPlatform("Mozilla iPhone"), "ios");
	assert.equal(detectPlatform("Mozilla Macintosh"), "macos");
	assert.equal(detectPlatform("Mozilla Windows NT"), "windows");
	assert.equal(detectPlatform("Mozilla X11 Linux"), "linux");
	assert.equal(detectPlatform("Some Browser"), "web");

	assert.ok(isSafeAttachmentPath("shares/user_1/A1b2/attachments/photo-1.webp"));
	assert.equal(isSafeAttachmentPath("../secrets"), false);
	assert.equal(isSafeAttachmentPath("shares/u/share/attachments/a/extra"), false);

	assert.equal(
		getLocalPreviewState({hostname: "127.0.0.1", search: "?share-state=pending"}),
		"pending",
	);
	assert.equal(
		getLocalPreviewState({hostname: "betterkeep.app", search: "?share-state=content"}),
		null,
	);
	assert.equal(
		getLocalPreviewState({hostname: "localhost", search: "?share-state=unknown"}),
		null,
	);
	assert.deepEqual(SHARE_STATES, [
		"loading",
		"request",
		"pending",
		"content",
		"expired",
		"revoked",
		"denied",
		"notFound",
		"error",
	]);
});

function streamingResponse(chunks, {contentLength} = {}) {
	let index = 0;
	let cancelled = false;
	const reader = {
		async read() {
			if (cancelled || index >= chunks.length) return {done: true};
			return {done: false, value: Uint8Array.from(chunks[index++])};
		},
		async cancel() {
			cancelled = true;
		},
		releaseLock() {},
	};
	return {
		response: {
			headers: new Headers(
				contentLength === undefined
					? {}
					: {"content-length": String(contentLength)},
			),
			body: {
				getReader: () => reader,
				async cancel() {
					cancelled = true;
				},
			},
		},
		get cancelled() {
			return cancelled;
		},
	};
}

test("bounded attachment reader rejects oversized declared lengths", async () => {
	const stream = streamingResponse([], {contentLength: 11});
	await assert.rejects(
		readResponseBytesWithLimit(stream.response, {maxBytes: 10}),
		/too large/,
	);
	assert.equal(stream.cancelled, true);
});

test("bounded attachment reader stops streams without a trustworthy length", async () => {
	const stream = streamingResponse([[1, 2, 3], [4, 5, 6]]);
	await assert.rejects(
		readResponseBytesWithLimit(stream.response, {maxBytes: 5}),
		/too large/,
	);
	assert.equal(stream.cancelled, true);
});

test("bounded attachment reader distrusts a misleading short length", async () => {
	const stream = streamingResponse([[1, 2, 3], [4, 5, 6]], {contentLength: 2});
	await assert.rejects(
		readResponseBytesWithLimit(stream.response, {maxBytes: 5}),
		/too large/,
	);
	assert.equal(stream.cancelled, true);
});

test("bounded attachment reader accepts the exact limit", async () => {
	const stream = streamingResponse([[1, 2], [3, 4, 5]], {contentLength: 5});
	assert.deepEqual(
		await readResponseBytesWithLimit(stream.response, {maxBytes: 5}),
		Uint8Array.from([1, 2, 3, 4, 5]),
	);
});

test("shared-note aggregate budget aborts on overflow", async () => {
	let overflows = 0;
	const budget = createByteBudget(5, {onExceeded: () => overflows++});
	const first = streamingResponse([[1, 2, 3]]);
	await readResponseBytesWithLimit(first.response, {maxBytes: 5, budget});
	const second = streamingResponse([[4, 5, 6]]);
	await assert.rejects(
		readResponseBytesWithLimit(second.response, {maxBytes: 5, budget}),
		/budget exceeded/,
	);
	assert.equal(second.cancelled, true);
	assert.equal(budget.usedBytes, 3);
	assert.equal(budget.exceeded, true);
	assert.equal(overflows, 1);
});

test("concurrency helper caps active work and preserves result order", async () => {
	let active = 0;
	let maximumActive = 0;
	const results = await mapWithConcurrency([0, 1, 2, 3, 4, 5, 6], 3, async (item) => {
		active++;
		maximumActive = Math.max(maximumActive, active);
		await new Promise((resolve) => setTimeout(resolve, (6 - item) % 3));
		active--;
		return `result-${item}`;
	});
	assert.equal(maximumActive, 3);
	assert.deepEqual(results, [
		"result-0",
		"result-1",
		"result-2",
		"result-3",
		"result-4",
		"result-5",
		"result-6",
	]);
});

test("only pending access requests need a live observer", async () => {
	for (const state of ["approved", "denied", "missing", "invalid"]) {
		let watches = 0;
		assert.equal(
			await loadShareRequestState({
				load: async () => ({status: state}),
				handle: async () => state,
				watch: () => watches++,
			}),
			state,
		);
		assert.equal(watches, 0);
	}

	let watches = 0;
	assert.equal(
		await loadShareRequestState({
			load: async () => ({status: "pending"}),
			handle: async () => "pending",
			watch: () => watches++,
		}),
		"pending",
	);
	assert.equal(watches, 1);
});

test("single-flight approved rendering runs only once per viewer session", async () => {
	let calls = 0;
	const renderOnce = createSingleFlight(async () => {
		calls++;
		await new Promise((resolve) => setTimeout(resolve, 1));
		return "rendered";
	});

	assert.deepEqual(
		await Promise.all([renderOnce(), renderOnce(), renderOnce()]),
		["rendered", "rendered", "rendered"],
	);
	assert.equal(await renderOnce(), "rendered");
	assert.equal(calls, 1);
});

test("Astro is the single source for the focused shared-note viewer", async () => {
	await assert.rejects(access(path.join(repositoryRoot, "web", "s", "index.html")));
	const [route, layout, component, runtime, gateway, styles, buildScript] =
		await Promise.all([
			readFile(path.join(siteSource, "pages", "s", "index", "index.astro"), "utf8"),
			readFile(path.join(siteSource, "layouts", "ShareLayout.astro"), "utf8"),
			readFile(path.join(siteSource, "components", "share", "ShareViewer.astro"), "utf8"),
			readFile(path.join(siteSource, "scripts", "share-viewer.ts"), "utf8"),
			readFile(path.join(siteSource, "scripts", "share-firebase.ts"), "utf8"),
			readFile(path.join(siteSource, "styles", "share-viewer.css"), "utf8"),
			readFile(path.join(repositoryRoot, "scripts", "build_web.sh"), "utf8"),
		]);

	assert.match(route, /ShareLayout/);
	assert.match(layout, /noindex, nofollow, noarchive/);
	assert.match(layout, /name="referrer" content="no-referrer"/);
	assert.doesNotMatch(layout, /canonical|plausible/i);
	assert.equal((component.match(/data-share-screen=/g) || []).length, 9);
	assert.match(component, /<dialog\b/);
	assert.match(component, /aria-live="polite"/);
	assert.match(component, /<label for="share-device-name">/);
	assert.doesNotMatch(component, /\sonclick=|\sstyle=/i);
	assert.match(runtime, /from 'dompurify'/);
	assert.match(runtime, /from 'marked'/);
	assert.match(runtime, /import\('\.\/share-firebase'\)/);
	assert.match(runtime, /URL\.revokeObjectURL/);
	assert.match(runtime, /createSingleFlight\(decryptAndShow\)/);
	assert.match(runtime, /loadShareRequestState\(/);
	assert.equal(
		(runtime.match(/createByteBudget\(\s*MAX_SHARED_NOTE_ATTACHMENT_BYTES/g) || [])
			.length,
		1,
	);
	const attachmentRuntime = runtime.slice(
		runtime.indexOf("const renderAttachments = async"),
		runtime.indexOf("const decryptAndShow = async"),
	);
	const slotReservation = attachmentRuntime.indexOf(
		"const slots = attachments.map(() => view.reserveAttachmentSlot())",
	);
	const concurrentWork = attachmentRuntime.indexOf("await mapWithConcurrency");
	assert.ok(slotReservation >= 0 && slotReservation < concurrentWork);
	assert.match(attachmentRuntime, /ATTACHMENT_DOWNLOAD_CONCURRENCY/);
	assert.match(attachmentRuntime, /readResponseBytesWithLimit\(response/);
	assert.match(attachmentRuntime, /signal: controller\.signal/);
	assert.doesNotMatch(attachmentRuntime, /response\.arrayBuffer/);
	assert.match(attachmentRuntime, /const slot = slots\[index\]/);
	assert.match(attachmentRuntime, /renderAudioAttachment\(slot,/);
	assert.match(attachmentRuntime, /renderImageAttachment\(slot,/);
	assert.match(attachmentRuntime, /renderAttachmentError\(slot\)/);
	assert.match(gateway, /getFirestore\(app, databaseId\)/);
	assert.match(gateway, /databaseId = local \? '\(default\)' : 'better-keep'/);
	assert.doesNotMatch(`${component}\n${runtime}\n${gateway}`, /gstatic\.com|jsdelivr\.net/);
	assert.match(styles, /@media \(prefers-reduced-motion: reduce\)/);
	assert.match(styles, /\.share-attachment--loading/);
	assert.doesNotMatch(buildScript, /web\/s|PROJECT_DIR\/web\/s/);

	const pageDirectory = path.join(siteSource, "pages", "s");
	const sourceFiles = await readdir(pageDirectory, {recursive: true});
	assert.deepEqual(sourceFiles.filter((name) => name.endsWith(".astro")), [
		path.join("index", "index.astro"),
	]);
});
