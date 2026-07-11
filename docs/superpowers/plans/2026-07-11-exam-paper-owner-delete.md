# 试卷投稿删除与经验撤销实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 允许投稿人永久删除自己的已发布或已下架试卷，并保证用户删除或管理员下架只会撤销一次 10 经验奖励。

**Architecture:** 继续使用现有投稿删除路由，由服务端根据锁定后的试卷状态区分撤回和永久删除。`rewarded_at` 与新增的 `reward_revoked_at` 共同形成奖励状态机，共享事务 helper 原子扣减经验；Flutter 根据服务端返回的 `reward_revocable` 提供准确确认文案，并在操作成功后重新加载列表与计数。

**Tech Stack:** Go 1.25、Gin、GORM、PostgreSQL/SQLite、Flutter/Dart、Dio、flutter_test。

---

## 文件结构

- `server/internal/models/exam_paper.go`：保存 `RewardRevokedAt` 审计字段。
- `server/internal/handlers/exam_paper.go`：返回奖励可撤销状态，封装经验撤销事务，扩展用户删除和管理员下架行为。
- `server/internal/handlers/exam_paper_test.go`：覆盖投稿人删除、权限、幂等和事务回滚。
- `server/internal/handlers/exam_paper_admin_test.go`：覆盖管理员下架撤销奖励和未奖励试卷不扣经验。
- `client/lib/models/exam_paper.dart`：解析 `reward_revocable`。
- `client/lib/services/exam_paper_service.dart`：调用删除接口并解析 `exp_revoked`。
- `client/lib/screens/exam_papers/my_exam_paper_submissions_screen.dart`：展示删除入口、确认弹窗和操作状态。
- `client/test/exam_paper_service_test.dart`：覆盖请求方法、路径与删除响应解析。
- `client/test/screens/my_exam_paper_submissions_screen_test.dart`：覆盖按钮、确认、取消、成功刷新和失败保留。

### Task 1: 奖励撤销模型与管理员下架

**Files:**
- Modify: `server/internal/models/exam_paper.go`
- Modify: `server/internal/handlers/exam_paper.go`
- Test: `server/internal/handlers/exam_paper_admin_test.go`
- Test: `server/internal/handlers/exam_paper_test.go`

- [ ] **Step 1: 写管理员下架撤销奖励的失败测试**

在 `exam_paper_admin_test.go` 新增一个已发放奖励的 published fixture，调用 `AdminUnpublish` 后断言经验从 80 变为 70、`RewardRevokedAt` 非空、消息包含“扣回 10 经验”；再调用一次断言返回冲突且经验仍为 70。

```go
func TestAdminUnpublishExamPaperRevokesRewardOnce(t *testing.T) {
	env := newExamPaperTestEnv(t)
	contributor := createExamPaperTestUser(t, env.db, "rewarded-unpublish-user", models.RoleUser, true, 80)
	admin := createExamPaperTestUser(t, env.db, "rewarded-unpublish-admin", models.RoleAdmin, false, 0)
	paper := createStoredExamPaper(t, env, contributor, models.ExamPaperStatusPublished)
	now := time.Now().Add(-time.Hour)
	env.db.Model(&paper).Update("rewarded_at", now)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	first := performExamPaperJSONRequest(env.handler.AdminUnpublish, http.MethodPost, "/api/admin/exam-papers/1/unpublish", params, admin.ID, map[string]any{"reason": "内容失效"})
	if first.Code != http.StatusOK {
		t.Fatalf("下架失败: status=%d body=%s", first.Code, first.Body.String())
	}
	var refreshedPaper models.ExamPaper
	var refreshedUser models.User
	env.db.First(&refreshedPaper, paper.ID)
	env.db.First(&refreshedUser, contributor.ID)
	if refreshedPaper.RewardRevokedAt == nil || refreshedUser.Exp != 70 {
		t.Fatalf("奖励撤销错误: paper=%#v exp=%d", refreshedPaper, refreshedUser.Exp)
	}

	second := performExamPaperJSONRequest(env.handler.AdminUnpublish, http.MethodPost, "/api/admin/exam-papers/1/unpublish", params, admin.ID, map[string]any{"reason": "重复下架"})
	if second.Code != http.StatusConflict {
		t.Fatalf("重复下架应冲突: status=%d", second.Code)
	}
	env.db.First(&refreshedUser, contributor.ID)
	if refreshedUser.Exp != 70 {
		t.Fatalf("重复下架不得重复扣经验: %d", refreshedUser.Exp)
	}
}
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `cd server && go test ./internal/handlers -run TestAdminUnpublishExamPaperRevokesRewardOnce -count=1`

Expected: 编译失败，提示 `RewardRevokedAt undefined`。

- [ ] **Step 3: 增加模型字段、响应字段与共享撤销 helper**

在 `ExamPaper` 增加：

```go
RewardRevokedAt *time.Time `json:"reward_revoked_at,omitempty"`
```

在 `examPaperResponse` 增加字段，并在 `examPaperToResponse` 中设置：

```go
RewardRevocable bool `json:"reward_revocable"`

