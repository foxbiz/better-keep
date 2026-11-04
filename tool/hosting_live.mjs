// Only public Hosting resources are accessed. Authentication stays in the pinned CLI.
import { createRequire } from "node:module";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { hostingHash, hostedPath } from "./hosting_files.mjs";
const require = createRequire(import.meta.url);
export const hostingSite = "better-keep-notes";

export async function connectHosting() {
	const { requireAuth } = require("firebase-tools/lib/requireAuth");
	const auth = require("firebase-tools/lib/auth");
	const { Client } = require("firebase-tools/lib/apiv2");
	const api = require("firebase-tools/lib/hosting/api");
	const { Uploader } = require("firebase-tools/lib/deploy/hosting/uploader");
	await requireAuth({
		project: hostingSite,
		...auth.getGlobalDefaultAccount(),
	});
	const client = new Client({
		urlPrefix: "https://firebasehosting.googleapis.com",
		apiVersion: "v1beta1",
		auth: true,
	});
	return {
		async live() {
			const channel = await api.getChannel(hostingSite, hostingSite, "live");
			const { body } = await client.get(`/${channel.release.version.name}`);
			return body;
		},
		async files(version) {
			const files = [];
			let pageToken;
			do {
				const { body } = await client.get(`/${version}/files`, {
					queryParams: { pageSize: 1000, ...(pageToken ? { pageToken } : {}) },
				});
				files.push(...(body.files || []));
				pageToken = body.nextPageToken;
			} while (pageToken);
			return files;
		},
		create: () => api.createVersion(hostingSite, { status: "CREATED" }),
		version: async (name) => (await client.get(`/${name}`)).body,
		upload: async (version, directory, files) =>
			new Uploader({
				version,
				public: directory,
				files: files.map((f) => f.slice(1)),
				cwd: process.cwd(),
				projectRoot: process.cwd(),
				uploadConcurrency: 6,
			}).start(),
		finalize: (version, config) =>
			api.updateVersion(hostingSite, version.split("/").at(-1), {
				status: "FINALIZED",
				config,
			}),
		release: (version, message) =>
			api.createRelease(hostingSite, "live", version, { message }),
	};
}

export async function snapshotHosting(
	root,
	{ api, appOnly = false, fetchFile = fetch } = {},
) {
	api ??= await connectHosting();
	const live = await api.live();
	const files = (await api.files(live.name)).filter(
		(f) => !appOnly || f.path.startsWith("/app/"),
	);
	if (!files.some((f) => f.path === "/app/index.html"))
		throw new Error("Live app index missing");
	if (files.some((file) => file.path === "/snapshot.json"))
		throw new Error("Live site uses the reserved snapshot manifest path");
	await mkdir(path.dirname(root), { recursive: true });
	await mkdir(root); // Refuse an existing or incomplete snapshot.
	let next = 0;
	await Promise.all(
		Array.from({ length: 6 }, async () => {
			while (next < files.length) {
				const file = files[next++];
				const target = hostedPath(root, file.path);
				const url = new URL(`https://${hostingSite}.web.app/`);
				url.pathname = file.path;
				const response = await fetchFile(url, { cache: "no-store" });
				if (!response.ok)
					throw new Error(`Unable to read ${file.path}: ${response.status}`);
				const data = Buffer.from(await response.arrayBuffer());
				if (hostingHash(data) !== file.hash)
					throw new Error(
						`Live content differs from recorded version: ${file.path}`,
					);
				await mkdir(path.dirname(target), { recursive: true });
				await writeFile(target, data);
			}
		}),
	);
	if ((await api.live()).name !== live.name)
		throw new Error("Live release changed during snapshot; retry");
	await writeFile(
		path.join(root, "snapshot.json"),
		JSON.stringify(
			{
				version: live.name,
				files,
				config: live.config,
				completeSite: !appOnly,
			},
			null,
			2,
		),
	);
	console.log(`Verified ${files.length} Hosting files from ${live.name}`);
}
