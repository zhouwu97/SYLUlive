# 试卷库界面优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成试卷库、投稿、我的投稿和审核管理四个 Flutter 页面 P0 优化，并补齐个人投稿筛选、管理员检索排序和快捷审核所需的 P1 服务端能力。

**Architecture:** 页面继续负责请求、分页、导航与提交；新增 `widgets/exam_papers/` 领域组件负责工具栏、状态徽标、列表卡片、空状态、骨架屏和投稿步骤展示。组件只接收值与回调，不依赖 `ExamPaperService`，以便独立 Widget 测试。

**Tech Stack:** Flutter 3 / Dart、Material 3、Provider、flutter_test。

---

### Task 1: 共享状态与列表组件

**Files:**
- Create: `client/lib/widgets/exam_papers/exam_paper_status_badge.dart`
- Create: `client/lib/widgets/exam_papers/exam_paper_empty_state.dart`
- Create: `client/lib/widgets/exam_papers/exam_paper_list_skeleton.dart`
- Modify: `client/lib/widgets/exam_paper_card.dart`
- Test: `client/test/widgets/exam_paper_card_test.dart`
- Create: `client/test/widgets/exam_paper_shared_widgets_test.dart`

- [ ] **Step 1: 写失败测试**

验证公开卡片不显示“已通过”，管理变体显示状态，空状态动作可点击，骨架屏固定生成三项。

- [ ] **Step 2: 运行测试确认 RED**

Run: `flutter test test/widgets/exam_paper_card_test.dart test/widgets/exam_paper_shared_widgets_test.dart`
Expected: FAIL，缺少共享组件与卡片变体参数。

- [ ] **Step 3: 实现最小组件**

`ExamPaperCard` 增加 `showStatus`、`footer` 与紧凑布局；状态颜色集中到 `ExamPaperStatusBadge`；空状态接收 `icon/title/message/primaryAction`；骨架屏固定三项且不改变列表宽度。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `flutter test test/widgets/exam_paper_card_test.dart test/widgets/exam_paper_shared_widgets_test.dart`
Expected: PASS。

### Task 2: 试卷库紧凑工具栏与真实总数

**Files:**
- Create: `client/lib/widgets/exam_papers/exam_paper_toolbar.dart`
- Modify: `client/lib/screens/exam_papers/exam_paper_library_screen.dart`
- Modify: `client/test/screens/exam_paper_library_screen_test.dart`

- [ ] **Step 1: 写失败测试**

覆盖“搜索课程名或关键词”、接口 `total`、筛选计数、清除筛选、无结果双动作，以及刷新失败时保留旧列表。

- [ ] **Step 2: 运行测试确认 RED**

Run: `flutter test test/screens/exam_paper_library_screen_test.dart`
Expected: FAIL，现有页面没有摘要、清除和保留内容错误条。

- [ ] **Step 3: 实现工具栏与页面状态**

保存 `_total`；区分初次加载与已有内容刷新；工具栏通过回调更新四个条件；空搜索结果允许清除条件或带课程名打开投稿页；公开卡片隐藏状态。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `flutter test test/screens/exam_paper_library_screen_test.dart`
Expected: PASS。

### Task 3: 投稿步骤与固定提交区

**Files:**
- Create: `client/lib/widgets/exam_papers/exam_paper_upload_step_header.dart`
- Modify: `client/lib/screens/exam_papers/exam_paper_upload_screen.dart`
- Create: `client/test/screens/exam_paper_upload_screen_test.dart`

- [ ] **Step 1: 写失败测试**

通过可注入的文件选择回调测试：初始提交禁用；课程、有效 PDF、隐私确认完成后启用；展示文件名、大小和“校验通过”；失败后表单仍存在。

- [ ] **Step 2: 运行测试确认 RED**

Run: `flutter test test/screens/exam_paper_upload_screen_test.dart`
Expected: FAIL，页面尚无可注入选择器、步骤头和禁用条件。

- [ ] **Step 3: 实现投稿页**

为页面增加可选 `pickFile` 与预填元数据参数；本地计算四步完成状态；提交区放入 `bottomNavigationBar` 并预留安全区；上传异常使用页面内错误条，保留表单与文件。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `flutter test test/screens/exam_paper_upload_screen_test.dart`
Expected: PASS。

### Task 4: 我的投稿状态与可行动空态

**Files:**
- Modify: `client/lib/screens/exam_papers/my_exam_paper_submissions_screen.dart`
- Modify: `client/test/screens/my_exam_paper_submissions_screen_test.dart`

- [ ] **Step 1: 写失败测试**

覆盖空态“去投稿”、待审核“管理员审核中”、已通过“已收录至试卷库”、已下架原因与“重新投稿”。

- [ ] **Step 2: 运行测试确认 RED**

Run: `flutter test test/screens/my_exam_paper_submissions_screen_test.dart`
Expected: FAIL，现有卡片没有状态说明和对应动作。

- [ ] **Step 3: 实现状态脚注与导航**

按 `ExamPaper.status` 生成说明与操作；重新投稿只传入课程、学年、学期、类型，不复用远端文件；空态进入投稿页；加载更多失败保持现有列表。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `flutter test test/screens/my_exam_paper_submissions_screen_test.dart`
Expected: PASS。

### Task 5: 审核页统一状态

