import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {cp, mkdir, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

// 页面在检测不到助手时直接给下载包，因此包必须与站点同源发布：
// 生产通道只授权线上域名，开发通道额外授权 5173，装错通道的包永远握手不上。
// 目录整体重建（而不是覆盖单个文件）才能保证一次构建只剩一个通道。
const args = process.argv;
const channel = args[args.indexOf('--channel') + 1];
if (channel !== 'production' && channel !== 'development') {
  console.error('用法：node package-web.mjs --channel production|development');
  process.exit(1);
}
const dev = channel === 'development';
const source = resolve(dev ? 'dist-dev' : 'dist');
const outDir = resolve('../web/public/assistant');
const folder = 'sylulive-assistant';
const zipName = `${folder}.zip`;

function run(command, commandArgs, cwd) {
  const result = spawnSync(command, commandArgs, {cwd, stdio: 'inherit'});
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(`${command} ${commandArgs.join(' ')} 失败（退出码 ${result.status}）`);
}

function installNotes(manifest) {
  return [
    '沈理校园教务助手 · 安装说明',
    '',
    `版本：${manifest.version}`,
    `授权站点：${(manifest.host_permissions ?? []).join('、')}`,
    '',
    '1. 把 sylulive-assistant 目录解压到一个固定位置，解压后不要移动、重命名或删除它。',
    '   解包安装的扩展身份由目录路径决定，换目录等于换了一个新扩展，本机已保存的教务资料不会跟过去。',
    '2. 在浏览器地址栏输入 edge://extensions 并回车（Chrome 为 chrome://extensions）。',
    '3. 打开「开发者模式」开关。',
    '4. 点「加载已解压的扩展程序」，选择第 1 步得到的 sylulive-assistant 目录。',
    '5. 回到沈理校园页面，页面会自动检测到助手并提示可以继续，不必刷新。读取资料仍由你点「连接并读取资料」触发。',
    '',
    '需要知道的事：',
    '- 浏览器不允许网页自行安装扩展，所以下载包只提供文件，安装动作必须在扩展管理页完成。',
    '- 开发者模式下浏览器会周期性提示甚至暂时停用非商店扩展，出现提示时选择保留即可；长期方案是发布到 Edge Add-ons / Chrome Web Store。',
    '- 学校密码只在助手页面输入，不会交给沈理校园网站。',
    '- 安装前请核对页面显示的 SHA-256 与下载文件一致。',
  ].join('\r\n');
}

run(process.execPath, ['build.mjs', ...(dev ? ['--dev'] : [])]);

const manifest = JSON.parse(await readFile(resolve(source, 'manifest.json'), 'utf8'));
if (!manifest.version || !Array.isArray(manifest.content_scripts))
  throw new Error(`${source}/manifest.json 不完整，拒绝产出下载包`);

const stage = await mkdtemp(join(tmpdir(), 'sylulive-assistant-'));
try {
  const root = join(stage, folder);
  await cp(source, root, {recursive: true});
  await writeFile(join(root, 'INSTALL.txt'), installNotes(manifest), 'utf8');
  await rm(outDir, {recursive: true, force: true});
  await mkdir(outDir, {recursive: true});
  const zip = resolve(outDir, zipName);
  if (process.platform === 'win32') {
    // 不用 Compress-Archive 也不用 .NET ZipFile：Windows PowerShell 5.1 两者都会写反斜杠条目名，
    // 不符合 ZIP 规范，非 Windows 解压工具会把「sylulive-assistant\manifest.json」整个当成文件名。
    // 用系统自带 bsdtar 按 .zip 扩展名产出，条目名统一为正斜杠并保留单一顶层目录。
    // 必须走绝对路径：从 Git Bash 里跑时 PATH 上的 GNU tar 不支持 zip。
    const bsdtar = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'tar.exe');
    run(bsdtar, ['-a', '-c', '-f', zip, '-C', stage, folder]);
  } else {
    run('zip', ['-r', '-X', zip, folder], stage);
  }
  const bytes = await readFile(zip);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  await writeFile(
    resolve(outDir, 'assistant.json'),
    JSON.stringify(
      {
        channel,
        extensionVersion: manifest.version,
        fileName: zipName,
        bytes: bytes.length,
        sha256,
        builtAt: new Date().toISOString(),
        sites: manifest.host_permissions ?? [],
      },
      null,
      2,
    ) + '\n',
  );
  console.log(
    `${outDir} 已产出 ${channel} 通道 ${zipName}（${bytes.length} 字节，sha256 ${sha256}）`,
  );
} finally {
  await rm(stage, {recursive: true, force: true});
}
