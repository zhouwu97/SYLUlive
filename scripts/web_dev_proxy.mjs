#!/usr/bin/env node
/**
 * Flutter Web 本地开发代理（同源反代）
 *
 * 用途
 * ----
 * `flutter run -d web-server` 自带的 dev server 只会返回前端静态资源，
 * 不会代理 /api，导致所有接口拿到 HTML（Dio 不解析 -> response.data 是 String）
 * 并抛出 `type 'String' is not a subtype of type 'int'`。
 *
 * 生产环境由 nginx 完成 `/api` -> Go 的同源反代，本脚本在本地复刻同样的结构：
 *
 *   /api/*       -> 远端后端（默认 https://sylulive.online）
 *   /uploads/*   -> 远端后端
 *   /stickers/*  -> 远端后端
 *   其它          -> 本机 Flutter dev server
 *
 * 因为浏览器始终只访问 http://127.0.0.1:<PROXY_PORT>，属于同源请求，
 * 所以不需要后端支持 CORS，也不用改动生产配置。
 *
 * 用法
 * ----
 *   终端 1：flutter run -d web-server --web-port=8082
 *   终端 2：node scripts/web_dev_proxy.mjs
 *   浏览器：http://127.0.0.1:3000
 *
 * 环境变量
 * --------
 *   PROXY_PORT    代理监听端口（默认 3000）
 *   FLUTTER_PORT  Flutter dev server 端口（默认 8082）
 *   API_TARGET    远端后端地址（默认 https://sylulive.online）
 *
 * 安全提示
 * --------
 * 默认指向生产后端，开发期的发帖/点赞等写操作会写入生产数据库。
 * 如需隔离，请把 API_TARGET 指向测试环境。
 */

import http from 'node:http';
import net from 'node:net';

const PROXY_PORT = Number(process.env.PROXY_PORT ?? 3000);
const FLUTTER_PORT = Number(process.env.FLUTTER_PORT ?? 8082);
const API_TARGET = (process.env.API_TARGET ?? 'https://sylulive.online').replace(/\/+$/, '');
const FLUTTER_HOST = '127.0.0.1';
const UPSTREAM_TIMEOUT_MS = Number(process.env.UPSTREAM_TIMEOUT_MS ?? 60_000);

/** 逐跳首部，不能透传给上游或下游。 */
const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'proxy-connection',
]);

/**
 * fetch 会自动解压 gzip/br，这两个首部必须剔除，
 * 否则浏览器会对已解压的响应体再解一次，得到乱码。
 */
const STRIPPED_RESPONSE_HEADERS = new Set(['content-encoding', 'content-length']);

/** 与生产 nginx 保持一致：这些前缀由后端提供。 */
const BACKEND_PREFIXES = ['/api/', '/uploads/', '/stickers/'];

const COLORS = {
  reset: '[0m',
  dim: '[2m',
  cyan: '[36m',
  green: '[32m',
  yellow: '[33m',
  red: '[31m',
  magenta: '[35m',
};

function paint(text, color) {
  if (!process.stdout.isTTY) return text;
  return `${COLORS[color]}${text}${COLORS.reset}`;
}

function statusColor(status) {
  if (status >= 500) return 'red';
  if (status >= 400) return 'yellow';
  if (status >= 300) return 'magenta';
  return 'green';
}

function timestamp() {
  return new Date().toTimeString().slice(0, 8);
}

/** 判断请求是否应转给后端。 */
function isBackendRequest(pathname) {
  return BACKEND_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

function resolveTarget(pathname) {
  return isBackendRequest(pathname) ? API_TARGET : `http://${FLUTTER_HOST}:${FLUTTER_PORT}`;
}

/** 收集原始请求体（GET/HEAD 没有 body）。 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    if (req.method === 'GET' || req.method === 'HEAD') {
      resolve(undefined);
      return;
    }
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      resolve(chunks.length > 0 ? Buffer.concat(chunks) : undefined);
    });
    req.on('error', reject);
  });
}

/** 构造转发用的请求头：剔除逐跳首部与宿主相关字段，避免上游按错误 Host 路由。 */
function buildForwardHeaders(req) {
  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const lower = key.toLowerCase();
    if (HOP_BY_HOP.has(lower)) continue;
    if (lower === 'host' || lower === 'content-length') continue;
    if (value === undefined) continue;
    headers[key] = value;
  }
  return headers;
}

/**
 * 生产后端是 HTTPS，下发的 Cookie 带 Secure 属性；
 * 本地代理是 HTTP，浏览器会直接丢弃这些 Cookie，导致登录态无法保持。
 * 仅在此处剥离 Secure，属于开发期适配。
 */
function normalizeSetCookies(headers) {
  const raw = typeof headers.getSetCookie === 'function' ? headers.getSetCookie() : [];
  if (raw.length === 0) return undefined;
  return raw.map((cookie) => cookie.replace(/;\s*Secure\b/gi, ''));
}

