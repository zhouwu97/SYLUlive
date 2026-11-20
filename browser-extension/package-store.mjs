import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {storeArchive} from './store-archive.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const build = spawnSync(process.execPath, [join(here, 'build.mjs'), '--store'], {cwd: here, stdio: 'inherit'});
if (build.status !== 0) throw new Error('Store build failed');
const source = join(here, 'dist-store'), output = join(here, 'release-store');
const names = ['manifest.json', 'background.js', 'relay.js', 'assistant.js', 'schedule-page.js', 'assistant.html', 'privacy.html', 'schedule.html', 'assistant.css', 'icon.png', ...[16,32,48,128].map(size=>`icon-${size}.png`)];
if ((await readdir(source)).some(name => !names.includes(name))) throw new Error('Unexpected files in store build');
const manifest = JSON.parse(await readFile(join(source, 'manifest.json'), 'utf8'));
if (manifest.manifest_version !== 3 || manifest.optional_permissions.includes('cookies') || [...manifest.host_permissions, ...manifest.optional_host_permissions].some(value=>!value.startsWith('https://')))
  throw new Error('Store package must use HTTPS-only permissions');
for (const size of [16,32,48,128]) {
  const png = await readFile(join(source, manifest.icons[size]));
  if (png.toString('hex', 0, 8) !== '89504e470d0a1a0a' || png.readUInt32BE(16) !== size || png.readUInt32BE(20) !== size)
    throw new Error(`Invalid ${size}px icon`);
}
const entries = Object.fromEntries(await Promise.all(names.map(async name=>[name, await readFile(join(source, name))])));
if (['background.js', 'assistant.js'].some(name=>entries[name].includes(Buffer.from('http://47.92.231.221')))) throw new Error('Legacy HTTP provider leaked into store build');
const zip = storeArchive(entries), filename = `sylulive-assistant-${manifest.version}-store.zip`;
await mkdir(output, {recursive: true});
await writeFile(join(output, filename), zip);
const result = {version: manifest.version, filename, bytes: zip.length, sha256: createHash('sha256').update(zip).digest('hex'), entries: names.sort(), channels: ['Chrome Web Store', 'Microsoft Edge Add-ons'], published: false};
await writeFile(join(output, 'manifest.json'), JSON.stringify(result, null, 2)+'\n');
console.log(JSON.stringify(result));
