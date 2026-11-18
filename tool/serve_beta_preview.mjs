#!/usr/bin/env node
import http from "node:http";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const types = {
	".html": "text/html",
	".js": "application/javascript",
	".mjs": "application/javascript",
	".json": "application/json",
	".wasm": "application/wasm",
	".css": "text/css",
	".svg": "image/svg+xml",
	".png": "image/png",
	".ico": "image/x-icon",
	".woff2": "font/woff2",
	".ttf": "font/ttf",
};
export function previewServer(directory, { emulators = false, workingLauncher = false } = {}) {
	const root = path.resolve(directory);
	return http.createServer(async (request, response) => {
		try {
			// Local acceptance tests must not read/write production accounts by accident.
			response.setHeader(
				"Content-Security-Policy",
				"connect-src 'self' https://www.gstatic.com https://fonts.gstatic.com" +
					(emulators ? " http://127.0.0.1:19099 http://127.0.0.1:18080" : ""),
			);
			const url = new URL(request.url, "http://localhost");
			let pathname = decodeURIComponent(url.pathname);
			if (pathname === "/app") pathname = "/app/";
			if (pathname === "/oauth/storage/callback") {
				response.setHeader("Content-Type", "text/html");
				response.setHeader("Cache-Control", "no-store");
				response.end(
					await readFile(new URL("../web/storage-auth.html", import.meta.url)),
				);
				return;
			}
			if (pathname.endsWith("/offline_worker.js"))
				response.setHeader("Service-Worker-Allowed", "/app");
			if (pathname.endsWith("/")) pathname += "index.html";
			const file = path.resolve(root, `.${pathname}`);
			if (
				!file.startsWith(`${root}${path.sep}`) ||
				!(await stat(file)).isFile()
			)
				throw new Error("Not found");
			response.setHeader(
				"Content-Type",
				types[path.extname(file)] || "application/octet-stream",
			);
			response.setHeader("Cache-Control", "no-store");
			const source = workingLauncher && pathname === "/app/beta-launcher.js"
				? new URL("../web/js/beta_launcher.js", import.meta.url)
				: file;
			response.end(await readFile(source));
		} catch (_) {
			response.writeHead(404);
			response.end("Not found");
		}
	});
}
if (path.resolve(process.argv[1] || "") === fileURLToPath(import.meta.url)) {
	const args = process.argv.slice(2);
	const [directory = "build/beta-preview", port = "5099"] =
		args.filter((arg) => arg !== "--working-launcher");
	const server = previewServer(directory, {
		workingLauncher: args.includes("--working-launcher"),
	});
	server.listen(Number(port), "127.0.0.1", () => {
		console.log(
			`Local preview: http://127.0.0.1:${server.address().port}/app/?channel=beta`,
		);
	});
}