RewardRevocable: paper.RewardedAt != nil && paper.RewardRevokedAt == nil,
```

在 handler 中增加共享 helper：

```go
const examPaperRewardExp = 10

func revokeExamPaperReward(tx *gorm.DB, paper *models.ExamPaper, now time.Time) (bool, error) {
	if paper.RewardedAt == nil || paper.RewardRevokedAt != nil {
		return false, nil
	}
	result := tx.Model(&models.User{}).Where("id = ?", paper.SubmitterID).
		UpdateColumn("exp", gorm.Expr("CASE WHEN exp >= ? THEN exp - ? ELSE 0 END", examPaperRewardExp, examPaperRewardExp))
	if result.Error != nil {
		return false, result.Error
	}
	if result.RowsAffected != 1 {
		return false, gorm.ErrRecordNotFound
	}
	if err := tx.Model(paper).UpdateColumn("reward_revoked_at", now).Error; err != nil {
		return false, err
	}
	paper.RewardRevokedAt = &now
	return true, nil
}
```

- [ ] **Step 4: 在管理员下架事务中撤销奖励**

锁定 published 试卷后先调用 `revokeExamPaperReward`，把返回值用于系统消息和管理员日志；未获得奖励的管理员直传试卷返回 `false`，经验保持不变。

```go
revoked, err := revokeExamPaperReward(tx, &locked, now)
if err != nil {
	return err
}
message := fmt.Sprintf("你投稿的试卷《%s》已下架。\n下架理由：%s", locked.Title, input.Reason)
if revoked {
	message += "\n该投稿获得的 10 经验已扣回。"
}
```

- [ ] **Step 5: 运行管理员和响应测试确认 GREEN**

Run: `cd server && go test ./internal/handlers -run 'TestAdmin(Unpublish|UpdateAndUnpublish)|TestExamPaperMySubmissions' -count=1`

Expected: PASS。

- [ ] **Step 6: 提交后端奖励撤销增量**

```bash
git add server/internal/models/exam_paper.go server/internal/handlers/exam_paper.go server/internal/handlers/exam_paper_admin_test.go server/internal/handlers/exam_paper_test.go
git commit -m "feat: 下架试卷时撤销投稿奖励"
```

### Task 2: 投稿人永久删除接口

**Files:**
- Modify: `server/internal/handlers/exam_paper.go`
- Test: `server/internal/handlers/exam_paper_test.go`

- [ ] **Step 1: 写 published、unpublished、权限和幂等失败测试**

新增表驱动测试，创建 `RewardedAt` 非空的本人试卷并调用现有 DELETE 路由：

```go
func TestExamPaperOwnerDeletesPublishedAndUnpublishedWithSingleRewardRevoke(t *testing.T) {
	for _, status := range []models.ExamPaperStatus{models.ExamPaperStatusPublished, models.ExamPaperStatusUnpublished} {
		t.Run(string(status), func(t *testing.T) {
			env := newExamPaperTestEnv(t)
			user := createExamPaperTestUser(t, env.db, "delete-owner-"+string(status), models.RoleUser, true, 30)
			paper := createStoredExamPaper(t, env, user, status)
			now := time.Now().Add(-time.Hour)
			env.db.Model(&paper).Update("rewarded_at", now)
			params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

			response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
			if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"exp_revoked":true`) {
				t.Fatalf("删除失败: status=%d body=%s", response.Code, response.Body.String())
			}
			var count int64
			var refreshed models.User
			env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&count)
			env.db.First(&refreshed, user.ID)
			if count != 0 || refreshed.Exp != 20 {
				t.Fatalf("删除结果错误: count=%d exp=%d", count, refreshed.Exp)
			}

			repeat := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
			if repeat.Code != http.StatusNotFound {
				t.Fatalf("重复删除应返回 404: %d", repeat.Code)
			}
			env.db.First(&refreshed, user.ID)
			if refreshed.Exp != 20 {
				t.Fatalf("重复删除不得重复扣经验: %d", refreshed.Exp)
			}
		})
	}
}
```

另加测试：非投稿人返回 404；`RewardRevokedAt` 已有值的 unpublished 记录删除后经验不变；管理员直传且未奖励的本人试卷删除后经验不变；删除回调注入错误时返回 500 且记录和经验均回滚。回滚测试使用 GORM Delete callback 对 `ExamPaper` 注入固定错误，请求结束后移除 callback，避免影响其他测试。

- [ ] **Step 2: 运行测试确认 RED**

Run: `cd server && go test ./internal/handlers -run 'TestExamPaperOwnerDelete|TestExamPaperDeleteTransaction' -count=1`

Expected: published/unpublished 当前返回 `409 exam_paper_not_pending`。

- [ ] **Step 3: 扩展现有 DELETE handler**

保留路由和 `Withdraw` 方法名以兼容已有调用；事务锁定本人试卷后按状态执行：

```go
switch locked.Status {
case models.ExamPaperStatusPending:
	// 未发放奖励，直接删除。
case models.ExamPaperStatusPublished, models.ExamPaperStatusUnpublished:
	revoked, err = revokeExamPaperReward(tx, &locked, time.Now())
	if err != nil {
		return err
	}
default:
	return errExamPaperNotDeletable
}
return tx.Delete(&locked).Error
```

成功响应：

```go
message := "投稿已撤回"
if paper.Status != models.ExamPaperStatusPending {
	message = "投稿已永久删除"
}
c.JSON(http.StatusOK, gin.H{"message": message, "exp_revoked": revoked})
```

- [ ] **Step 4: 运行 handler 全量测试确认 GREEN**

Run: `cd server && go test ./internal/handlers -count=1`

Expected: PASS。

- [ ] **Step 5: 提交投稿人删除增量**

```bash
git add server/internal/handlers/exam_paper.go server/internal/handlers/exam_paper_test.go
git commit -m "feat: 允许投稿人永久删除试卷"
```

### Task 3: Flutter 模型与服务契约

**Files:**
- Modify: `client/lib/models/exam_paper.dart`
- Modify: `client/lib/services/exam_paper_service.dart`
- Test: `client/test/exam_paper_model_test.dart`
- Test: `client/test/exam_paper_service_test.dart`

- [ ] **Step 1: 写模型和服务失败测试**

```dart
test('试卷模型解析奖励是否可撤销', () {
  final paper = ExamPaper.fromJson({
    ..._paperJson(1, '高等数学'),
    'reward_revocable': true,
  });
  expect(paper.rewardRevocable, isTrue);
});

test('删除投稿使用 DELETE 并解析经验撤销结果', () async {
  final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
  RequestOptions? captured;
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    captured = options;
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: {'message': '投稿已永久删除', 'exp_revoked': true},
    ));
  }));

  final result = await ExamPaperService(dio).deleteSubmission(9);
  expect(captured?.method, 'DELETE');
  expect(captured?.path, '/exam-papers/my-submissions/9');
  expect(result.message, '投稿已永久删除');
  expect(result.expRevoked, isTrue);
});
```

- [ ] **Step 2: 运行测试确认 RED**

Run: `cd client && flutter test --no-pub test/exam_paper_model_test.dart test/exam_paper_service_test.dart`

Expected: 编译失败，提示 `rewardRevocable`、`deleteSubmission` 未定义。

- [ ] **Step 3: 实现模型字段与删除结果类型**

在 `ExamPaper` 增加：

```dart
final bool rewardRevocable;
// 构造函数中使用 this.rewardRevocable = false，保持直接构造的旧测试兼容。
rewardRevocable: json['reward_revocable'] == true,
```

在 service 文件增加：

```dart
class ExamPaperDeleteResult {
  final String message;
  final bool expRevoked;

  const ExamPaperDeleteResult({required this.message, required this.expRevoked});

  factory ExamPaperDeleteResult.fromJson(Map<String, dynamic> json) {
    return ExamPaperDeleteResult(
      message: json['message']?.toString() ?? '操作成功',
      expRevoked: json['exp_revoked'] == true,
    );
  }
}
```

用返回结果的方法替换原 `withdraw` 网络实现，并保留兼容 wrapper：

```dart
Future<ExamPaperDeleteResult> deleteSubmission(int id) async {
  try {
    final response = await _dio.delete<Map<String, dynamic>>('/exam-papers/my-submissions/$id');
    return ExamPaperDeleteResult.fromJson(_responseMap(response.data));
  } on DioException catch (error) {
    throw ExamPaperApiException.fromDio(error);
  }
}

Future<void> withdraw(int id) async {
  await deleteSubmission(id);
}
```

- [ ] **Step 4: 运行模型与服务测试确认 GREEN**

Run: `cd client && flutter test --no-pub test/exam_paper_model_test.dart test/exam_paper_service_test.dart`

Expected: PASS。

- [ ] **Step 5: 提交客户端契约增量**

```bash
git add client/lib/models/exam_paper.dart client/lib/services/exam_paper_service.dart client/test/exam_paper_model_test.dart client/test/exam_paper_service_test.dart
git commit -m "feat: 支持试卷删除响应契约"
```

### Task 4: 我的投稿删除交互

**Files:**
- Modify: `client/lib/screens/exam_papers/my_exam_paper_submissions_screen.dart`
- Test: `client/test/screens/my_exam_paper_submissions_screen_test.dart`
- Test: `client/test/screens/exam_paper_responsive_test.dart`

- [ ] **Step 1: 写删除按钮、取消、成功刷新和失败保留测试**

扩展 fake service 记录 `deletedIds` 并可注入错误。测试切换到“已下架”，点击“删除”后断言弹窗包含“永久删除”和按 `rewardRevocable` 决定的“扣回 10 经验”；取消时不调用接口，确认时调用一次并重新请求当前 `unpublished` 状态；错误时卡片仍存在且显示错误消息。

测试文件增加统一构建 helper，避免每个用例重复 Provider：

```dart
Widget _buildScreen(ExamPaperService service) {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: MaterialApp(
      home: MyExamPaperSubmissionsScreen(service: service),
    ),
  );
}
```

```dart
testWidgets('已下架投稿确认删除后刷新当前状态和计数', (tester) async {
  final service = _DeletingExamPaperService();
  await tester.pumpWidget(_buildScreen(service));
  await tester.pumpAndSettle();
  await tester.tap(find.text('已下架 1'));
  await tester.pumpAndSettle();

  await tester.tap(find.text('删除'));
  await tester.pumpAndSettle();
  expect(find.textContaining('永久删除'), findsOneWidget);
  expect(find.textContaining('扣回 10 经验'), findsOneWidget);
  await tester.tap(find.text('确认删除'));
  await tester.pumpAndSettle();

  expect(service.deletedIds, [3]);
  expect(service.requestedStatuses.last, 'unpublished');
});
```

- [ ] **Step 2: 运行 Widget 测试确认 RED**

Run: `cd client && flutter test --no-pub test/screens/my_exam_paper_submissions_screen_test.dart`

Expected: 找不到“删除”按钮。

- [ ] **Step 3: 实现删除状态、确认弹窗和 footer 操作**

新增 `_deleting` 集合并实现：

```dart
final Set<int> _deleting = {};

Future<void> _delete(ExamPaper paper) async {
  if (_deleting.contains(paper.id)) return;
  final rewardText = paper.rewardRevocable ? '\n删除后将扣回该投稿获得的 10 经验。' : '';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('永久删除投稿'),
      content: Text('确认永久删除《${paper.title}》吗？此操作不可恢复。$rewardText'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !mounted) return;
  setState(() => _deleting.add(paper.id));
  try {
    final result = await widget.service.deleteSubmission(paper.id);
    if (!mounted) return;
    _showMessage(result.expRevoked ? '${result.message}，已扣回 10 经验' : result.message);
    await _load(refresh: true);
  } on ExamPaperApiException catch (error) {
    if (mounted) _showMessage(error.message);
  } finally {
    if (mounted) setState(() => _deleting.remove(paper.id));
  }
}
```

published footer 使用 `Expanded` 保持状态文本稳定，并增加 error 色删除按钮；unpublished footer 使用右对齐 `Wrap` 同时容纳删除和重新投稿，避免 320px 溢出。

- [ ] **Step 4: 运行 Widget 与 320px 暗色测试确认 GREEN**

Run: `cd client && flutter test --no-pub test/screens/my_exam_paper_submissions_screen_test.dart test/screens/exam_paper_responsive_test.dart`

Expected: PASS，无 overflow 异常。

- [ ] **Step 5: 提交界面增量**

```bash
git add client/lib/screens/exam_papers/my_exam_paper_submissions_screen.dart client/test/screens/my_exam_paper_submissions_screen_test.dart client/test/screens/exam_paper_responsive_test.dart
git commit -m "feat: 添加我的投稿删除操作"
```

### Task 5: 完整验证、审查与部署

**Files:**
- Verify only; no planned source changes.

- [ ] **Step 1: 运行后端全量测试**

Run: `cd server && go test ./... -count=1`

Expected: 所有 package PASS。

- [ ] **Step 2: 运行 Flutter 全量测试与定向分析**

Run: `cd client && flutter test --no-pub`

Run: `cd client && flutter analyze --no-pub lib/models/exam_paper.dart lib/services/exam_paper_service.dart lib/screens/exam_papers/my_exam_paper_submissions_screen.dart test/exam_paper_model_test.dart test/exam_paper_service_test.dart test/screens/my_exam_paper_submissions_screen_test.dart test/screens/exam_paper_responsive_test.dart`

Expected: 全部测试通过，分析输出 `No issues found!`。

- [ ] **Step 3: 检查差异并请求代码审查**

Run: `git diff --check HEAD`

审查重点：奖励只撤销一次、非本人不可删除、事务失败回滚、文件提交后删除、旧 `withdraw` 调用兼容、320px footer 不溢出。修复所有 Critical/Important 后重新运行 Step 1-2。

- [ ] **Step 4: 构建并部署后端**

将最终提交通过 Git bundle 上传生产服务器，在 detached worktree 中隔离生产 `.env` 后运行 `go test ./... -count=1` 和 `go build -trimpath -o /opt/shenliyuan/shenliyuan.new ./cmd/main.go`。备份当前二进制，原子替换并重启 `shenliyuan`；失败时恢复备份。

- [ ] **Step 5: 线上验收**

确认 `systemctl is-active shenliyuan`、`/health`、`/api/version`、进程重启次数和严重日志。使用有权限的测试路径验证删除及管理员下架不返回 5xx；不得读取或输出生产 `.env` 值。

- [ ] **Step 6: 最终状态核对**

Run: `git status --short --branch`

Expected: 仅保留任务开始前已经存在的两个文档删除，不出现新的未提交实现文件。
