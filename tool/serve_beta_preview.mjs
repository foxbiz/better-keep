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
export function previewServer(directory) {
	const root = path.resolve(directory);
	return http.createServer(async (request, response) => {
		try {
			// Local acceptance tests must not read/write production accounts by accident.
			response.setHeader(
				"Content-Security-Policy",
				"connect-src 'self' https://www.gstatic.com https://fonts.gstatic.com",
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
			response.end(await readFile(file));
		} catch (_) {
			response.writeHead(404);
			response.end("Not found");
		}
	});
}
if (path.resolve(process.argv[1] || "") === fileURLToPath(import.meta.url)) {
	const server = previewServer(process.argv[2] || "build/beta-preview");
	server.listen(Number(process.argv[3] || 5099), "127.0.0.1", () => {
		console.log(
			`Local preview: http://127.0.0.1:${server.address().port}/app/`,
		);
	});
}
