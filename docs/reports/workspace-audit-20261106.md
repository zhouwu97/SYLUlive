# 2026-11-06 工作区全量审查与链路验证

## 范围与判定

本次按维护者“完整检查是否需要或落后，测试后推送并补全链路”的授权，审查 `E:\AI\xynewui` 的未提交快照。源 HEAD 为 `e19b33daad997e5301d86dfe8d4faedf2a0ed4d6`；隔离审查基准为 `d8dcd8a8885674fb5ff25e6fa07f2b089104b0c3`，分支 `codex/workspace-audit-20261106`。所有修改、合成数据库和测试产物位于隔离工作区；没有修改原 `zhou` 工作区，没有生产部署。

原始 378 项包括 200 项修改、8 项删除、170 项新增。逐文件清单、输入与结果 SHA-256 见 [清单](workspace-audit-20261106-files.tsv)。

| 判定 | 数量 | 处理 |
| --- | ---: | --- |
| accepted | 311 | 保留账号、机器人、上传/GIF、表情创作商城、教务同步、Web/扩展及其必要测试与文档 |
| reconciled | 10 | 对重叠文件合并较完整实现，保留本聊天已修复的上下文隔离、连接步骤和插件后台入口 |
| already-present | 6 | 目标 HEAD 已有等价内容，不重复修改 |
| excluded | 51 | 不采纳全部 8 项删除、撤销/放宽设计治理及只移除设计引用的改动；不收录 `web/preview/` 独立样机 |

121 项原始内容在其他本地分支已有相同 blob；“原目录未提交”不等于“从未完成”或“已经落后”。本次按目标分支实际缺口、依赖和验证结果保留业务内容，没有把 121 项简单当作废弃项。

明确保留现行 `AGENTS.md`、`CLAUDE.md`、`DEVELOPMENT_STANDARD.md`、`CONTRIBUTING.md`、UI PR 模板、Golden CI、设计文档/ADR，以及仍被接受 ADR 引用的方案。`README.md`、`docs/README.md`、`canteen_theme.dart`、`state_placeholder.dart` 中仅移除设计引用的改动也未采纳。

原目录在快照后发生内容变化的文件为 `web/src/academic.tsx`、`web/src/commons.css`、`web/src/pages.tsx`、`web/src/campus-chrome.tsx`、`web/e2e/market-presentation.spec.ts`、`web/e2e/desktop-reference.spec.ts`。已读取差异；新增空态图标、集市图片选择和部分相同方向的测试修订留在原目录，不覆盖、不自动混入固定快照。本轮在隔离分支中独立修正必要测试。

## 修正与保留行为

- 插件权限后台版本由落后的 `0.5.0` 对齐 metadata/main/build 的 `0.5.7`，避免构建验证误判；打包清单包含 `chat_context.py` 和新增运行模块。
- Web 恢复 `invalid_scope` 中文恢复提示，说明插件与服务端的权限协议不一致，保留原授权。
- 媒体夹具区分校园帖子与 `board=2` 集市侧栏，分页夹具只接管 `feed_pagination_meta_v1` 请求，避免把侧栏请求消费为分页失败。保留原图、预览、重试、偏移及迟到响应断言。
- 更新落后桌面测试：服务入口迁移至首页六个常用入口和右栏工具箱；通过命名组件检查卡片高度，新增日历不改变断言对象；没有置顶时隐藏公共帖子区，同时验证动态空态；阴影比较真实卡片，仍检查无渐变/毛玻璃、逐帧布局、键盘导航和滚动可达。没有删除失败用例或更新 canonical Golden。
- 保留当前图片/连发上下文隔离与私有记忆边界，保持原生 hook 顺序；保留双账号运行隔离、独立 bot 身份、scope 最小化、撤权和取消、refresh 轮换、运行租约与写入复核。
- 表情商城保持免费、创作者独立权限、逐版本审核和不可变上架；GIF v2 保留透明度，旧 v1 与原图回退保留。学校密码留在客户端/扩展本机存储，不进入同步快照。
- 本机 guardian 保留为可选运维工具，已测试但未安装、未启动守护、未重启现有机器人。真实 AI 验证脚本保留为显式选择入口，未调用付费模型。

## 验证环境与结果

