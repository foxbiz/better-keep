import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { readFile, readdir, mkdir, copyFile } from "node:fs/promises";
import path from "node:path";

export const hostingHash = (data) =>
	createHash("sha256")
		.update(gzipSync(data, { level: 9 }))
		.digest("hex");
export const readJson = async (file) =>
	JSON.parse(await readFile(file, "utf8"));
export function hostedPath(root, name) {
	if (
		!name.startsWith("/") ||
		name.includes("\\") ||
		name.split("/").some((p) => p === ".." || p === ".")
	)
		throw new Error(`Unsafe Hosting path: ${name}`);
	const file = path.resolve(root, `.${name}`);
	if (!file.startsWith(`${path.resolve(root)}${path.sep}`))
		throw new Error("Unsafe Hosting path");
	return file;
}
export async function copyHostedFile(from, to, name) {
	const destination = hostedPath(to, name);
	await mkdir(path.dirname(destination), { recursive: true });
	await copyFile(hostedPath(from, name), destination);
}
export async function listHostedFiles(root, prefix = "") {
	const files = [];
	for (const entry of await readdir(path.join(root, prefix), {
		withFileTypes: true,
	})) {
		const name = `${prefix}/${entry.name}`;
		if (entry.isSymbolicLink())
			throw new Error(`Hosting symlinks are not allowed: ${name}`);
		if (entry.isDirectory()) files.push(...(await listHostedFiles(root, name)));
		else if (entry.isFile()) files.push(name);
	}
	return files.sort();
}
export async function hashHostedFiles(root) {
	const result = {};
	for (const file of await listHostedFiles(root))
		result[file] = hostingHash(await readFile(hostedPath(root, file)));
	return result;
}
export async function verifySnapshot(root) {
	const snapshot = await readJson(path.join(root, "snapshot.json"));
	for (const file of snapshot.files) {
		if (hostingHash(await readFile(hostedPath(root, file.path))) !== file.hash)
			throw new Error(`Snapshot was modified: ${file.path}`);
	}
	return snapshot;
}
