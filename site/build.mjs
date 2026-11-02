import { mkdir, copyFile, rm } from 'node:fs/promises';
import { files } from './files.mjs';
import { sync } from './pages.mjs';
// Shared header/footer and the version details are written into the pages first, from
// pages.mjs and ../releases.json, so what ships always matches the version list.
await sync();
await rm('dist', { recursive: true, force: true });
await mkdir('dist/art', { recursive: true });
for (const file of files) await copyFile(file, `dist/${file}`);
console.log(`Production static build: dist/ (${files.length} files). No dependencies or network.`);
