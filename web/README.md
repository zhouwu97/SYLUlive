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

维护者也可照常手工装载上面的目录；普通用户不必再自己找目录。页面检测不到教务助手时，连接弹窗与工具箱“教务连接诊断”会给出本站同源的安装包下载入口、SHA-256 校验值和自助安装步骤；用户在扩展管理页装载后，扩展会主动向已打开的站点标签页补注入握手脚本，页面自动复检并提示可以继续，不需要刷新。复检只确认通道建立，读取学校资料仍由用户点“连接并读取资料”触发。

该引导依赖 `web/public/assistant/`：本地 5173 用 `pnpm assistant:dev` 产出开发通道包，`pnpm build` 自动产出生产通道包。两个通道的授权域名不同，页面会拒绝在错误环境安装错误通道的包。已知限制：在扩展管理页把扩展由“停用”改为“启用”不会触发补注入，此时仍需刷新页面一次。

在网站登录后，进入课表或成绩的“连接教务助手”。助手按系统请求域名权限，打开学校官网；用户自行完成登录与验证码，回到网站核对并确认身份。体测在扩展页面输入凭据，使用学校现有 HTTP 服务。本科与研究生仅向 Go 提交现有接口要求的学校类型、学号和本机身份声明；学校密码、原始响应和会话凭据不交给网站。

个人资料默认保留在页面会话中。勾选“在此电脑保存”后，扩展 IndexedDB 才保存查询得到的结构化资料。课程提醒另行确认通知权限及本机保存，依赖浏览器运行；修改课表后需重新同步提醒。独立课程窗口不提供系统置顶。

## 认证链路的错误码与授权状态

扩展的回包 `error.code` 是可判定的分类，页面按分类给下一步动作，不再只丢一句文本：

| code | 含义 | 页面动作 |
| --- | --- | --- |
| `extension_unavailable` | 握手超时，本机没有助手 | 展示下载与自助安装步骤，自动复检 |
| `authorization_required` | 助手未获准访问该学校域名 | 提示打开助手页授权；次按钮变成“打开助手完成授权”，授权完成后免刷新自动恢复 |
| `school_login_required` | 学校登录过期或会话被踢 | 提示打开学校登录页后重试 |
| `site_login_required` | 站点账号已失效 | 退回未连接，要求重新登录沈理校园 |
| `connection_stale` / `identity_changed` | 连接代次被接管或本机教务身份换了人 | 清空连接、退回第 2 步并提示重新连接 |
| `unsupported_query` / `invalid_argument` / `failed` | 该系统不提供该资料、参数无效、其他异常 | 原样展示消息 |

兼容性：`BridgeResponse.error.code` 仍是 `string`，`hello` 的 `connections`、`authorized` 都是可选字段。旧扩展回的 `academic_failed` 一类未知码按 `failed` 处理，读不到 `authorized` 时不显示授权提示也不为此轮询，因此新页面配旧扩展、旧页面配新扩展都可用；协议只加字段，没有新增命令。

请求计数：一次“连接并读取资料”= `hello`（本地）→ `session`（站点 `account` + 学校身份页）→ 站点 `bind` → `query`（前置 `account`、前置身份核对、抓资料、后置身份核对、后置 `account`），共 8 次网络，其中 3 次抓的是同一个本科身份页。`hello` 会报告扩展已保有的连接代次和本机授权位（只读 `chrome.storage.session` 与 `chrome.permissions.contains`，不发任何网络请求），所以重开弹窗再点“查询并更新资料”只需 5 次。`query` 内部的前后置核对一次都没有减少，账号被切换仍能在写入前检出。

课表拉取：默认学年学期由 `defaultAcademicTerm()` 按月份推导（正方以秋季起算学年，春季学期归属上一学年，直接取日历年份会在 2–8 月拉到上一学期）；JSON 接口返回登录页时按“重新登录”提示，返回坏数据时提示原资料已保留。学校对某学期返回空列表且本机已有非空课表或成绩时，页面拒绝替换，弹窗保持打开并说明原因，扩展侧仍照常记录快照。

明确未做的优化：身份结果的同代次 TTL 复用、成绩分页并发抓取、用课表响应自带的学号代替独立身份复核。

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

发布后请确认 `/web/assistant/assistant.json` 真的以 JSON 返回（例如 `curl -I https://<站点>/web/assistant/assistant.json` 看 `content-type`）。`web/deploy/nginx.conf` 的 `try_files` 会把缺失文件伪装成 200 + `index.html`，此时页面只会提示“本站暂无可用的教务助手安装包”，不会显示下载按钮。

## 验收边界

已运行的自动化包括共享数据校验、解析与提醒计算、SSE 分帧、课表编辑及冲突、主要路由和移动导航，以及真实 Chromium 扩展加载和握手。Go 测试覆盖收藏、Origin 校验与个人 AI 授权/用量等边界。`web/e2e/assistant-install.spec.ts` 覆盖未装助手时的下载引导与安装步骤、装好后不刷新自动复检（并断言此间不发起学校查询）、以及安装包缺失或通道不符时的降级；`web/src/assistant-package.test.ts` 和 `browser-extension/src/inject.test.ts` 覆盖包清单校验与补注入的站点计划。

尚未完成真实账号的发布—审核—通知回读，以及本科、研究生、二课、体测四种学校来源的登录查询验收。Chrome/Edge 的重启、升级、多账号和系统通知还需实机验收。18 个页面的固定数据视觉对照也尚未全量完成，不能用路由冒烟代替。

教务助手引导交付的是解包（开发者模式）安装：真实 Edge 上“下载—解压—加载已解压扩展—页面免刷新复检”的完整链路、浏览器周期性提示或暂时停用非商店扩展的表现、以及更换解压目录导致扩展身份变化后本机资料需要重新读取，都只能人工验收。长期方案是发布到 Edge Add-ons 或 Chrome Web Store，目前尚未提交审核。

校园地图已复用 App 资源；食堂贡献列表、实拍、审核原因及评价编辑保留关联资料已接入；管理端已增加用户、版块、公告、版本、日志和 AI 指标入口。这些接口接入仍需真实账号验收，不能视为发布—审核—回读全链路已通过。

学业页已展示分模块学分要求、课程明细和本地缺口检查，切换栏目保留本次查询结果并标注来源及时间；毕业检查仅覆盖已返回的学分模块，不替代学校最终结论。

完整方案中仍需补齐的业务包括校园电话/办事指南、食堂治理细项、部分竞赛推荐与偏好、更完整的成绩详情及毕业条件覆盖等。当前已有页面及 API 接入不等于这些子流程全部完成。

学校凭据请只输入官网或助手页面。真实学校来源不可达、身份不具备对应能力或服务器拒绝时保留错误与旧数据，不以模拟响应确认完成。
