# 沈理校园 Web 与教务助手

React + TypeScript + Vite，复用 Go API；视觉基准为 `web/reference/prototype-v3.html`。当前产物用于开发联调，尚未满足完整方案的最终验收门槛。

## 运行

在仓库根目录执行：

```powershell
pnpm install
pnpm dev
```

访问 `http://127.0.0.1:5173/web/`。默认代理仓库中的 `https://sylulive.online`，会访问真实业务服务。需要本地 Go 服务时先设置 `$env:SYLULIVE_API_ORIGIN='http://127.0.0.1:8080'`，再启动。Go 启动沿用服务端原有环境配置，不把生产密钥复制到前端。

## 扩展安装与本机查询

```powershell
pnpm --filter @sylulive/extension dev
```

Chrome 打开 `chrome://extensions`，Edge 打开 `edge://extensions`，开启开发者模式，选择“加载已解压的扩展程序”，目录为 `browser-extension/dist-dev`。生产域名使用 `browser-extension/dist`；生产包不注入 localhost。

在网站登录后，进入课表或成绩的“连接教务助手”。助手按系统请求域名权限，打开学校官网；用户自行完成登录与验证码，回到网站核对并确认身份。体测在扩展页面输入凭据，使用学校现有 HTTP 服务。本科与研究生仅向 Go 提交现有接口要求的学校类型、学号和本机身份声明；学校密码、原始响应和会话凭据不交给网站。

个人资料默认保留在页面会话中。勾选“在此电脑保存”后，扩展 IndexedDB 才保存查询得到的结构化资料。课程提醒另行确认通知权限及本机保存，依赖浏览器运行；修改课表后需重新同步提醒。独立课程窗口不提供系统置顶。

## 构建、测试与打包

```powershell
pnpm check
pnpm test
pnpm build
pnpm --filter @sylulive/extension dev
pnpm exec playwright install chromium
pnpm test:e2e
pnpm package
cd server
go test ./internal/handlers ./internal/middleware ./internal/ai
```

`artifacts/web-build/` 包含静态网站、生产扩展、开发扩展及 Windows 下生成的 ZIP。包为联调候选包，不表示学校链路或商店审核通过。扩展发布前还需按实际商店补齐展示素材与隐私披露。

`pnpm package` 会额外写出 `artifacts/web-build/BUILD_INFO.json`：产出提交号、分支、工作树是否干净，以及三棵子树的确定性摘要和 ZIP 的 SHA-256。部署前用它核对「发布物就是待部署提交」：

```powershell
node scripts/package-web.mjs --check <待部署 SHA>   # 或设置 RELEASE_SHA
```

校验会同时比对提交号与磁盘内容摘要，任一不符即失败退出。工作区有未提交改动时打包默认拒绝，确需打实验包用 `ALLOW_DIRTY_RELEASE=1`，此时 `BUILD_INFO.json` 记录 `dirty: true`，不得作为发布物。

## 部署

将 `web/dist/` 内容放到现有站点 `/web/`。参考 `web/deploy/nginx.conf` 合并到原 HTTPS server；保留官网及分享路由，API 与附件使用同源代理，SSE 关闭缓冲。新增收藏和个人 AI 分析需要同时发布本仓库 Go 修改；仅更新静态页面不会让线上旧服务具备新接口。

## 验收边界

已运行的自动化包括共享数据校验、解析与提醒计算、SSE 分帧、课表编辑及冲突、主要路由和移动导航，以及真实 Chromium 扩展加载和握手。Go 测试覆盖收藏、Origin 校验与个人 AI 授权/用量等边界。

尚未完成真实账号的发布—审核—通知回读，以及本科、研究生、二课、体测四种学校来源的登录查询验收。Chrome/Edge 的重启、升级、多账号和系统通知还需实机验收。18 个页面的固定数据视觉对照也尚未全量完成，不能用路由冒烟代替。

校园地图已复用 App 资源；食堂贡献列表、实拍、审核原因及评价编辑保留关联资料已接入；管理端已增加用户、版块、公告、版本、日志和 AI 指标入口。这些接口接入仍需真实账号验收，不能视为发布—审核—回读全链路已通过。

学业页已展示分模块学分要求、课程明细和本地缺口检查，切换栏目保留本次查询结果并标注来源及时间；毕业检查仅覆盖已返回的学分模块，不替代学校最终结论。

完整方案中仍需补齐的业务包括校园电话/办事指南、食堂治理细项、部分竞赛推荐与偏好、更完整的成绩详情及毕业条件覆盖等。当前已有页面及 API 接入不等于这些子流程全部完成。

学校凭据请只输入官网或助手页面。真实学校来源不可达、身份不具备对应能力或服务器拒绝时保留错误与旧数据，不以模拟响应确认完成。
