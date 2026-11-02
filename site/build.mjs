import { mkdir, copyFile, rm, writeFile } from 'node:fs/promises';
import { files } from './files.mjs';
import { render } from './pages.mjs';
import { load } from './releases.mjs';
// Pages ship as pages.mjs renders them from ../releases.json. The source files are never
// rewritten here (that is `node pages.mjs`), so a stale committed page fails the tests.
const rendered = await render(await load());
await rm('dist', { recursive: true, force: true });
await mkdir('dist/art', { recursive: true });
for (const file of files) {
  if (rendered[file] !== undefined) await writeFile(`dist/${file}`, rendered[file]);
  else await copyFile(file, `dist/${file}`);
}
console.log(`Production static build: dist/ (${files.length} files). No dependencies or network.`);
