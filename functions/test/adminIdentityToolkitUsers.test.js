const assert = require("node:assert/strict");
const test = require("node:test");
const {
	identityToolkitClaimsAuth,
	identityToolkitUserExists,
	identityToolkitUserRecord,
	listIdentityToolkitUsers,
} = require("../lib/adminIdentityToolkitUsers");

const credential = {
	getAccessToken: async () => ({ access_token: "test-token", expires_in: 3600 }),
};

test("maps Identity Platform accounts to the bounded admin-index user contract", () => {
	const user = identityToolkitUserRecord({
		localId: "uid-1",
		email: "ADMIN@EXAMPLE.COM",
		displayName: "Admin",
		photoUrl: "https://example.com/avatar.png",
		providerUserInfo: [{ providerId: "password" }, { providerId: "google.com" }],
		disabled: false,
		emailVerified: true,
		customAttributes: JSON.stringify({ appAdmin: true }),
		createdAt: "1704067200000",
		lastLoginAt: "1704153600000",
	});
	assert.deepEqual(user, {
		uid: "uid-1",
		email: "ADMIN@EXAMPLE.COM",
		displayName: "Admin",
		photoURL: "https://example.com/avatar.png",
		providerData: [{ providerId: "password" }, { providerId: "google.com" }],
		disabled: false,
		emailVerified: true,
		customClaims: { appAdmin: true },
		metadata: {
			creationTime: "Mon, 01 Jan 2024 00:00:00 GMT",
			lastSignInTime: "Tue, 02 Jan 2024 00:00:00 GMT",
		},
	});
});

test("reads and writes custom claims with an explicit quota project", async () => {
	const requests = [];
	const claimsAuth = identityToolkitClaimsAuth({
		credential,
		projectId: "better-keep-notes",
		fetchImpl: async (url, init) => {
			const request = {
				body: JSON.parse(init.body),
				headers: new Headers(init.headers),
				url: String(url),
			};
			requests.push(request);
			if (request.url.endsWith("accounts:lookup")) {
				return new Response(
					JSON.stringify({
						users: [
							{
								localId: "uid-claims",
								customAttributes: JSON.stringify({ appAdmin: true }),
							},
						],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			return new Response(JSON.stringify({ localId: "uid-claims" }), {
				status: 200,
				headers: { "content-type": "application/json" },
			});
		},
	});
	const user = await claimsAuth.getUser("uid-claims");
	assert.deepEqual(user.customClaims, { appAdmin: true });
	await claimsAuth.setCustomUserClaims("uid-claims", {
		appAdmin: true,
		plan: "pro",
	});
	assert.equal(requests.length, 2);
	for (const request of requests) {
		assert.equal(request.headers.get("authorization"), "Bearer test-token");
		assert.equal(
			request.headers.get("x-goog-user-project"),
			"better-keep-notes",
		);
	}
	assert.deepEqual(requests[0].body, { localId: ["uid-claims"] });
	assert.deepEqual(requests[1].body, {
		customAttributes: JSON.stringify({ appAdmin: true, plan: "pro" }),
		localId: "uid-claims",
	});
});

test("claims API failures expose only the operation and HTTP status", async () => {
	const claimsAuth = identityToolkitClaimsAuth({
		credential,
		projectId: "better-keep-notes",
		fetchImpl: async () =>
			new Response("sensitive Identity Platform body", { status: 403 }),
	});
	await assert.rejects(
		claimsAuth.getUser("uid-claims"),
		/^Error: Identity Platform claims lookup failed with HTTP 403$/,
	);
});

test("claims lookup classifies deleted users as terminal", async () => {
	const claimsAuth = identityToolkitClaimsAuth({
		credential,
		projectId: "better-keep-notes",
		fetchImpl: async () =>
			new Response(JSON.stringify({ users: [] }), {
				status: 200,
				headers: { "content-type": "application/json" },
			}),
	});
	await assert.rejects(claimsAuth.getUser("deleted"), (error) => {
		assert.equal(error.code, "auth/user-not-found");
		return true;
	});
});

test("lists users with a bounded page and explicit quota project", async () => {
	let request;
	const result = await listIdentityToolkitUsers({
		credential: {
			getAccessToken: async () => ({ access_token: "test-token", expires_in: 3600 }),
		},
		projectId: "better-keep-notes",
		pageToken: "next page",
		fetchImpl: async (url, init) => {
			request = { url: String(url), headers: new Headers(init.headers) };
			return new Response(JSON.stringify({
				users: [{ localId: "uid-2" }],
				nextPageToken: "later",
			}), { status: 200, headers: { "content-type": "application/json" } });
		},
	});
	assert.equal(request.headers.get("authorization"), "Bearer test-token");
	assert.equal(request.headers.get("x-goog-user-project"), "better-keep-notes");
	assert.match(request.url, /maxResults=1000/);
	assert.match(request.url, /nextPageToken=next\+page/);
	assert.equal(result.users[0].uid, "uid-2");
	assert.equal(result.pageToken, "later");
});

test("fails without exposing Identity Platform response bodies", async () => {
	await assert.rejects(
		listIdentityToolkitUsers({
			credential: {
				getAccessToken: async () => ({ access_token: "test-token", expires_in: 3600 }),
			},
			projectId: "better-keep-notes",
			fetchImpl: async () => new Response("sensitive response", { status: 403 }),
		}),
		/Identity Platform user listing failed with HTTP 403/,
	);
});

test("looks up an exact UID with an explicit quota project", async () => {
	let request;
	const exists = await identityToolkitUserExists({
		credential,
		projectId: "better-keep-notes",
		uid: "uid-3",
		fetchImpl: async (url, init) => {
			request = {
				body: JSON.parse(init.body),
				headers: new Headers(init.headers),
				method: init.method,
				url: String(url),
			};
			return new Response(JSON.stringify({ users: [{ localId: "uid-3" }] }), {
				status: 200,
				headers: { "content-type": "application/json" },
			});
		},
	});
	assert.equal(exists, true);
	assert.equal(request.method, "POST");
	assert.deepEqual(request.body, { localId: ["uid-3"] });
	assert.equal(request.headers.get("authorization"), "Bearer test-token");
	assert.equal(request.headers.get("x-goog-user-project"), "better-keep-notes");
	assert.match(request.url, /accounts:lookup$/);
});

test("reports absent UIDs without exposing provider error bodies", async () => {
	assert.equal(
		await identityToolkitUserExists({
			credential,
			projectId: "better-keep-notes",
			uid: "missing",
			fetchImpl: async () =>
				new Response(JSON.stringify({ users: [] }), {
					status: 200,
					headers: { "content-type": "application/json" },
				}),
		}),
		false,
	);
	await assert.rejects(
		identityToolkitUserExists({
			credential,
			projectId: "better-keep-notes",
			uid: "uid-3",
			fetchImpl: async () => new Response("sensitive response", { status: 403 }),
		}),
		/Identity Platform user lookup failed with HTTP 403/,
	);
});
