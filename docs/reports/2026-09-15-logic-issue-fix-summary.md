# 逻辑问题修复记录

**日期**：2026-09-15
**输入**：`docs/reports/2026-09-15-logic-issue-audit.md`（2 高危 / 6 中危 / 5 客户端 / 7 低危，共 20 条）
**分支**：`diaofenyuan`（已推送，远端 = 本地 = `756609a9`）
**粒度**：一个问题一个提交（M2 另有一笔后续修正提交），共 22 笔

---

## 一、提交对照表

| 编号 | 提交 | 要点 |
|---|---|---|
| — | `c8c17d9a` | 审计报告入库，作为修复基线 |
| H1 | `b7cd724e` | `routers/spider.py`/`routers/erke.py` 补 `require_internal_service`；Go 侧 `/api/erke/scores` 转发补发 `X-Internal-Service-Token` |
| H2 | `4f56e5ff` | `main()` 时区初始化改 fail-fast；新增 `academiccalendar.DayStart` 把"自然日"收敛到单一口径 |
| M1 | `f1eaa353` | 管理员经验扣减改原子表达式（`models.PenalizeAdminExpOnAppealPass`）；法定票数下限抽 `models.AppealMinRequiredVotes` |
| M2 | `f1dd13c6` | 社区规则门禁从"路径前缀猜"改为路由显式挂载（`middleware.RequireCommunityRules`） |
| M2 后续 | `fa33a789` | 门禁拒绝时补置 `idempotency_auth_rejected`，否则 403 会被写进幂等记录、确认后重试被永久重放 |
| M3 | `3f2de224` | 一批"查询失败被当空数据"改为 5xx：canteen_reviews / canteen_rankings / user / feedback_ticket*，顺带修 `AdminGetStats` 5 个计数 |
| M4 | `91aa8318` | 成绩分页加 `MAX_GRADE_PAGES` / 条数上限 + 重复页指纹检测 |
| M5 | `7dc49620` | 水帖版主操作写库失败不再返回 200（本文件 8 处 Update/Delete/Count 全部接错误） |
| M6 | `6ff647ca` | 评价历史 `can_delete`/`can_edit` 按视图者身份判定 |
| C1 | `ab608b79` | `_loadingMore` 无条件复位，切会话后上滑加载不再永久失效 |
| C2 | `3011f0c4` | 翻页自增版本号 + 用发起时的页码决定覆盖/合并，不再整页跳过 |
| C3 | `52055ecb` | AI 本地历史逐条容错（枚举 orElse、时间 tryParse、坏记录跳过） |
| C4 | `1892e7b4` | 版块兜底查找补 `orElse` |
| C5 | `10cf4d00` | 6 个文件的无保护 `int.parse` 统一改 `tryParse`（学年 / 课时串） |
| L1 | `ae7a06c0` | 课表去重键补上老师、地点、周次 |
| L2 | `f3d7784d` | 明细无"总"项时返回空值，不再拿最后一行当总评 |
| L3 | `6f5a0cd5` | 二课登录表单不再同时提交明文密码（`Password` 传空串） |
| L4 | `bb9c8298` | `competition.go` 4 处 `ShouldBindJSON` 错误不再被忽略 |
| L5 | `214862fc` | 19 个文件 46 处 `== gorm.ErrRecordNotFound` 统一为 `errors.Is` |
| L6 | `fffd0f25` | RAG 服务令牌改用 `hmac.compare_digest`（并统一 encode 成 bytes） |
| L7 | `756609a9` | 调试脚本不再打印 ticket / Cookie 片段，改为长度 + 指纹 |

---

## 二、修复过程中额外发现并一并处理的问题

这些不在原报告条目内，但属同一失败模式，已包含在对应提交里：

1. **M2 的幂等契约缺失（`fa33a789`）** —— 门禁移到路由层后漏掉
   `idempotency_auth_rejected` 标记：社区规则 403 会被当作业务响应存进幂等记录，
   用户确认规则后用同一个 `Idempotency-Key` 重试会一直重放 403。
   这是本次唯一一处"改出来的问题"，已由既有的
   `TestCommunityRulesConsentAllowsRepeatedLikesAndSurvivesLegalRenewal` 捕获。
2. `feedback_ticket_admin.AdminGetStats` 5 个概览计数失败返回全 0 → 角标显示成
   "没有待处理工单"（M3）。
3. `water_moderation.go` 另外 7 处写操作 / 回读失败被吞（M5）。
4. `competition.go:2335` 禁用分享快照时原因静默丢失（L4）。
5. `test_erke.py` 同一处明文密码提交（L3）。

---

## 三、验证方式与局限

| 范围 | 本地可验证 | 说明 |
|---|---|---|
| Go | `go build ./...`、`go vet ./...`、`gofmt` 全绿 | 测试只能跑 glebarez（纯 Go sqlite）用例；用 `gorm.io/driver/sqlite` 的用例本机无 gcc 一律 CGO 失败，由 CI 覆盖。最终一轮 handlers/models/middleware 共 30 个失败**全部**是 CGO 阻塞，真实失败 0 |
| python-edu-service | 全量 `pytest -q` → **334 passed** | 已建隔离 venv 装 `requirements-test.txt` |
| python-rag-service | `compileall` + 判定逻辑本地复算 | 依赖重（fastembed/langchain），pytest 交 CI |
| client（Flutter） | `dart analyze`（含 test 文件）无新增问题 | `flutter test` 本机因 SDK 版本不一致必然失败（objective_c 原生构建），与本次改动无关 |

新增/更新的测试共 **9 个文件**：Go 4（erke 转发、申诉经验、社区规则门禁、删帖失败、置顶绑定）、
Python 5（个人路由鉴权、分页守护、课表去重、二课登录表单、总评回退）、Dart 3（消息翻页、feed 翻页、AI 历史）。

---

## 四、未处理（原报告明确留白的区域）

原报告第六、八节列出的"已复核无问题"与"未覆盖区域"未在本轮改动，其中
`server/internal/ai/` 的策略/权限执行链仍建议单独排期审查。
