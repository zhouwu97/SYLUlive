# 沈理校园官网

静态 HTML、CSS 和原生 JavaScript，无需前端构建即可预览。官网与 `web/` 业务页面分别维护。

## 本地预览

在仓库根目录运行：

```powershell
python -m http.server 8000 --bind 127.0.0.1 --directory sylulive_site_v5
```

- `http://127.0.0.1:8000/preview.html`：切换两套方向和宽屏／手机预览。
- `http://127.0.0.1:8000/index.html`：完整官网，采用清爽产品布局、青绿配色与少量校园手写标注。
- `http://127.0.0.1:8000/index.html?look=journal`：保留手账风格对照。
- `http://127.0.0.1:8000/download.html`：下载页，本地显示预览状态。

主页和下载页的基础样式维护在 `assets/site.css`，下载布局在 `assets/download.css`，风格对照在 `assets/site-directions.css`。预览器只切换本地 iframe，不请求业务数据。官网中的 Web 入口沿用 `/web/`，本地联调需要相应代理或独立启动 Web 服务。

首页各内容区由 `assets/section-viewport.css` 尽量适配一屏并轻量吸附，为固定导航留出空间；`assets/section-snap.js` 让对齐且能完整显示的区块用滚轮切换，避免小幅滚动被吸回。内容过长时允许页面自然增长和滚动；较矮窗口及减少动态效果时关闭吸附，避免裁切正文与交互控件。

## 产品展示交互

产品区由 `assets/product-page.css` 布置为一整屏，标题、图片和分页共用视口高度，进入时按整页轻量吸附。手机同样在一屏内呈现；低于 620px 的矮窗口改用自然高度，保留完整正文。

`assets/product-tour.js` 在鼠标位于产品区、整页已对齐或接近对齐且纵向滚动停稳后，将上下滚轮转换为横向分页；接近对齐时会先校正位置。半屏状态和较矮窗口保留网页滚动；一个连续手势只切换一页，首张向上、末张向下跨出一屏。选择分页或使用方向键时也会对齐完整产品页。保留左右拖动、原生触屏横向滑动、分页按钮、方向键和 Home／End，不拦截缩放和原生横向触控板输入。减少动效偏好下使用即时切换。

校园生活支持鼠标和方向键切换；手机导航支持 Escape、选择链接和焦点离开关闭。内容默认可见，不依赖滚动显现脚本。AI 对话为明确标注的静态示例。

## 下载状态与验证

`assets/release.js` 沿用 `/api/app/update` 的 Android stable 契约，保留 APK 和应用市场两种交付方式，包含加载、空版本、失败、12 秒超时和手动重试。旧响应不能覆盖新请求；下载地址只接受不含用户凭据的 HTTPS URL。localhost、127.0.0.1、IPv6 回环和本地文件预览不请求线上版本，也不提供伪造的下载地址。

```powershell
node --test sylulive_site_v5/tests/*.test.cjs
```

## 素材

真实界面截图和吉祥物沿用项目原有素材，路线与小图标使用页面内 SVG，不冒充实际校园摄影。缺失的内容图片保留文字说明和刷新提示。

手写小字使用 `assets/fonts/sylu-notes.woff`，是霞鹜文楷的有限字符子集，修改后的家族名称为 SYLU Notes；来源、修改说明和 SIL OFL 1.1 许可均在同目录。字体本地加载，无运行时字体 CDN。普通正文保持系统字体，不依赖该子集。
