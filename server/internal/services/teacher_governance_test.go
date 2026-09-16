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