Windows；Flutter 3.41.8/Dart 3.11.5；Python 3.12、真实 AstrBot 4.29.3 SDK；Go 使用 Strawberry gcc 且 CGO 开启；浏览器为 Playwright Chromium；PostgreSQL 使用本轮新建、仅监听本机的可丢弃集群。浏览器独立端口 5273，未接管原目录 5173 服务；未模拟的 API 指向本机不可达端口 9，禁止转发生产。扩展测试学校域名由夹具接管并封锁真实 DNS。

| 检查 | 结果与证据（证据位于本地 `scratch/workspace-audit/`） |
| --- | --- |
| Web/扩展依赖、类型、单测、构建 | frozen lockfile 安装、`pnpm -r check`、`pnpm test`（21 文件/148 项）、`pnpm -r build` 通过；最终类型/构建再次通过。构建保留现有 chunk 体积提醒 |
| Web Playwright | 首轮 229/239 通过、10 失败；定位后受影响 28 项全部通过；最终整套 239/239 通过，`web-e2e-final.txt` |
| 插件后台 Playwright | 12 项全部通过，含新增教程入口、异常目标拒绝、权限保存/失败恢复和深浅窄宽渲染，`permissions-ui-final.txt` |
| Python | compileall 通过；插件及 3 个脚本测试 560 passed、1 skipped、4 subtests passed；跳过为可选 Stealer 源码未配置；保留 AstrBot register_star 弃用警告，`python-final.txt` |
| AstrBot 原生合并插件 | 当前候选源码与实际 reply_merge 源码的原生 hook 回放通过；两图输入、无重复用户文本、排除预测补写；外部模型调用和 QQ 外发为 0，`native-reply-merge-final.txt` |
| Flutter | 完整测试 3443 passed、7 skipped（6 项既有私聊功能关闭，1 项表情链路需独立服务夹具且已在专项链路执行通过）；机器人连接/管理补跑 56 项通过并输出实际渲染图，`flutter-full-first.txt`、`flutter-bot-render-final.txt` |
| Flutter 静态检查 | 当前 381 项、有效 HEAD 基准 390 项，无新增诊断；analyze 因存量问题退出 1，不能写作静态检查全绿，`flutter-analyzer-delta.json` |
| Go 标准检查 | `go vet ./...`、`go test -p 2 ./...`、`go build ./...` 均 exit 0，`go-vet.txt`、`go-full.txt`、`go-build.txt` |
| Go 竞态 | services/handlers 的 `^TestIntegration` 在 `-race -count=1` 下通过，`go-race.txt` |
| PostgreSQL | tagged models、handlers 通过；services 首轮有一项并发超时，原断言单测和整组 services 后续通过，见下文 |
| 真实服务启动与收藏持久化 | 新 PostgreSQL 集群、真实二进制启动/重启、建表、鉴权、幂等收藏、列表持久化和幂等删除通过，集群自动停止，`bookmark-startup.json` |
| Web → Go → Python → AstrBot | 推送前、推送后 11 步均通过，真实 HTTP/原生 SDK 工具循环，合成 Provider，`cross-runtime-first.txt`、`cross-runtime-post-push.txt` |
| Flutter → Go 表情链路 | 推送前、推送后均通过；真实 TLS 路由、SQLite 与上传卷，导入→创作者申请/审核→不可变发布→下载→面板→评论上传提交→下架，`emoji-chain-first.txt`、`emoji-chain-post-push.txt` |

## 首次失败和处理

1. Web 首轮 10 项失败中，媒体/分页为新侧栏请求导致夹具范围过宽；桌面布局/入口/空态/材质断言滞后于当前产品实现。修复夹具并按当前语义保留功能断言，受影响 28 项通过。
2. 二课真实扩展首轮第二次自动登录 20 秒未返回；诊断轮可继续完成该步骤但整项 120 秒耗尽。当时多个完整套件并发高负载；无源码或 timeout 修改的独立重跑在 42.1 秒完成全部流程。首次两份证据分别为 `web-e2e-first.txt`、`extension-diagnostic.txt`，独立验证为 `extension-isolated.txt`。不以重复运行抹去首败。
3. PostgreSQL services 首轮 `TestSecurityEventDistinctBucketsDoNotSerializeOnInProcessLock` 在 16 并发、机器高负载时超时。保留测试与时限；独立原用例峰值并发 16、734ms 通过，整组 tagged services 39.157s 通过。证据 `go-postgres-first.txt`、`go-postgres-concurrency-recheck.txt`、`go-postgres-services-final.txt`。
4. 最初 Qt/MSYS gcc 链接/cgo 环境不可用，保留 `go-full-msys.txt` 与 `go-link-diagnostic.txt`；切换可用 Strawberry 工具链，没有关闭 CGO 或绕过 SQLite。
5. Flutter 初次基准副本遗漏本地 path 依赖，不能作为有效对照。补齐相同 HEAD 的依赖后得到有效基准 390 项；报告只使用 `flutter-analyze-baseline-final.txt`。

