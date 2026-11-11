# 商店提交材料

此目录维护可填写的商店文案和审核说明。安装包由 `pnpm --filter @sylulive/extension package:store` 生成，路径为 `browser-extension/release-store/sylulive-assistant-<version>-store.zip`；同目录 `manifest.json` 包含版本、文件大小、文件列表与 SHA-256。它不表示已经上架或通过审核。

完成 Web 构建和商店构建后，运行 `node browser-extension/store/capture-assets.mjs`，在 `release-store/assets/` 生成两张 1280×800 的实际产品截图和一张 440×280 宣传图，另有尺寸与 SHA-256 清单。截图使用本机合成账号、未导入资料的实际页面，带演示标记；脚本阻止外部学校请求。提交材料包 `*-submission-kit.zip` 仅供查阅/交接，商店上传时应选其中的 `*-store.zip`，不要把整个材料包当作扩展上传。

## 中文展示文案

- 名称：沈理校园教务助手
- 简短描述：在自己的浏览器查询学校资料，连接沈理校园 Web，管理本地课表和提醒。
- 类别：工具 / Productivity（以后台实际选项为准）
- 语言：简体中文
- 主页：https://sylulive.online/web/
- 隐私页：https://sylulive.online/extension/privacy
- 支持方式：隐私页中与 App「关于」同步的开发者邮箱；提交账号的已验证联系邮箱由账号持有人设置。

详细描述：

沈理校园教务助手把用户自己浏览器中的学校查询与沈理校园 Web 连接起来，支持本科教务、研究生教务和第二课堂的 HTTPS 入口。用户按系统授予权限并登录学校后，可在网站中使用该系统实际支持的课表、成绩、考试或第二课堂查询，按需管理本机备份及课程提醒。查询会核对学校身份，学校账号与站点账号分别隔离。

学校密码仅用于用户发起的学校登录流程，不经网页消息桥上传到沈理校园服务器；可以自行选择是否在扩展本机记住凭据。提醒通知为可选权限。商店版不提供明文 HTTP 体测连接。学校入口是否可用仍取决于学校服务与账号权限。本扩展由社区开发，不代表学校官方。

## English listing

Name: SYLU Campus Academic Assistant

Summary: Connect your browser's school queries to SYLU Campus Web, with local schedules and optional reminders.

Description: This community extension connects SYLU Campus Web to supported HTTPS undergraduate, postgraduate and second-classroom portals in your own browser. Grant access to each school portal when needed, then use the datasets supported by that portal. School identity is checked around queries. Optional features include local credential storage, backups and schedule reminders. Passwords are used in the extension's school sign-in flow and are not passed through the website message bridge. The store build does not connect to the legacy HTTP physical-test portal. This extension is not an official university product.

## 权限与数据披露填写依据

单一用途：让用户在自己的浏览器中查询和管理本人学校资料，并连接沈理校园 Web。

| 权限 | 用户可见用途 |
| --- | --- |
| storage | 保存本机连接、用户选择保存的资料、凭据密文和设置 |
| scripting | 用户发起的学校登录和可信站点消息桥恢复 |
| alarms | 用户设置的本地课程、考试提醒 |
| notifications（可选） | 用户启用的提醒通知 |
| sylulive.online | 与用户正在使用的网站握手、核对网站登录状态 |
| jxw / yjsgl / webvpn.sylu.edu.cn（可选） | 对应系统的用户发起登录和学校资料查询 |

后台数据类别须如实选择个人身份信息（学号、姓名）、身份验证信息（学校登录凭据、会话）及网站内容（学校资料）。不能因为数据主要在本机处理就选择“完全不处理用户数据”。按实际后台术语逐项对应；未设置任何广告、数据售卖或 AI 外发用途。远程代码：否，随包打包执行代码。完整处理、流向、留存和删除说明见 [privacy.txt](privacy.txt)。

## 审核操作说明

1. 使用 Chrome/Edge 120 或以上，安装 ZIP 对应的商店候选构建。
2. 从主页进入 Web 的教务助手页面。无学校权限时应显示连接引导，不应自动查询学校。
3. 选择学校系统后才授予相应学校域名；用户在扩展助手页登录自己的学校账号。站点账号需自行登录。
4. 可检查课表/成绩等查询、身份切换拒绝旧连接、断开、清除本机凭据、可选提醒；体测显示商店版不支持。
5. 学校受限功能需要有效的学校账号。不能把本次实网测试的私人账号交给商店审核员，也不在 ZIP/文案中放真实凭据。若审核要求可重复访问，先由学校或维护者提供经授权的审核环境。

## 账号与最终提交

当前未注册商店开发者账号。账号持有人需完成实名/主体资料、验证与商店条款等注册步骤；本仓库不代填身份或支付资料。准备好账号后上传 ZIP，填写上述文案、权限解释、隐私页和截图，再提交审核。没有商店 item ID 时，网站继续使用现有手动安装入口，不伪造商店安装链接。审核通过后再配置真实链接并复核安装/更新流程。

公开隐私 URL 必须先通过正式部署发布，并验证 GET/HEAD 返回正文；本地候选已经覆盖 Go 路由和三份 Nginx 配置。生产发布受根目录 AGENTS.md 与 CONTRIBUTING.md 的授权约束。

官方入口（核对日期：2026-11-11）：[Chrome 发布流程](https://developer.chrome.com/docs/webstore/publish)、[Chrome 图片要求](https://developer.chrome.com/docs/webstore/images)、[Chrome 用户数据说明](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq)、[Edge 开发者账号](https://learn.microsoft.com/en-us/microsoft-edge/extensions/publish/create-dev-account)。