/** 把指向远端的 Location 改写回代理自身，避免浏览器跳到跨域地址。 */
function rewriteLocation(location) {
  if (!location) return location;
  if (location.startsWith(API_TARGET)) {
    return location.slice(API_TARGET.length) || '/';
  }
  return location;
}

function sendError(res, status, message) {
  if (res.headersSent) {
    res.end();
    return;
  }
  const payload = `${message}\n`;
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(payload);
}

const server = http.createServer(async (req, res) => {
  const requestPath = req.url ?? '/';
  const target = resolveTarget(requestPath);
  const toBackend = isBackendRequest(requestPath);
  const targetUrl = new URL(requestPath, target);

  const startedAt = Date.now();
  let body;
  try {
    body = await readBody(req);
  } catch (error) {
    console.log(paint(`[${timestamp()}] 读取请求体失败 ${requestPath}: ${error.message}`, 'red'));
    sendError(res, 400, '读取请求体失败');
    return;
  }

  try {
    const upstream = await fetch(targetUrl, {
      method: req.method,
      headers: buildForwardHeaders(req),
      body: body,
      redirect: 'follow',
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });

    const outHeaders = {};
    upstream.headers.forEach((value, key) => {
      const lower = key.toLowerCase();
      if (HOP_BY_HOP.has(lower)) return;
      if (STRIPPED_RESPONSE_HEADERS.has(lower)) return;
      if (lower === 'set-cookie') return; // 单独处理
      if (lower === 'location') {
        outHeaders[key] = rewriteLocation(value);
        return;
      }
      outHeaders[key] = value;
    });

    const cookies = normalizeSetCookies(upstream.headers);
    if (cookies) outHeaders['set-cookie'] = cookies;

    // 开发代理不做任何缓存，避免看到过期页面。
    outHeaders['cache-control'] = 'no-store';

    const payload = Buffer.from(await upstream.arrayBuffer());
    res.writeHead(upstream.status, outHeaders);
    res.end(payload);

    const elapsed = Date.now() - startedAt;
    const route = toBackend ? paint('→远端', 'cyan') : paint('→本地', 'dim');
    const status = paint(String(upstream.status), statusColor(upstream.status));
    console.log(
      `[${timestamp()}] ${route} ${status} ${req.method} ${requestPath} ` +
        paint(`${elapsed}ms`, 'dim')
    );
  } catch (error) {
    const reason = error?.name === 'TimeoutError' ? '上游超时' : error?.message ?? String(error);
    if (toBackend) {
      console.log(paint(`[${timestamp()}] 远端请求失败 ${requestPath}: ${reason}`, 'red'));
      sendError(res, 502, `无法连接后端 ${API_TARGET}\n${reason}`);
    } else {
      console.log(paint(`[${timestamp()}] dev server 连接失败 ${requestPath}: ${reason}`, 'red'));
      sendError(
        res,
        502,
        `无法连接 Flutter dev server（${FLUTTER_HOST}:${FLUTTER_PORT}）\n` +
          `请先在另一个终端执行：\n  flutter run -d web-server --web-port=${FLUTTER_PORT}\n\n${reason}`
      );
    }
  }
});

/**
 * 热重载依赖 WebSocket，dev server 的 WS 端点必须原样透传，
 * 否则页面能打开但 hot restart 会失效。
 */
server.on('upgrade', (req, socket, head) => {
  const upstream = net.connect(FLUTTER_PORT, FLUTTER_HOST, () => {
    const headerLines = Object.entries(req.headers)
      .filter(([key]) => !HOP_BY_HOP.has(key.toLowerCase()))
      .map(([key, value]) => `${key}: ${Array.isArray(value) ? value.join(', ') : value}`);
    upstream.write(
      `${req.method} ${req.url} HTTP/1.1\r\n${headerLines.join('\r\n')}\r\n\r\n`
    );
    if (head && head.length > 0) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });

  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  const line = '─'.repeat(58);
  console.log(paint(line, 'dim'));
  console.log(paint('  Flutter Web 开发代理已启动', 'green'));
  console.log(paint(line, 'dim'));
  console.log(`  本地入口      ${paint(`http://127.0.0.1:${PROXY_PORT}`, 'cyan')}`);
  console.log(`  dev server    ${paint(`http://${FLUTTER_HOST}:${FLUTTER_PORT}`, 'dim')}  （/api 以外的请求）`);
  console.log(`  远端后端      ${paint(API_TARGET, 'yellow')}  （/api、/uploads、/stickers）`);
  console.log(paint(line, 'dim'));
  console.log(paint('  ⚠ 当前指向生产后端，写操作会写入生产数据库', 'yellow'));
  console.log(paint(line, 'dim'));
});

server.on('error', (error) => {
  if (error.code === 'EADDRINUSE') {
    console.error(paint(`端口 ${PROXY_PORT} 已被占用，请设置 PROXY_PORT 换一个端口。`, 'red'));
    process.exit(1);
  }
  console.error(paint(`代理启动失败: ${error.message}`, 'red'));
  process.exit(1);
});
