import { chmod, chown, mkdir, readdir } from 'node:fs/promises';
import { prepareFixtures } from '../memory/fixture.ts';

if (process.getuid?.() !== 0 || process.argv.length !== 2) throw new Error('Disposable root prep container required.');
const directory = '/lab/sah-memory-fixtures';
await mkdir(directory, { mode: 0o700 });
console.log(JSON.stringify(await prepareFixtures(directory)));
for (const name of await readdir(directory)) {
  await chmod(`${directory}/${name}`, 0o600);
  await chown(`${directory}/${name}`, 1000, 1000);
}
await chown(directory, 1000, 1000);
