import {readFileSync} from 'node:fs';
import {parseEnv} from 'node:util';

// Check the effective Flutter defines, including explicit CLI overrides.
const defines = {};
const overrides = {};
const args = process.argv.slice(2);
try {
  for (let i = 0; i < args.length; i++) {
    const [flag, ...rest] = args[i].split('=');
    if (!['--dart-define-from-file', '--dart-define'].includes(flag)) continue;
    const value = rest.length ? rest.join('=') : args[++i];
    if (flag === '--dart-define-from-file') {
      const text = readFileSync(value, 'utf8');
      Object.assign(defines, text.trimStart().startsWith('{') ? JSON.parse(text) : parseEnv(text));
    } else {
      const split = value.indexOf('=');
      if (split < 1) throw new Error('invalid define');
      overrides[value.slice(0, split)] = value.slice(split + 1);
    }
  }
  // Flutter applies explicit defines after all files, regardless of argument order.
  Object.assign(defines, overrides);
  if (!/^[0-9a-fA-F]{64}$/.test(defines.WEB_STORAGE_KEY ?? '')) {
    throw new Error('missing compatibility value');
  }
} catch {
  // Never print define values or file contents in build logs.
  console.error('Web release blocked: retain the original 64-character hexadecimal WEB_STORAGE_KEY in the build defines. Do not generate a replacement; it is required to read existing browser keys.');
  process.exitCode = 1;
}
