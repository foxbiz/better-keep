// Embed public Flutter asset paths into the shipped worker. Only the selected
// release is warmed; provider files and account data never enter Cache Storage.
import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

export async function prepareOfflineAssets(directory) {
	const root = path.join(directory, "assets");
	const files = await readdir(root, { withFileTypes: true, recursive: true });
	const assets = files
		.filter((file) => file.isFile())
		.map(
			(file) =>
				"assets/" +
				path
					.relative(root, path.join(file.parentPath, file.name))
					.split(path.sep)
					.map(encodeURIComponent)
					.join("/"),
		)
		.sort();
	const worker = path.join(directory, "offline_worker.js");
	const source = await readFile(worker, "utf8");
	const marker = /^const bundledAssets = \[[^\r\n]*\];$/m;
	if (!marker.test(source))
		throw new Error("Offline asset list marker missing");
	await writeFile(
		worker,
		source.replace(
			marker,
			() => "const bundledAssets = " + JSON.stringify(assets) + ";",
		),
	);
}
if (
	process.argv[1] &&
	import.meta.url === pathToFileURL(process.argv[1]).href
) {
	await prepareOfflineAssets(process.argv[2]);
}