## Design QA 与状态矩阵

沿用现行设计规范和 accepted ADR；没有引入新 Theme seed、动效系统或依赖。机器人连接/管理、表情创作、个人数据页和媒体适用状态由现有完整测试及专项补跑覆盖：loading、empty、error、retry、disabled、敏感权限默认关闭、取消、撤权、异步晚到、切号、输入焦点、键盘、图片加载/损坏/重试。可见运行状态与真正执行端状态区分展示。

实际查看了机器人连接 dark/1.5×、教程 light/1.3×、机器人管理 dark/1.5×、表情商城详情/编辑预览、桌面首页与暗色移动媒体卡截图。正文换行、操作按钮和滚动无明显遮挡；Widget 几何/异常断言通过。Windows 截图用于本机布局审核，没有修改 Ubuntu canonical Golden。

- P0：本轮已覆盖路径未发现未解决项。
- P1：本轮已覆盖路径未发现未解决项；首次失败及归因完整保留。
- P2：Flutter 存量 analyzer 问题留在原有范围，本批无新增；正式平台视觉基线未在 Windows 上更新。
- P3：Web chunk 体积和 SDK 弃用提醒保留，未为本次修复引入依赖升级。

## 恢复与未验证范围

本次只推送独立分支，不合并 `zhou`，不修改部署开关、权限配置或运行中机器人。回退使用上一个固定版本；启用运行协议和 GIF v2 时按 `docs/ops/astrbot-integrations.md` 与 `DEPLOY.md` 先停执行端/旧 worker，保留数据库新增字段、旧变体、授权与发言账本。表情版本与已安装本地副本不因回退擦除。

未执行生产 QQ 收发、付费模型、真实学校凭据登录、生产迁移/部署、Android/iOS 真机和 Linux canonical Golden。Web/Go/Python/AstrBot 与 Flutter/Go 的链路使用真实运行时及本地合成数据，不能等同生产验收。原目录快照后的六个文件变化仍需其所属任务完成审核。

逐文件扫描未发现本轮新增的私钥、GitHub token、API key 模式或超过 10MiB 的新增文件；构建物、测试库、截图和日志保留在 ignored 目录，不随源码提交。推送前仍执行暂存差异和空白检查。

## 推送后验收

首次推送提交 `380a68ae6fad03f31adc54e363637e202d87f91f`；`git ls-remote` 确认远端同名分支指向该 SHA。服务端与插件、Flutter、Web、支持工具分别形成 4 个中文提交。本节是其后的纯文档补交，不改变已验证业务代码。

- `go test -p 1 ./internal/handlers -run '^TestIntegrationWebAstrBotCrossRuntime$' -count=1 -v`：25.06 秒通过；Web 授权、显式权限与启用、成绩/二课同步、Python HTTP 回读、原生 SDK 私聊与自主工具循环、两账号运行/暂停隔离、跨用户拒绝、并发 refresh、撤权和设备取消全部通过。`production_requests=0`、`qq_sends=0`。
- `scripts/verify-emoji-chain.ps1`：Flutter 集成用例及真实 Go fixture 通过；评论图片实际上传并提交，产生 `emoji-chain-post-push/` 的日志与截图。
- 重新打包插件并核验 `build.json`：版本 0.5.7、`source_dirty=false`、源码提交与已推送 SHA 一致；33 个打包文件的 ZIP/manifest/工作区 SHA-256 全部一致，包含上下文与独立运行模块。包与证据保留本机，不提交 ZIP。
- 本轮专用 PostgreSQL 已停止；独立 Vite 和权限实验页在最后核验后关闭。原目录 5173 服务与现有机器人不由本任务重启或停止。
