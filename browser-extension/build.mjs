import { build } from "esbuild";
import { mkdir, writeFile, copyFile, readFile } from "node:fs/promises";
const {version} = JSON.parse(await readFile(new URL('./package.json', import.meta.url), 'utf8'));
const dev = process.argv.includes("--dev"),
  store = process.argv.includes('--store'),
  out = store ? 'dist-store' : dev ? "dist-dev" : "dist";
if (dev && store) throw new Error('Store builds cannot include localhost permissions');
const icons = Object.fromEntries([16, 32, 48, 128].map(size => [String(size), `icon-${size}.png`]));
await mkdir(out, { recursive: true });
await build({
  entryPoints: ["src/background.ts", "src/relay.ts", "src/assistant.ts", "src/schedule-page.ts"],
  outdir: out,
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "chrome120",
  minify: !dev,
  define: {__STORE_BUILD__: String(store)},
});
const sites = [
  "https://sylulive.online/*",
  ...(dev ? ["http://localhost:5173/*", "http://127.0.0.1:5173/*"] : []),
];
await writeFile(
  `${out}/manifest.json`,
  JSON.stringify(
    {
      manifest_version: 3,
      name: "沈理校园教务助手",
      version,
      description: "从本机查询校园资料，连接沈理校园 Web。",
      minimum_chrome_version: "120",
      icons,
      permissions: ["storage", "alarms", "scripting"],
      optional_permissions: ["notifications", ...(!store ? ["cookies"] : [])],
      host_permissions: sites,
      optional_host_permissions: [
        "https://jxw.sylu.edu.cn/*",
        "https://yjsgl.sylu.edu.cn/*",
        "https://webvpn.sylu.edu.cn/*",
        ...(!store ? ["http://47.92.231.221/*"] : []),
      ],
      background: { service_worker: "background.js" },
      action: {
        default_title: "沈理校园教务助手",
        default_popup: "assistant.html",
        default_icon: icons,
      },
      content_scripts: [
        {
          matches: sites,
          js: ["relay.js"],
          run_at: "document_start",
          all_frames: false,
        },
      ],
      content_security_policy: {
        extension_pages:
          "script-src 'self'; object-src 'none'; base-uri 'none'",
      },
    },
    null,
    2,
  ),
);
await copyFile("src/assistant.html", `${out}/assistant.html`);
const privacy = (await readFile('../server/static/legal/extension-privacy.html','utf8'))
  .replace('href="/"','href="https://sylulive.online/web/"')
  .replace('href="/privacy"','href="https://sylulive.online/privacy"');
await writeFile(`${out}/privacy.html`, privacy);
await copyFile("src/schedule.html", `${out}/schedule.html`);
await copyFile("src/assistant.css", `${out}/assistant.css`);
for (const size of [16, 32, 48, 128]) await copyFile(`assets/icon-${size}.png`, `${out}/icon-${size}.png`);
await copyFile('assets/icon-128.png', `${out}/icon.png`);
