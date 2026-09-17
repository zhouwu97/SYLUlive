package services

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func newGovTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:gov_svc_test_%d?mode=memory&cache=shared", time.Now().UnixNano())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("创建内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.CourseSubject{},
		&models.CourseSubjectAlias{},
		&models.Teacher{},
		&models.TeacherAlias{},
		&models.TeacherRating{},
		&models.TeacherRatingVote{},
		&models.TeacherMergeRecord{},
		&models.CourseEvaluationSubmission{},
		&models.AdminLog{},
	); err != nil {
		t.Fatalf("自动迁移失败: %v", err)
	}
	// 生产启动时 EnsureRatingInteractionSchema 先建立此唯一索引，测试必须包含
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_teacher_rating_user
		ON teacher_ratings (teacher_id, user_id)
		WHERE deleted_at IS NULL;
	`).Error; err != nil {
		t.Fatalf("创建唯一索引失败: %v", err)
	}
	if err := models.EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("EnsureCourseEvaluationSchema 失败: %v", err)
	}
	if err := models.EnsureTeacherGovernanceSchema(db); err != nil {
		t.Fatalf("EnsureTeacherGovernanceSchema 失败: %v", err)
	}
	return db
}

// TestTeacherGovernanceCandidates 覆盖候选分组测试（Section 36）
func TestTeacherGovernanceCandidates(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	s1 := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	s2 := models.CourseSubject{Name: "线性代数", NormalizedName: models.NormalizeCourseSubjectName("线性代数"), Verified: true}
	db.Create(&s1)
	db.Create(&s2)

	// 1. 同学科称谓变体：张三 / 张三老师 -> 高置信 (high)
	db.Create(&models.Teacher{Name: "张三", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("张三"), Verified: true})
	db.Create(&models.Teacher{Name: "张三老师", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("张三老师"), Verified: false})

	// 2. 同学科同姓氏一字之差：李四 / 李四明 -> 疑似 (suspected)
	db.Create(&models.Teacher{Name: "李四", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("李四"), Verified: true})
	db.Create(&models.Teacher{Name: "李思", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("李思"), Verified: false})

	// 3. 跨课程同名：王五 / 王五 -> 仅提示 (hint)，mergeable = false
	db.Create(&models.Teacher{Name: "王五", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("王五"), Verified: true})
	db.Create(&models.Teacher{Name: "王五", Course: "线性代数", CourseSubjectID: &s2.ID, NameNormalized: models.NormalizeTeacherName("王五"), Verified: true})

	groups, err := svc.ListDuplicateGroups()
	if err != nil {
		t.Fatalf("ListDuplicateGroups 失败: %v", err)
	}

	foundVariant := false
	foundSimilar := false
	foundCross := false

	for _, g := range groups {
		switch g.Kind {
		case DuplicateGroupNameVariant:
			foundVariant = true
			if g.Confidence != "high" || !g.Mergeable {
				t.Fatalf("称谓变体应为高置信且可合并，实际: confidence=%s, mergeable=%v", g.Confidence, g.Mergeable)
			}
		case DuplicateGroupSimilarName:
			foundSimilar = true
			if g.Confidence != "suspected" || !g.Mergeable {
				t.Fatalf("相似名称应为疑似提示，实际: confidence=%s, mergeable=%v", g.Confidence, g.Mergeable)
			}
		case DuplicateGroupCrossCourse:
			foundCross = true
			if g.Mergeable {
				t.Fatalf("跨课程同名在默认情况下禁止直接合并")
			}
			if g.Confidence != "hint" {
				t.Fatalf("跨课程同名置信度应为 hint，实际 %s", g.Confidence)
			}
		}
	}

	if !foundVariant {
		t.Fatalf("未检测到称谓变体候选组")
	}
	if !foundSimilar {
		t.Fatalf("未检测到近似名称候选组")
	}
	if !foundCross {
		t.Fatalf("未检测到跨课程同名候选组")
	}
}

// TestTeacherGovernancePreviewAndMerge 覆盖预览与完整合并事务（Section 37 & 38）
func TestTeacherGovernancePreviewAndMerge(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	db.Create(&admin)

	s1 := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	db.Create(&s1)

	keeper := models.Teacher{Name: "张三", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("张三"), Verified: true}
	loser := models.Teacher{Name: "张三老师", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("张三老师"), Verified: false}
	db.Create(&keeper)
	db.Create(&loser)

	// 用户 101 仅评价 keeper；用户 102 同时评价 keeper (旧) 和 loser (新)；用户 103 仅评价 loser
	now := time.Now()
	rKeeper101 := models.TeacherRating{TeacherID: keeper.ID, UserID: 101, Star: 5, Comment: "讲得好", Status: "normal", CreatedAt: now.Add(-2 * time.Hour)}
	rKeeper102 := models.TeacherRating{TeacherID: keeper.ID, UserID: 102, Star: 3, Comment: "一般般", Status: "normal", CreatedAt: now.Add(-time.Hour)}
	rLoser102 := models.TeacherRating{TeacherID: loser.ID, UserID: 102, Star: 5, Comment: "非常有水平", Status: "normal", CreatedAt: now}
	rLoser103 := models.TeacherRating{TeacherID: loser.ID, UserID: 103, Star: 4, Comment: "还行", Status: "normal", CreatedAt: now}
	db.Create(&rKeeper101)
	db.Create(&rKeeper102)
	db.Create(&rLoser102)
	db.Create(&rLoser103)

	// 针对冲突用户 102 的两条评价做投票：投票者 201 同时投票了 keeper 评价与 loser 评价
	v1 := models.TeacherRatingVote{RatingID: rKeeper102.ID, UserID: 201, VoteType: "up", UpdatedAt: now.Add(-time.Minute)}
	v2 := models.TeacherRatingVote{RatingID: rLoser102.ID, UserID: 201, VoteType: "up", UpdatedAt: now}
	// 投票者 202 仅投票了 keeper 评价，胜出者为 rLoser102 时该投票需迁移至 rLoser102
	v3 := models.TeacherRatingVote{RatingID: rKeeper102.ID, UserID: 202, VoteType: "up", UpdatedAt: now}
	db.Create(&v1)
	db.Create(&v2)
	db.Create(&v3)

	// 提交记录：subKeeper 对应 rKeeper102，subLoser 对应 rLoser102
	subKeeper := models.CourseEvaluationSubmission{
		UserID:          102,
		DedupKey:        "102|subKeeper",
		CourseName:      "高等数学A1",
		TeacherName:     "张三",
		TeacherID:       &keeper.ID,
		TeacherRatingID: &rKeeper102.ID,
		Status:          models.CourseEvaluationStatusPublished,
	}
	subLoser := models.CourseEvaluationSubmission{
		UserID:          102,
		DedupKey:        "102|subLoser",
		CourseName:      "高等数学A1",
		TeacherName:     "张三老师",
		TeacherID:       &loser.ID,
		TeacherRatingID: &rLoser102.ID,
		Status:          models.CourseEvaluationStatusPublished,
	}
	db.Create(&subKeeper)
	db.Create(&subLoser)

	// --- 1. PreviewMerge 测试：保证绝对不写库 ---
	input := MergeInput{
		KeeperID: keeper.ID,
		LoserIDs: []uint{loser.ID},
	}
	preview, err := svc.PreviewMerge(input)
	if err != nil {
		t.Fatalf("PreviewMerge 失败: %v", err)
	}

	if preview.SnapshotToken == "" {
		t.Fatalf("Preview 应生成 snapshot_token")
	}
	if preview.RatingConflictsCount != 1 {
		t.Fatalf("应检测到 1 位冲突用户评价，实际 %d", preview.RatingConflictsCount)
	}
	if len(preview.RatingConflicts) != 1 {
		t.Fatalf("应包含 1 条冲突明细")
	}
	if preview.RatingConflicts[0].WinnerRatingID != rLoser102.ID {
		t.Fatalf("根据 created_at 最新原则，胜出评价应为 rLoser102(#%d)，实际 %d",
			rLoser102.ID, preview.RatingConflicts[0].WinnerRatingID)
	}
	if preview.TotalVoteConflictsDeduped != 1 {
		t.Fatalf("应检测到 1 个重复投票去重，实际 %d", preview.TotalVoteConflictsDeduped)
	}
	if preview.TotalVotesMigrated != 1 {
		t.Fatalf("应检测到 1 个未冲突投票迁移，实际 %d", preview.TotalVotesMigrated)
	}

	// 验证 Preview 确实没有修改数据库
	var dbLoser models.Teacher
	db.First(&dbLoser, loser.ID)
	if dbLoser.MergedIntoID != nil {
		t.Fatalf("Preview 绝不能修改数据库状态")
	}

	// --- 2. SnapshotToken 强制与陈旧校验测试 ---
	missingTokenInput := input
	missingTokenInput.SnapshotToken = ""
	_, err = svc.Merge(admin.ID, missingTokenInput)
	if err == nil {
		t.Fatalf("缺少 snapshot_token 应该报错")
	}
	var govErr *TeacherGovernanceError
	if !errors.As(err, &govErr) || govErr.Code != CodeGovernanceSnapshotRequired {
		t.Fatalf("应返回 CodeGovernanceSnapshotRequired，实际 %v", err)
	}

	staleInput := input
	staleInput.SnapshotToken = "stale_token_value_xyz"
	_, err = svc.Merge(admin.ID, staleInput)
	if err == nil {
		t.Fatalf("陈旧 snapshot_token 应该报错")
	}
	if !errors.As(err, &govErr) || govErr.Code != CodeGovernanceSnapshotStale {
		t.Fatalf("应返回 CodeGovernanceSnapshotStale，实际 %v", err)
	}

	// --- 3. 正式 Merge 事务执行 ---
	mergeInput := input
	mergeInput.SnapshotToken = preview.SnapshotToken
	executedPlan, err := svc.Merge(admin.ID, mergeInput)
	if err != nil {
		t.Fatalf("Merge 执行失败: %v", err)
	}
	if executedPlan == nil {
		t.Fatalf("Merge 返回 plan 为空")
	}

	// 验证 loser 标记为 merged
	db.First(&dbLoser, loser.ID)
	if dbLoser.MergedIntoID == nil || *dbLoser.MergedIntoID != keeper.ID {
		t.Fatalf("loser 应被合并至 keeper #%d，实际 %v", keeper.ID, dbLoser.MergedIntoID)
	}

	// 验证评价胜出者与软删除
	var checkRLoser102, checkRKeeper102 models.TeacherRating
	db.Unscoped().First(&checkRLoser102, rLoser102.ID)
	db.Unscoped().First(&checkRKeeper102, rKeeper102.ID)

	if checkRLoser102.TeacherID != keeper.ID {
		t.Fatalf("胜出的 rLoser102 应重挂到 keeper #%d", keeper.ID)
	}
	if !checkRKeeper102.DeletedAt.Valid {
		t.Fatalf("冲突落败的 rKeeper102 应被软删除")
	}

	// 验证投票去重与重新计算计数
	var remainingVotes []models.TeacherRatingVote
	db.Where("rating_id = ?", checkRLoser102.ID).Find(&remainingVotes)
	if len(remainingVotes) != 2 {
		t.Fatalf("胜出评价上的投票在去重后应为 2 条（v2保留，v3重挂，v1删除），实际 %d", len(remainingVotes))
	}
	if checkRLoser102.HelpfulCount != 2 {
		t.Fatalf("胜出评价的 helpful_count 应被重算为 2，实际 %d", checkRLoser102.HelpfulCount)
	}

	// 验证提交记录冲突：落败评价关联的 subKeeper 状态应为 superseded
	var checkSubKeeper, checkSubLoser models.CourseEvaluationSubmission
	db.First(&checkSubKeeper, subKeeper.ID)
	db.First(&checkSubLoser, subLoser.ID)

	if checkSubKeeper.Status != models.CourseEvaluationStatusSuperseded {
		t.Fatalf("重复提交 subKeeper 状态应为 superseded，实际 %s", checkSubKeeper.Status)
	}
	if checkSubKeeper.TeacherRatingID != nil {
		t.Fatalf("superseded 提交的 teacher_rating_id 应为 NULL")
	}
	if checkSubKeeper.SupersededBySubmissionID == nil || *checkSubKeeper.SupersededBySubmissionID != checkSubLoser.ID {
		t.Fatalf("superseded 提交应指向 winner 提交 subLoser(#%d)，实际 %v", checkSubLoser.ID, checkSubKeeper.SupersededBySubmissionID)
	}

	// 验证教师别名已登记
	var alias models.TeacherAlias
	err = db.Where("course_subject_id = ? AND normalized_alias = ?", s1.ID, models.NormalizeTeacherName("张三老师")).First(&alias).Error
	if err != nil {
		t.Fatalf("应成功为 keeper 登记张三老师别名: %v", err)
	}
	if alias.TeacherID != keeper.ID {
		t.Fatalf("别名应指向 keeper #%d", keeper.ID)
	}

	// 验证 TeacherMergeRecord 审计记录完整生成
	var records []models.TeacherMergeRecord
	db.Where("loser_id = ?", loser.ID).Find(&records)
	if len(records) != 1 {
		t.Fatalf("应为 loser #%d 生成 1 条合并审计记录", loser.ID)
	}
	rec := records[0]
	if rec.KeeperID != keeper.ID || rec.KeeperNameSnapshot != keeper.Name || rec.LoserNameSnapshot != loser.Name {
		t.Fatalf("审计记录快照信息不符: %+v", rec)
	}

	// --- 4. 幂等性测试：再次对同一个 keeper 执行合并应幂等成功 ---
	pPrev, err := svc.PreviewMerge(MergeInput{
		KeeperID: keeper.ID,
		LoserIDs: []uint{loser.ID},
	})
	if err != nil {
		t.Fatalf("幂等 preview 失败: %v", err)
	}
	idempotentPlan, err := svc.Merge(admin.ID, MergeInput{
		KeeperID:      keeper.ID,
		LoserIDs:      []uint{loser.ID},
		SnapshotToken: pPrev.SnapshotToken,
	})
	if err != nil {
		t.Fatalf("对已合并至相同 keeper 的教师再次合并应幂等成功，但报错: %v", err)
	}
	if len(idempotentPlan.IdempotentLosers) != 1 || idempotentPlan.IdempotentLosers[0] != loser.ID {
		t.Fatalf("应将已合并的 loser 列入 idempotent_losers")
	}

	// --- 5. 跨教师冲突：试图将已合并的 loser 合并到第三位教师，Preview 与 Merge 均应报 409 TEACHER_ALREADY_MERGED ---
	thirdTeacher := models.Teacher{Name: "赵六", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("赵六"), Verified: true}
	db.Create(&thirdTeacher)
	_, err = svc.PreviewMerge(MergeInput{
		KeeperID: thirdTeacher.ID,
		LoserIDs: []uint{loser.ID},
	})
	if err == nil {
		t.Fatalf("对已合并到其他目标的 loser 执行 preview 应当报错")
	}
	if !errors.As(err, &govErr) || govErr.Code != CodeTeacherAlreadyMerged {
		t.Fatalf("Preview 应返回 CodeTeacherAlreadyMerged，实际 %v", err)
	}

	_, err = svc.Merge(admin.ID, MergeInput{
		KeeperID:      thirdTeacher.ID,
		LoserIDs:      []uint{loser.ID},
		SnapshotToken: "prior_snapshot_token",
	})
	if err == nil {
		t.Fatalf("将已合并教师合并到其他目标应报错")
	}
	if !errors.As(err, &govErr) || govErr.Code != CodeTeacherAlreadyMerged {
		t.Fatalf("Merge 应返回 CodeTeacherAlreadyMerged，实际 %v", err)
	}
}

// TestTeacherAliasConflictValidation 覆盖别名冲突检测（Section 9）
func TestTeacherAliasConflictValidation(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "管理员", Role: "admin"}
	db.Create(&admin)

	s1 := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	db.Create(&s1)

	t1 := models.Teacher{Name: "张三", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("张三"), Verified: true}
	t2 := models.Teacher{Name: "李四", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("李四"), Verified: true}
	db.Create(&t1)
	db.Create(&t2)

	// 1. 为 t1 成功添加别名“三哥”
	view, err := svc.AddAlias(admin.ID, AddAliasInput{
		Type:            "teacher",
		CourseSubjectID: s1.ID,
		TeacherID:       t1.ID,
		Alias:           "三哥",
	})
	if err != nil {
		t.Fatalf("添加别名失败: %v", err)
	}
	if view.TargetID != t1.ID {
		t.Fatalf("别名目标应为 t1")
	}

	// 2. 幂等添加相同 target 的别名：成功返回
	_, err = svc.AddAlias(admin.ID, AddAliasInput{
		Type:            "teacher",
		CourseSubjectID: s1.ID,
		TeacherID:       t1.ID,
		Alias:           "三哥",
	})
	if err != nil {
		t.Fatalf("幂等添加已有别名应成功，但报错: %v", err)
	}

	// 3. 目标冲突：试图把“三哥”指向 t2 必须报 ALIAS_TARGET_CONFLICT (409)
	_, err = svc.AddAlias(admin.ID, AddAliasInput{
		Type:            "teacher",
		CourseSubjectID: s1.ID,
		TeacherID:       t2.ID,
		Alias:           "三哥",
	})
	if err == nil {
		t.Fatalf("指向不同目标的别名添加应失败")
	}
	var govErr *TeacherGovernanceError
	if !errors.As(err, &govErr) || govErr.Code != CodeAliasTargetConflict {
		t.Fatalf("应返回 CodeAliasTargetConflict，实际 %v", err)
	}

	// 4. 真实 canonical 名冲突：试图把“李四”作为 t1 的别名，必须拒绝
	_, err = svc.AddAlias(admin.ID, AddAliasInput{
		Type:            "teacher",
		CourseSubjectID: s1.ID,
		TeacherID:       t1.ID,
		Alias:           "李四",
	})
	if err == nil {
		t.Fatalf("与活动教师实名冲突的别名添加应被拒绝")
	}
	if !errors.As(err, &govErr) || govErr.Code != CodeCanonicalNameConflict {
		t.Fatalf("应返回 CodeCanonicalNameConflict，实际 %v", err)
	}
}

// TestPendingTeacherMergeInto 覆盖待审教师快速并入测试（Section 21.1）
func TestPendingTeacherMergeInto(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "管理员", Role: "admin"}
	db.Create(&admin)

	s1 := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	db.Create(&s1)

	keeper := models.Teacher{Name: "张三", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("张三"), Verified: true}
	db.Create(&keeper)

	// 1. 无评分的待审教师可快速并入
	pendingNoRating := models.Teacher{Name: "小张", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("小张"), Verified: false}
	db.Create(&pendingNoRating)

	keeperName, err := svc.MergePendingTeacherInto(admin.ID, pendingNoRating.ID, keeper.ID, true)
	if err != nil {
		t.Fatalf("待审教师快速并入失败: %v", err)
	}
	if keeperName != keeper.Name {
		t.Fatalf("返回 keeper 名称不符: %s", keeperName)
	}

	var checkPending models.Teacher
	db.First(&checkPending, pendingNoRating.ID)
	if checkPending.MergedIntoID == nil || *checkPending.MergedIntoID != keeper.ID {
		t.Fatalf("待审教师应被标记为 merged_into_id = %d", keeper.ID)
	}

	// 2. 有评分的待审教师必须拒绝并返回 409 USE_GOVERNANCE_MERGE
	pendingWithRating := models.Teacher{Name: "老张", Course: "高等数学A1", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("老张"), Verified: false}
	db.Create(&pendingWithRating)
	db.Create(&models.TeacherRating{TeacherID: pendingWithRating.ID, UserID: 88, Star: 5, Comment: "非常好"})

	_, err = svc.MergePendingTeacherInto(admin.ID, pendingWithRating.ID, keeper.ID, true)
	if err == nil {
		t.Fatalf("存在评价的待审教师应被拒绝快速并入")
	}
	var govErr *TeacherGovernanceError
	if !errors.As(err, &govErr) || govErr.Code != CodeUseGovernanceMerge {
		t.Fatalf("应返回 CodeUseGovernanceMerge，实际 %v", err)
	}
}

// TestTeacherGovernanceMergeWithUniqueIndex 验证 loser-wins 评价冲突在生产唯一索引下不会违约
func TestTeacherGovernanceMergeWithUniqueIndex(t *testing.T) {
	db := newGovTestDB(t) // 已包含 uq_teacher_rating_user 唯一索引
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "管理员", Role: "admin"}
	db.Create(&admin)

	s1 := models.CourseSubject{Name: "线性代数", NormalizedName: models.NormalizeCourseSubjectName("线性代数"), Verified: true}
	db.Create(&s1)

	keeper := models.Teacher{Name: "陈老师", Course: "线性代数", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("陈老师"), Verified: true}
	loser := models.Teacher{Name: "陈教授", Course: "线性代数", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("陈教授"), Verified: false}
	db.Create(&keeper)
	db.Create(&loser)

	now := time.Now()
	// 用户 301: keeper 上有旧评价, loser 上有新评价 → loser 评价胜出
	rKeeperOld := models.TeacherRating{TeacherID: keeper.ID, UserID: 301, Star: 2, Comment: "旧的keeper评价", Status: "normal", CreatedAt: now.Add(-2 * time.Hour)}
	rLoserNew := models.TeacherRating{TeacherID: loser.ID, UserID: 301, Star: 5, Comment: "新的loser评价", Status: "normal", CreatedAt: now}
	db.Create(&rKeeperOld)
	db.Create(&rLoserNew)

	// 关键：此时执行合并时，如果先 UPDATE loser.teacher_id = keeper 再 soft-delete keeper rating，
	// 会暂时存在两条活动的 (keeper.ID, 301)，违反唯一索引。正确顺序是先软删 keeper rating 再 repoint loser。
	preview, err := svc.PreviewMerge(MergeInput{
		KeeperID: keeper.ID,
		LoserIDs: []uint{loser.ID},
	})
	if err != nil {
		t.Fatalf("PreviewMerge 失败: %v", err)
	}
	if preview.RatingConflictsCount != 1 {
		t.Fatalf("应检测到 1 位冲突用户评价，实际 %d", preview.RatingConflictsCount)
	}

	// 执行合并 - 这是关键测试点：如果更新顺序错误将直接因唯一索引报错
	_, err = svc.Merge(admin.ID, MergeInput{
		KeeperID:      keeper.ID,
		LoserIDs:      []uint{loser.ID},
		SnapshotToken: preview.SnapshotToken,
	})
	if err != nil {
		t.Fatalf("Merge 在唯一索引下执行失败（P0 回归）: %v", err)
	}

	// 验证结果：keeper 旧评价已软删，loser 新评价已 repoint 到 keeper
	var checkKeeperRating, checkLoserRating models.TeacherRating
	db.Unscoped().First(&checkKeeperRating, rKeeperOld.ID)
	db.Unscoped().First(&checkLoserRating, rLoserNew.ID)

	if !checkKeeperRating.DeletedAt.Valid {
		t.Fatalf("keeper 旧评价应被软删除")
	}
	if checkLoserRating.TeacherID != keeper.ID {
		t.Fatalf("loser 新评价应 repoint 到 keeper(#%d)，实际 %d", keeper.ID, checkLoserRating.TeacherID)
	}
	if checkLoserRating.DeletedAt.Valid {
		t.Fatalf("loser 新评价（胜出方）不应被软删除")
	}
}

// TestPendingTeacherMergeSubmissions 验证 MergePendingTeacherInto 重挂提交记录和跨学科拒绝
func TestPendingTeacherMergeSubmissions(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "管理员", Role: "admin"}
	db.Create(&admin)

	s1 := models.CourseSubject{Name: "概率论", NormalizedName: models.NormalizeCourseSubjectName("概率论"), Verified: true}
	s2 := models.CourseSubject{Name: "数理统计", NormalizedName: models.NormalizeCourseSubjectName("数理统计"), Verified: true}
	db.Create(&s1)
	db.Create(&s2)

	keeper := models.Teacher{Name: "刘老师", Course: "概率论", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("刘老师"), Verified: true}
	db.Create(&keeper)

	// 1. 同学科 pending，带有提交记录 → 应成功重挂
	pendingSameSubject := models.Teacher{Name: "刘老", Course: "概率论", CourseSubjectID: &s1.ID, NameNormalized: models.NormalizeTeacherName("刘老"), Verified: false}
	db.Create(&pendingSameSubject)

	sub1 := models.CourseEvaluationSubmission{
		UserID:      501,
		DedupKey:    "501|sub_pending1",
		CourseName:  "概率论",
		TeacherName: "刘老",
		TeacherID:   &pendingSameSubject.ID,
		Status:      models.CourseEvaluationStatusPending,
	}
	sub2 := models.CourseEvaluationSubmission{
		UserID:      502,
		DedupKey:    "502|sub_pending2",
		CourseName:  "概率论",
		TeacherName: "刘老",
		TeacherID:   &pendingSameSubject.ID,
		Status:      models.CourseEvaluationStatusPending,
	}
	db.Create(&sub1)
	db.Create(&sub2)

	keeperName, err := svc.MergePendingTeacherInto(admin.ID, pendingSameSubject.ID, keeper.ID, true)
	if err != nil {
		t.Fatalf("同学科待审教师快速并入失败: %v", err)
	}
	if keeperName != keeper.Name {
		t.Fatalf("返回 keeper 名称不符: 期望 %q, 得到 %q", keeper.Name, keeperName)
	}

	// 验证提交记录已重挂
	var checkSub1, checkSub2 models.CourseEvaluationSubmission
	db.First(&checkSub1, sub1.ID)
	db.First(&checkSub2, sub2.ID)
	if checkSub1.TeacherID == nil || *checkSub1.TeacherID != keeper.ID {
		t.Fatalf("提交1应重挂到 keeper(#%d)，实际 %v", keeper.ID, checkSub1.TeacherID)
	}
	if checkSub1.TeacherName != keeper.Name {
		t.Fatalf("提交1教师名应更新为 %q，实际 %q", keeper.Name, checkSub1.TeacherName)
	}
	if checkSub2.TeacherID == nil || *checkSub2.TeacherID != keeper.ID {
		t.Fatalf("提交2应重挂到 keeper(#%d)，实际 %v", keeper.ID, checkSub2.TeacherID)
	}

	// 2. 跨学科 pending → 应拒绝
	pendingCrossSubject := models.Teacher{Name: "刘教授", Course: "数理统计", CourseSubjectID: &s2.ID, NameNormalized: models.NormalizeTeacherName("刘教授"), Verified: false}
	db.Create(&pendingCrossSubject)

	_, err = svc.MergePendingTeacherInto(admin.ID, pendingCrossSubject.ID, keeper.ID, true)
	if err == nil {
		t.Fatalf("跨学科待审教师快速并入应被拒绝")
	}
	var govErr *TeacherGovernanceError
	if !errors.As(err, &govErr) || govErr.Code != CodeCrossSubjectMergeRequiresSubjectDecision {
		t.Fatalf("应返回 CodeCrossSubjectMergeRequiresSubjectDecision，实际 %v", err)
	}
}

// TestCourseMergeWorkflow 测试完整课程合并：保留不同教师，仅合并指定配对教师，软合并课程，登记别名
func TestCourseMergeWorkflow(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	db.Create(&admin)

	// 准备课程：高数（上） (loser) 与 高等数学A1 (keeper)
	sLoser := models.CourseSubject{Name: "高数（上）", NormalizedName: models.NormalizeCourseSubjectName("高数（上）"), Verified: true}
	sKeeper := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	db.Create(&sLoser)
	db.Create(&sKeeper)

	// 高数（上）下有：张老师 (t1)、李四 (t2)
	t1 := models.Teacher{Name: "张老师", Course: "高数（上）", CourseSubjectID: &sLoser.ID, NameNormalized: models.NormalizeTeacherName("张老师"), Verified: true}
	t2 := models.Teacher{Name: "李四", Course: "高数（上）", CourseSubjectID: &sLoser.ID, NameNormalized: models.NormalizeTeacherName("李四"), Verified: true}
	// 高等数学A1下有：张三 (t3)、王五 (t4)
	t3 := models.Teacher{Name: "张三", Course: "高等数学A1", CourseSubjectID: &sKeeper.ID, NameNormalized: models.NormalizeTeacherName("张三"), Verified: true}
	t4 := models.Teacher{Name: "王五", Course: "高等数学A1", CourseSubjectID: &sKeeper.ID, NameNormalized: models.NormalizeTeacherName("王五"), Verified: true}
	db.Create(&t1)
	db.Create(&t2)
	db.Create(&t3)
	db.Create(&t4)

	// 评价：
	// 用户 101 在 t1 有评星 3分（较早），在 t3 有评星 5分（较新） -> 冲突去重
	// 用户 102 在 t1 有评星 4分 -> 迁移至 t3
	// 用户 103 在 t2 (李四) 有评星 5分 -> 留在李四，不合并至张三
	// 用户 105 在 t4 (王五) 有评星 4分 -> 留在王五
	tEarly := time.Now().Add(-2 * time.Hour)
	tLate := time.Now().Add(-1 * time.Hour)
	r1_101 := models.TeacherRating{TeacherID: t1.ID, UserID: 101, Star: 3, Comment: "一般般", CreatedAt: tEarly, UpdatedAt: tEarly}
	r1_102 := models.TeacherRating{TeacherID: t1.ID, UserID: 102, Star: 4, Comment: "讲得不错", CreatedAt: tEarly, UpdatedAt: tEarly}
	r2_103 := models.TeacherRating{TeacherID: t2.ID, UserID: 103, Star: 5, Comment: "李老师好", CreatedAt: tEarly, UpdatedAt: tEarly}
	r3_101 := models.TeacherRating{TeacherID: t3.ID, UserID: 101, Star: 5, Comment: "张老师很棒", CreatedAt: tLate, UpdatedAt: tLate}
	r4_105 := models.TeacherRating{TeacherID: t4.ID, UserID: 105, Star: 4, Comment: "王老师很好", CreatedAt: tEarly, UpdatedAt: tEarly}
	db.Create(&r1_101)
	db.Create(&r1_102)
	db.Create(&r2_103)
	db.Create(&r3_101)
	db.Create(&r4_105)

	// 1. 预览课程合并
	previewInput := CourseMergeInput{
		KeeperSubjectID: sKeeper.ID,
		LoserSubjectIDs: []uint{sLoser.ID},
		FinalCourseName: "高等数学A1",
		TeacherPairs: []CourseMergeTeacherPair{
			{
				LoserTeacherID:   t1.ID,
				KeeperTeacherID:  t3.ID,
				FinalTeacherName: "张三",
			},
		},
		Reason: "统一高等数学课程规范名称",
	}

	preview, err := svc.PreviewCourseMerge(previewInput)
	if err != nil {
		t.Fatalf("PreviewCourseMerge 失败: %v", err)
	}
	if !preview.MergeAllowed {
		t.Fatalf("课程合并预览应允许合并，实际被阻断: %s, 冲突: %v", preview.BlockReason, preview.Conflicts)
	}
	if len(preview.PairedTeacherMerges) != 1 {
		t.Fatalf("配对教师数量应为 1，实际 %d", len(preview.PairedTeacherMerges))
	}
	if len(preview.MigratingTeachers) != 1 {
		t.Fatalf("未配对迁移教师数量应为 1 (李四)，实际 %d", len(preview.MigratingTeachers))
	}
	if preview.MigratingTeachers[0].TeacherID != t2.ID {
		t.Fatalf("迁移教师应为李四(#%d)，实际 #%d", t2.ID, preview.MigratingTeachers[0].TeacherID)
	}
	if preview.TotalRatingsDeduped != 1 {
		t.Fatalf("去重评价数应为 1，实际 %d", preview.TotalRatingsDeduped)
	}

	// 2. 执行课程合并
	mergeInput := previewInput
	mergeInput.SnapshotToken = preview.SnapshotToken

	execResult, err := svc.CourseMerge(admin.ID, mergeInput)
	if err != nil {
		t.Fatalf("CourseMerge 失败: %v", err)
	}
	if !execResult.MergeAllowed {
		t.Fatalf("合并执行结果异常")
	}

	// 3. 验证课程实体与别名状态
	var checkLoserSubject, checkKeeperSubject models.CourseSubject
	db.First(&checkLoserSubject, sLoser.ID)
	db.First(&checkKeeperSubject, sKeeper.ID)

	if checkLoserSubject.MergedIntoID == nil || *checkLoserSubject.MergedIntoID != sKeeper.ID {
		t.Fatalf("原课程 MergedIntoID 应指向 keeper(#%d)，实际 %v", sKeeper.ID, checkLoserSubject.MergedIntoID)
	}
	var courseAlias models.CourseSubjectAlias
	if err := db.Where("course_subject_id = ? AND alias = ?", sKeeper.ID, "高数（上）").First(&courseAlias).Error; err != nil {
		t.Fatalf("未成功登记原课程名别名: %v", err)
	}

	// 4. 验证教师状态：
	// - t1 (张老师) 已并入 t3 (张三)
	// - t2 (李四) 迁移至 sKeeper，但保持未合并状态！仍叫李四！
	// - t4 (王五) 保持未合并状态！仍叫王五！
	var checkT1, checkT2, checkT3, checkT4 models.Teacher
	db.First(&checkT1, t1.ID)
	db.First(&checkT2, t2.ID)
	db.First(&checkT3, t3.ID)
	db.First(&checkT4, t4.ID)

	if checkT1.MergedIntoID == nil || *checkT1.MergedIntoID != t3.ID {
		t.Fatalf("张老师(#%d) 应并入 张三(#%d)，实际 MergedIntoID=%v", t1.ID, t3.ID, checkT1.MergedIntoID)
	}
	if checkT2.MergedIntoID != nil {
		t.Fatalf("李四(#%d) 不应被合并！其实体应保持独立，实际 MergedIntoID=%v", t2.ID, checkT2.MergedIntoID)
	}
	if checkT2.CourseSubjectID == nil || *checkT2.CourseSubjectID != sKeeper.ID {
		t.Fatalf("李四(#%d) 的 course_subject_id 应更新为目标课程(#%d)，实际 %v", t2.ID, sKeeper.ID, checkT2.CourseSubjectID)
	}
	if checkT2.Course != "高等数学A1" {
		t.Fatalf("李四(#%d) 的 course 字符串应更新为「高等数学A1」，实际 %q", t2.ID, checkT2.Course)
	}
	if checkT2.Name != "李四" {
		t.Fatalf("李四的姓名应保留为李四，实际 %q", checkT2.Name)
	}

	if checkT4.MergedIntoID != nil {
		t.Fatalf("王五(#%d) 不应被合并，实际 MergedIntoID=%v", t4.ID, checkT4.MergedIntoID)
	}

	// 5. 验证李四的评价没有被合并到张三名下
	var t2Ratings []models.TeacherRating
	db.Where("teacher_id = ? AND deleted_at IS NULL", t2.ID).Find(&t2Ratings)
	if len(t2Ratings) != 1 || t2Ratings[0].UserID != 103 {
		t.Fatalf("李四名下评价应保持完整 (1条，用户103)，实际数量 %d", len(t2Ratings))
	}

	// 6. 验证张三名下评价：101（保留最新的5分），102（4分）
	var t3Ratings []models.TeacherRating
	db.Where("teacher_id = ? AND deleted_at IS NULL", t3.ID).Find(&t3Ratings)
	if len(t3Ratings) != 2 {
		t.Fatalf("张三名下有效评价数应为 2，实际 %d", len(t3Ratings))
	}

	// 7. 幂等性测试：再次提交相同合并请求，应安全通过不报错
	_, err = svc.CourseMerge(admin.ID, mergeInput)
	if err != nil {
		t.Fatalf("重复执行课程合并应幂等成功，实际报错: %v", err)
	}
}

// TestCourseAliasSelfConflictResolution 验证第二处问题：课程合并过程中，原课程登记为别名时不再被自身阻断
func TestCourseAliasSelfConflictResolution(t *testing.T) {
	db := newGovTestDB(t)

	s1 := models.CourseSubject{Name: "高等数学(一)", NormalizedName: models.NormalizeCourseSubjectName("高等数学(一)"), Verified: true}
	s2 := models.CourseSubject{Name: "高等数学A1", NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"), Verified: true}
	db.Create(&s1)
	db.Create(&s2)

	// 直接调用 planCourseAliasExcluding，排除 s1.ID，验证不会报告冲突
	aliasItem, conflictMsg, err := planCourseAliasExcluding(db, s1.Name, s2.ID, s2.Name, []uint{s1.ID})
	if err != nil {
		t.Fatalf("planCourseAliasExcluding 报错: %v", err)
	}
	if conflictMsg != "" {
		t.Fatalf("排除源课程后不应报告名称自冲突，实际消息: %s", conflictMsg)
	}
	if aliasItem.Status != "to_create" {
		t.Fatalf("别名状态应为 to_create，实际 %s", aliasItem.Status)
	}
}

// TestCourseMergeReconcileAliasesAndValidateSchema 验证第1项问题：
// 合并已有别名的课程后，历史别名与原课程名正确迁移，且下次启动通过 ValidateTeacherGovernanceSchema 校验
func TestCourseMergeReconcileAliasesAndValidateSchema(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	db.Create(&admin)

	sKeeper := models.CourseSubject{
		Name:           "高等数学A1",
		NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"),
		Verified:       true,
	}
	sLoser := models.CourseSubject{
		Name:           "高数（上）",
		NormalizedName: models.NormalizeCourseSubjectName("高数（上）"),
		Verified:       true,
	}
	db.Create(&sKeeper)
	db.Create(&sLoser)

	// 源课程已有别名 "高数上"
	existingAlias := models.CourseSubjectAlias{
		CourseSubjectID: sLoser.ID,
		Alias:           "高数上",
		NormalizedAlias: models.NormalizeCourseSubjectName("高数上"),
	}
	if err := db.Create(&existingAlias).Error; err != nil {
		t.Fatalf("创建源课程别名失败: %v", err)
	}

	tKeeper := models.Teacher{
		Name:            "张三",
		Course:          "高等数学A1",
		CourseSubjectID: &sKeeper.ID,
		NameNormalized:  models.NormalizeTeacherName("张三"),
		Verified:        true,
	}
	tLoser := models.Teacher{
		Name:            "张老师",
		Course:          "高数（上）",
		CourseSubjectID: &sLoser.ID,
		NameNormalized:  models.NormalizeTeacherName("张老师"),
		Verified:        true,
	}
	db.Create(&tKeeper)
	db.Create(&tLoser)

	previewInput := CourseMergeInput{
		KeeperSubjectID: sKeeper.ID,
		LoserSubjectIDs: []uint{sLoser.ID},
		FinalCourseName: "高等数学A1",
		TeacherPairs: []CourseMergeTeacherPair{
			{KeeperTeacherID: tKeeper.ID, LoserTeacherID: tLoser.ID, FinalTeacherName: "张三"},
		},
		Reason: "测试别名重挂",
	}

	preview, err := svc.PreviewCourseMerge(previewInput)
	if err != nil {
		t.Fatalf("PreviewCourseMerge 失败: %v", err)
	}

	mergeInput := previewInput
	mergeInput.SnapshotToken = preview.SnapshotToken
	_, err = svc.CourseMerge(admin.ID, mergeInput)
	if err != nil {
		t.Fatalf("CourseMerge 执行失败: %v", err)
	}

	// 验证1: sLoser 的 MergedIntoID 指向 sKeeper
	var checkLoser models.CourseSubject
	db.First(&checkLoser, sLoser.ID)
	if checkLoser.MergedIntoID == nil || *checkLoser.MergedIntoID != sKeeper.ID {
		t.Fatalf("源课程 MergedIntoID 应指向 keeper, 实际: %v", checkLoser.MergedIntoID)
	}

	// 验证2: 历史别名 "高数上" 重定向到 sKeeper
	var reloadedAlias models.CourseSubjectAlias
	if err := db.First(&reloadedAlias, existingAlias.ID).Error; err != nil {
		t.Fatalf("读取历史别名失败: %v", err)
	}
	if reloadedAlias.CourseSubjectID != sKeeper.ID {
		t.Fatalf("历史别名未重定向到 keeper, 实际 course_subject_id: %d", reloadedAlias.CourseSubjectID)
	}

	// 验证3: 原课程名 "高数（上）" 登记为 sKeeper 的别名
	var origNameAlias models.CourseSubjectAlias
	if err := db.Where("course_subject_id = ? AND alias = ?", sKeeper.ID, "高数（上）").First(&origNameAlias).Error; err != nil {
		t.Fatalf("原课程名别名未正确登记: %v", err)
	}

	// 验证4: 核心验收项——合并后下次启动校验 ValidateTeacherGovernanceSchema 必须通过！
	if err := models.ValidateTeacherGovernanceSchema(db); err != nil {
		t.Fatalf("合并后启动数据完整性校验失败: %v", err)
	}

	// 验证5: 启动时 dedupeCourseSubjects 不应物理删除软合并的课程
	if err := models.EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("合并后再次执行 EnsureCourseEvaluationSchema 失败: %v", err)
	}
	var countAfter int64
	db.Model(&models.CourseSubject{}).Where("id = ?", sLoser.ID).Count(&countAfter)
	if countAfter != 1 {
		t.Fatalf("软合并课程不应被物理删除, 期望保留1条记录, 实际 count: %d", countAfter)
	}
}

// TestTeacherAndCourseMergeAdoptLoserName 验证第3项问题：
// 采用另一条被合并实体的名称时，在生产 partial unique index 下正常执行改名并正确登记历史别名
func TestTeacherAndCourseMergeAdoptLoserName(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	db.Create(&admin)

	s1 := models.CourseSubject{
		Name:           "大学物理A",
		NormalizedName: models.NormalizeCourseSubjectName("大学物理A"),
		Verified:       true,
	}
	db.Create(&s1)

	// 场景 A: 教师合并中 Keeper (#1 张老师) 合并 Loser (#2 张三)，最终采用 Loser 姓名 "张三"
	tKeeper := models.Teacher{
		Name:            "张老师",
		Course:          "大学物理A",
		CourseSubjectID: &s1.ID,
		NameNormalized:  models.NormalizeTeacherName("张老师"),
		Verified:        true,
	}
	tLoser := models.Teacher{
		Name:            "张三",
		Course:          "大学物理A",
		CourseSubjectID: &s1.ID,
		NameNormalized:  models.NormalizeTeacherName("张三"),
		Verified:        true,
	}
	db.Create(&tKeeper)
	db.Create(&tLoser)

	previewTeacher, err := svc.PreviewMerge(MergeInput{
		KeeperID:         tKeeper.ID,
		LoserIDs:         []uint{tLoser.ID},
		FinalTeacherName: "张三",
	})
	if err != nil {
		t.Fatalf("PreviewMerge 失败: %v", err)
	}

	// 在存在生产索引 uq_teachers_active_subject_name 下执行改名为 loser 姓名
	_, err = svc.Merge(admin.ID, MergeInput{
		KeeperID:         tKeeper.ID,
		LoserIDs:         []uint{tLoser.ID},
		FinalTeacherName: "张三",
		SnapshotToken:    previewTeacher.SnapshotToken,
		Reason:           "采用被合并者姓名",
	})
	if err != nil {
		t.Fatalf("教师合并最终采用被合并者姓名失败: %v", err)
	}

	var checkTKeeper models.Teacher
	db.First(&checkTKeeper, tKeeper.ID)
	if checkTKeeper.Name != "张三" {
		t.Fatalf("Keeper 姓名应更新为「张三」, 实际: %q", checkTKeeper.Name)
	}

	// 验证 Keeper 自己的原名 "张老师" 是否登记为别名
	var keeperOldAlias models.TeacherAlias
	if err := db.Where("teacher_id = ? AND alias = ?", tKeeper.ID, "张老师").First(&keeperOldAlias).Error; err != nil {
		t.Fatalf("Keeper 自身原名未登记为别名: %v", err)
	}

	// 场景 B: 课程合并中 Keeper (高等数学A1) 合并 Loser (高数（上）)，最终采用 Loser 课程名 "高数（上）"
	sKeeper := models.CourseSubject{
		Name:           "高等数学A1",
		NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"),
		Verified:       true,
	}
	sLoser := models.CourseSubject{
		Name:           "高数（上）",
		NormalizedName: models.NormalizeCourseSubjectName("高数（上）"),
		Verified:       true,
	}
	db.Create(&sKeeper)
	db.Create(&sLoser)

	coursePreviewInput := CourseMergeInput{
		KeeperSubjectID: sKeeper.ID,
		LoserSubjectIDs: []uint{sLoser.ID},
		FinalCourseName: "高数（上）",
		Reason:          "采用源课程名",
	}

	previewCourse, err := svc.PreviewCourseMerge(coursePreviewInput)
	if err != nil {
		t.Fatalf("PreviewCourseMerge 失败: %v", err)
	}

	courseMergeInput := coursePreviewInput
	courseMergeInput.SnapshotToken = previewCourse.SnapshotToken
	_, err = svc.CourseMerge(admin.ID, courseMergeInput)
	if err != nil {
		t.Fatalf("课程合并最终采用被合并课程原名失败: %v", err)
	}

	var checkSKeeper models.CourseSubject
	db.First(&checkSKeeper, sKeeper.ID)
	if checkSKeeper.Name != "高数（上）" {
		t.Fatalf("Keeper 课程名应更新为「高数（上）」, 实际: %q", checkSKeeper.Name)
	}

	// 验证 Keeper 原课程名 "高等数学A1" 登记为别名
	var keeperCourseOldAlias models.CourseSubjectAlias
	if err := db.Where("course_subject_id = ? AND alias = ?", sKeeper.ID, "高等数学A1").First(&keeperCourseOldAlias).Error; err != nil {
		t.Fatalf("Keeper 原课程名未登记为别名: %v", err)
	}

	// 验证启动校验正常通过
	if err := models.ValidateTeacherGovernanceSchema(db); err != nil {
		t.Fatalf("采用源名称合并后启动完整性校验失败: %v", err)
	}
}

// TestCourseMergeSubmissionDedupKeyAndRepeatRating 验证第4项问题：
// 评价迁移后维护 DedupKey，用户再次对合并后的教师评分不会失败
func TestCourseMergeSubmissionDedupKeyAndRepeatRating(t *testing.T) {
	db := newGovTestDB(t)
	govSvc := NewTeacherGovernanceService(db)
	evalSvc := NewCourseEvaluationService(db)

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	user := models.User{Nickname: "普通学生", Role: "user"}
	db.Create(&admin)
	db.Create(&user)

	sKeeper := models.CourseSubject{
		Name:           "高等数学A1",
		NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"),
		Verified:       true,
	}
	sLoser := models.CourseSubject{
		Name:           "高数（上）",
		NormalizedName: models.NormalizeCourseSubjectName("高数（上）"),
		Verified:       true,
	}
	db.Create(&sKeeper)
	db.Create(&sLoser)

	tKeeper := models.Teacher{
		Name:            "李四",
		Course:          "高等数学A1",
		CourseSubjectID: &sKeeper.ID,
		NameNormalized:  models.NormalizeTeacherName("李四"),
		Verified:        true,
	}
	tLoser := models.Teacher{
		Name:            "李老师",
		Course:          "高数（上）",
		CourseSubjectID: &sLoser.ID,
		NameNormalized:  models.NormalizeTeacherName("李老师"),
		Verified:        true,
	}
	db.Create(&tKeeper)
	db.Create(&tLoser)

	// 用户在旧课程旧教师下提交了评价并通过生成评分
	initialSub, err := evalSvc.Submit(user.ID, CreateCourseEvaluationInput{
		CourseName:      sLoser.Name,
		CourseSubjectID: &sLoser.ID,
		TeacherName:     tLoser.Name,
		TeacherID:       &tLoser.ID,
		Star:            4,
		Comment:         "讲得不错",
	})
	if err != nil {
		t.Fatalf("用户初次评价旧教师失败: %v", err)
	}
	if initialSub == nil {
		t.Fatalf("初次评价返回为空")
	}

	// 执行课程合并，把 sLoser 并入 sKeeper，把 tLoser 配对并入 tKeeper
	previewInput := CourseMergeInput{
		KeeperSubjectID: sKeeper.ID,
		LoserSubjectIDs: []uint{sLoser.ID},
		FinalCourseName: "高等数学A1",
		TeacherPairs: []CourseMergeTeacherPair{
			{KeeperTeacherID: tKeeper.ID, LoserTeacherID: tLoser.ID, FinalTeacherName: "李四"},
		},
		Reason: "合并学科与教师",
	}

	preview, err := govSvc.PreviewCourseMerge(previewInput)
	if err != nil {
		t.Fatalf("PreviewCourseMerge 失败: %v", err)
	}

	mergeInput := previewInput
	mergeInput.SnapshotToken = preview.SnapshotToken
	_, err = govSvc.CourseMerge(admin.ID, mergeInput)
	if err != nil {
		t.Fatalf("CourseMerge 失败: %v", err)
	}

	// 检查旧提交的 DedupKey 是否已更新为新课程与新教师的规范去重键
	var migratedSub models.CourseEvaluationSubmission
	db.First(&migratedSub, initialSub.ID)
	expectedDedupKey := models.CourseEvaluationDedupKey(user.ID, sKeeper.Name, tKeeper.Name)
	if migratedSub.DedupKey != expectedDedupKey {
		t.Fatalf("迁移后的提交 DedupKey 应更新为 %q, 实际: %q", expectedDedupKey, migratedSub.DedupKey)
	}

	// 核心验证：用户通过教师评分入口再次评分，由于 DedupKey 正确维护，会自动查找到既有提交并走 Update，
	// 而绝不会因为找不到原提交去走新建从而触发 uq_teacher_rating_user 唯一约束冲突！
	updatedSub, err := evalSvc.RateVerifiedTeacher(user.ID, tKeeper.ID, 5, "合并后重新打5分")
	if err != nil {
		t.Fatalf("合并后再次评分失败 (可能触发了唯一约束): %v", err)
	}
	if updatedSub.Star != 5 {
		t.Fatalf("再次评分分数应为5, 实际: %d", updatedSub.Star)
	}

	// 验证 teacher_ratings 只有 1 条记录 (更新了原评价)，且星级为 5
	var userRatings []models.TeacherRating
	db.Where("teacher_id = ? AND user_id = ? AND deleted_at IS NULL", tKeeper.ID, user.ID).Find(&userRatings)
	if len(userRatings) != 1 {
		t.Fatalf("用户对保留教师应只有 1 条有效评分，实际有 %d 条", len(userRatings))
	}
	if userRatings[0].Star != 5 {
		t.Fatalf("评分未更新为5星, 实际: %d", userRatings[0].Star)
	}
}

// TestCourseEvaluationServiceCanonicalSubjectResolution 验证第2项问题：
// 课程规范目标解析收口，名称解析与ID读取自动跟随合并指向，已合并课程不直接作为目标
func TestCourseEvaluationServiceCanonicalSubjectResolution(t *testing.T) {
	db := newGovTestDB(t)
	evalSvc := NewCourseEvaluationService(db)

	sKeeper := models.CourseSubject{
		Name:           "高等数学A1",
		NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"),
		Verified:       true,
	}
	db.Create(&sKeeper)

	sLoser := models.CourseSubject{
		Name:           "高数（上）",
		NormalizedName: models.NormalizeCourseSubjectName("高数（上）"),
		Verified:       true,
		MergedIntoID:   &sKeeper.ID,
	}
	db.Create(&sLoser)

	// 别名指向 keeper 课程
	db.Create(&models.CourseSubjectAlias{
		CourseSubjectID: sKeeper.ID,
		Alias:           "高数（上）",
		NormalizedAlias: models.NormalizeCourseSubjectName("高数（上）"),
	})

	// 1. 测试 resolveSubjects：输入已合并的旧课程名，必须命中活跃的 keeper 课程，绝不能返回已合并的 loser
	candidates, err := evalSvc.resolveSubjects("高数（上）")
	if err != nil {
		t.Fatalf("resolveSubjects 失败: %v", err)
	}
	if len(candidates) == 0 {
		t.Fatalf("期望命中候选课程，实际返回空")
	}
	for _, c := range candidates {
		if c.ID == sLoser.ID {
			t.Fatalf("候选列表中包含了已合并的旧课程 #%d", sLoser.ID)
		}
	}
	if candidates[0].ID != sKeeper.ID {
		t.Fatalf("首选学科应为保留学科 #%d, 实际为 #%d", sKeeper.ID, candidates[0].ID)
	}

	// 2. 测试 canonicalizeTargetNames：传入旧课程 ID，必须自动解析并转换为保留课程 ID 和名称
	canonicalized := canonicalizeTargetNames(db, courseEvaluationInput{
		CourseSubjectID: &sLoser.ID,
		CourseName:      sLoser.Name,
	})
	if canonicalized.CourseSubjectID == nil || *canonicalized.CourseSubjectID != sKeeper.ID {
		t.Fatalf("canonicalizeTargetNames 未将旧课程ID重定向到 keeper, 实际: %v", canonicalized.CourseSubjectID)
	}
	if canonicalized.CourseName != sKeeper.Name {
		t.Fatalf("canonicalizeTargetNames 未将课程名称规范化为 keeper 名称, 实际: %q", canonicalized.CourseName)
	}

	// 3. 测试 resolveCanonicalCourseSubject 追溯
	resolved, err := resolveCanonicalCourseSubject(db, sLoser.ID)
	if err != nil {
		t.Fatalf("resolveCanonicalCourseSubject 失败: %v", err)
	}
	if resolved == nil || resolved.ID != sKeeper.ID {
		t.Fatalf("resolveCanonicalCourseSubject 未返回 keeper, 实际: %v", resolved)
	}
}

// TestCourseMergeSnapshotTokenDetectsRatingAndVoteChanges 验证第5项问题：
// 课程合并快照覆盖评价、投票和提交变化，能检测出预览后的评价变化并拒绝冲突 Token
func TestCourseMergeSnapshotTokenDetectsRatingAndVoteChanges(t *testing.T) {
	db := newGovTestDB(t)
	svc := NewTeacherGovernanceService(db)

	admin := models.User{Nickname: "超级管理员", Role: "admin"}
	db.Create(&admin)

	sKeeper := models.CourseSubject{
		Name:           "高等数学A1",
		NormalizedName: models.NormalizeCourseSubjectName("高等数学A1"),
		Verified:       true,
	}
	sLoser := models.CourseSubject{
		Name:           "高数（上）",
		NormalizedName: models.NormalizeCourseSubjectName("高数（上）"),
		Verified:       true,
	}
	db.Create(&sKeeper)
	db.Create(&sLoser)

	tKeeper := models.Teacher{
		Name:            "张三",
		Course:          "高等数学A1",
		CourseSubjectID: &sKeeper.ID,
		NameNormalized:  models.NormalizeTeacherName("张三"),
		Verified:        true,
	}
	tLoser := models.Teacher{
		Name:            "张老师",
		Course:          "高数（上）",
		CourseSubjectID: &sLoser.ID,
		NameNormalized:  models.NormalizeTeacherName("张老师"),
		Verified:        true,
	}
	db.Create(&tKeeper)
	db.Create(&tLoser)

	// 第一次预览生成快照 Token
	courseInput := CourseMergeInput{
		KeeperSubjectID: sKeeper.ID,
		LoserSubjectIDs: []uint{sLoser.ID},
		FinalCourseName: "高等数学A1",
		TeacherPairs: []CourseMergeTeacherPair{
			{KeeperTeacherID: tKeeper.ID, LoserTeacherID: tLoser.ID, FinalTeacherName: "张三"},
		},
		Reason: "快照验证",
	}

	preview1, err := svc.PreviewCourseMerge(courseInput)
	if err != nil {
		t.Fatalf("第一次 PreviewCourseMerge 失败: %v", err)
	}

	// 模拟在管理员确认前，有用户给 tLoser 新增了评价
	newRating := models.TeacherRating{
		TeacherID: tLoser.ID,
		UserID:    999,
		Star:      5,
		Comment:   "新评价",
	}
	if err := db.Create(&newRating).Error; err != nil {
		t.Fatalf("创建新评价失败: %v", err)
	}

	// 第二次预览生成快照 Token
	preview2, err := svc.PreviewCourseMerge(courseInput)
	if err != nil {
		t.Fatalf("第二次 PreviewCourseMerge 失败: %v", err)
	}

	// 核心验证：评价变动后快照 Token 必须改变！
	if preview1.SnapshotToken == preview2.SnapshotToken {
		t.Fatalf("新增评价后快照 Token 未改变，仍为 %q", preview1.SnapshotToken)
	}

	// 用旧快照 Token 执行合并必须被拦截并返回冲突错误
	staleInput := courseInput
	staleInput.SnapshotToken = preview1.SnapshotToken
	_, err = svc.CourseMerge(admin.ID, staleInput)
	if err == nil {
		t.Fatalf("使用过期快照 Token 执行合并应被拦截，实际未报错")
	}

	// 用新快照 Token 执行合并应成功
	freshInput := courseInput
	freshInput.SnapshotToken = preview2.SnapshotToken
	_, err = svc.CourseMerge(admin.ID, freshInput)
	if err != nil {
		t.Fatalf("使用最新快照 Token 执行合并失败: %v", err)
	}
}


