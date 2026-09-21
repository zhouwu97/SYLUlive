import { build } from "esbuild";
import { mkdir, writeFile, copyFile } from "node:fs/promises";
const dev = process.argv.includes("--dev"),
  out = dev ? "dist-dev" : "dist";
await mkdir(out, { recursive: true });
await build({
  entryPoints: ["src/background.ts", "src/relay.ts", "src/assistant.ts", "src/schedule-page.ts"],
  outdir: out,
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "chrome120",
  minify: !dev,
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
      version: "0.1.0",
      description: "从本机查询校园资料，连接沈理校园 Web。",
      minimum_chrome_version: "120",
      permissions: ["storage", "alarms", "scripting"],
      optional_permissions: ["notifications", "cookies"],
      host_permissions: sites,
      optional_host_permissions: [
        "https://jxw.sylu.edu.cn/*",
        "https://yjsgl.sylu.edu.cn/*",
        "https://webvpn.sylu.edu.cn/*",
        "http://47.92.231.221/*",
      ],
      background: { service_worker: "background.js" },
      action: {
        default_title: "沈理校园教务助手",
        default_popup: "assistant.html",
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
await copyFile("src/schedule.html", `${out}/schedule.html`);
await copyFile("src/assistant.css", `${out}/assistant.css`);
// 通知图标使用固定 PNG；不依赖外部网络资源。
await writeFile(
  `${out}/icon.png`,
  Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "base64",
  ),
);