**Files:**
- Modify: `client/lib/screens/exam_papers/admin_exam_papers_screen.dart`
- Create: `client/test/screens/admin_exam_papers_screen_test.dart`

- [ ] **Step 1: 写失败测试**

通过可注入 `ExamPaperService` 验证待审核空态文案、重试动作、卡片“预览/审核”操作与列表状态徽标。

- [ ] **Step 2: 运行测试确认 RED**

Run: `flutter test test/screens/admin_exam_papers_screen_test.dart`
Expected: FAIL，页面尚不可注入服务且使用简单空文本。

- [ ] **Step 3: 实现审核页**

构造器支持测试服务；初次加载使用骨架；无数据使用共享空状态；错误使用共享空状态；菜单文案收敛为“预览 PDF / 审核投稿 / 管理试卷”。

- [ ] **Step 4: 运行测试确认 GREEN**

Run: `flutter test test/screens/admin_exam_papers_screen_test.dart`
Expected: PASS。

### Task 6: 响应式与全量验证

**Files:**
- Modify: 上述测试文件（仅在发现明确回归时补充）

- [ ] **Step 1: 运行格式化**

Run: `dart format lib/screens/exam_papers lib/widgets/exam_paper_card.dart lib/widgets/exam_papers test/screens test/widgets`
Expected: exit 0。

- [ ] **Step 2: 运行试卷域测试**

Run: `flutter test test/exam_paper_model_test.dart test/exam_paper_service_test.dart test/widgets/exam_paper_card_test.dart test/widgets/exam_paper_shared_widgets_test.dart test/screens/exam_paper_library_screen_test.dart test/screens/exam_paper_upload_screen_test.dart test/screens/my_exam_paper_submissions_screen_test.dart test/screens/admin_exam_papers_screen_test.dart test/screens/exam_paper_preview_screen_test.dart`
Expected: PASS。

- [ ] **Step 3: 运行静态分析**

Run: `flutter analyze lib/screens/exam_papers lib/widgets/exam_paper_card.dart lib/widgets/exam_papers test/screens test/widgets`
Expected: 无新增 error。

- [ ] **Step 4: 运行全量测试**

Run: `flutter test`
Expected: PASS。

- [ ] **Step 5: 检查变更范围**

Run: `git diff --check && git status --short`
Expected: 无空白错误，只有本计划与试卷库 P0 相关文件。

### Task 7: P1 查询接口与客户端集成

**Files:**
- Modify: `server/internal/handlers/exam_paper.go`
- Modify: `server/internal/handlers/exam_paper_test.go`
- Modify: `server/internal/handlers/exam_paper_admin_test.go`
- Modify: `client/lib/models/exam_paper.dart`
- Modify: `client/lib/services/exam_paper_service.dart`
- Modify: `client/test/exam_paper_service_test.dart`
- Modify: `client/lib/screens/exam_papers/my_exam_paper_submissions_screen.dart`
- Modify: `client/lib/screens/exam_papers/admin_exam_papers_screen.dart`

- [ ] **Step 1: 用失败测试定义接口契约**

个人投稿支持 `status` 并返回 `status_counts`；管理员列表支持 `keyword`、`contributor` 和 `sort`。

- [ ] **Step 2: 运行 Go 与 Dart 测试确认 RED**

Run: `go test ./internal/handlers -run 'TestExamPaperMySubmissionsFiltersStatusAndReturnsCounts|TestAdminExamPaperListFiltersKeywordContributorAndSort' -count=1`
Run: `flutter test --no-pub test/exam_paper_service_test.dart`
Expected: FAIL，现有接口忽略筛选参数且客户端没有对应签名。

- [ ] **Step 3: 实现查询、计数与参数解析**

后端只使用现有字段，不创建数据库迁移；客户端解析状态计数并将筛选条件随分页请求传递。

- [ ] **Step 4: 接入页面控件与快捷审核**

我的投稿使用服务端状态筛选和计数；管理员页使用服务端关键词、投稿人和排序。快捷通过调用现有 `approve`，提交前展示完整标题并二次确认；退回仍进入审核页填写理由。

- [ ] **Step 5: 运行前后端定向测试确认 GREEN**

Run: `go test ./internal/handlers -count=1`
Run: `flutter test --no-pub test/exam_paper_service_test.dart test/screens/my_exam_paper_submissions_screen_test.dart test/screens/admin_exam_papers_screen_test.dart`
Expected: PASS。

### Task 8: 生产部署与验收

**Files:**
- Server source: `/opt/shenliyuan-src`
- Runtime: `/opt/shenliyuan/shenliyuan`

- [ ] **Step 1: 只读核对线上基线**

检查 systemd、源码分支与提交、工作区、磁盘、Go 版本、健康接口；不得读取或输出 `.env` 值。

- [ ] **Step 2: 部署前备份与构建**

备份当前二进制；在干净源码目录同步已验证提交；运行 Go 测试并构建 `.new` 二进制。

- [ ] **Step 3: 原子替换并重启**

保留带时间戳的旧二进制，原子移动新二进制，重启 `shenliyuan`；失败时立即恢复旧二进制。

- [ ] **Step 4: 线上验收**

确认 `systemctl is-active`、健康接口、版本接口、最近日志无启动错误，并用已认证测试路径验证新增查询参数不会返回 5xx。
