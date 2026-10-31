import { readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';

const root = process.argv[2];
if (!root) throw new Error('Expected the generated hosting directory');
const index = join(root, 'app/index.html');
const html = await readFile(index, 'utf8');
const stripped = html.replace(/^[ \t]*<script src="js\/firebase_emulator_proxy\.js"><\/script>\r?\n/m, '');
// Idempotent for a clean build, fail closed if markup changed unexpectedly.
if (stripped.includes('firebase_emulator_proxy')) throw new Error('Emulator proxy script was not removed');
await writeFile(index, stripped);
await rm(join(root, 'app/js/firebase_emulator_proxy.js'), { force: true });
await rm(join(root, 'js/firebase_emulator_proxy.js'), { force: true });
