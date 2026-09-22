package services

import (
	"errors"
	"strings"
	"testing"

	"shenliyuan/internal/models"
)

// govInjectedReadFailure 是测试注入的查询错误文本。
var govInjectedReadFailure = errors.New("injected snapshot read failure")

// seedGovSnapshotRows 给每一类快照读取都至少留下一行数据：
// 评价、投票、提交、课程别名。这样「注入失败的阶段」一定命中真实查询，
// 也才能区分「读到 0 行」和「读取失败」。
func (f *govIntentFixture) seedGovSnapshotRows(t *testing.T) {
	t.Helper()
	rating := models.TeacherRating{
		TeacherID: f.loserB.ID, UserID: 3001, Star: 5,
		Comment: "讲得清楚", Status: "normal",
	}
	if err := f.db.Create(&rating).Error; err != nil {
		t.Fatalf("创建评价失败: %v", err)
	}
	vote := models.TeacherRatingVote{RatingID: rating.ID, UserID: 4001, VoteType: "up"}
	if err := f.db.Create(&vote).Error; err != nil {
		t.Fatalf("创建投票失败: %v", err)
	}
	submission := models.CourseEvaluationSubmission{
		UserID: 3001, DedupKey: "3001|gov-snapshot", CourseName: f.subjectA.Name,
		TeacherName: f.loserB.Name, TeacherID: &f.loserB.ID, CourseSubjectID: &f.subjectA.ID,
		TeacherRatingID: &rating.ID, Status: models.CourseEvaluationStatusPublished,
	}
	if err := f.db.Create(&submission).Error; err != nil {
		t.Fatalf("创建提交失败: %v", err)
	}
	alias := models.CourseSubjectAlias{
		CourseSubjectID: f.subjectA.ID, Alias: "高数A",
		NormalizedAlias: models.NormalizeCourseSubjectName("高数A"),
	}
	if err := f.db.Create(&alias).Error; err != nil {
		t.Fatalf("创建课程别名失败: %v", err)
	}
}

func (f *govIntentFixture) teacherMergeInput() MergeInput {
	return MergeInput{KeeperID: f.keeperA.ID, LoserIDs: []uint{f.loserB.ID}}
}

// requireInternalSnapshotError 断言失败被归类为「快照读取失败」而不是被吞掉。
func requireInternalSnapshotError(t *testing.T, err error, stage string) {
	t.Helper()
	if err == nil {
		t.Fatalf("阶段 %s 的读取失败被吞掉了", stage)
	}
	var govErr *TeacherGovernanceError
	if !errors.As(err, &govErr) {
		t.Fatalf("应返回治理业务错误，实际 %v", err)
	}
	if govErr.Code != CodeTeacherGovernanceInternalError {
		t.Fatalf("应返回 %s，实际 %s（%v）", CodeTeacherGovernanceInternalError, govErr.Code, err)
	}
	if status := TeacherGovernanceHTTPStatus(govErr.Code); status < 500 {
		t.Fatalf("快照读取失败必须是 5xx，实际 %d", status)
	}
	if !strings.Contains(govErr.Error(), "stage="+stage) {
		t.Fatalf("错误应带上失败阶段 %s，实际 %v", stage, err)
	}
	if !errors.Is(err, govInjectedReadFailure) {
		t.Fatalf("应保留底层查询错误，实际 %v", err)
	}
}

// GOV-06：教师合并快照的每一类读取失败都要让预览明确报错，且不产出可执行凭证。
func TestTeacherMergePreviewFailsOnEverySnapshotReadError(t *testing.T) {
	for _, stage := range govTeacherMergeSnapshotStages {
		stage := stage
		t.Run(stage, func(t *testing.T) {
			f := newGovIntentFixture(t)
			f.seedGovSnapshotRows(t)
			svc := f.service()

			govSnapshotReadFault = func(s string) error {
				if s == stage {
					return govInjectedReadFailure
				}
				return nil
			}
			t.Cleanup(func() { govSnapshotReadFault = nil })

			plan, err := svc.PreviewMerge(f.teacherMergeInput())
			requireInternalSnapshotError(t, err, stage)
			if plan != nil {
				t.Fatalf("读取失败时不得返回预览计划，实际 token=%q", plan.SnapshotToken)
			}
		})
	}
}

// GOV-06：课程合并快照的每一类读取失败都要让预览明确报错。
func TestCourseMergePreviewFailsOnEverySnapshotReadError(t *testing.T) {
	for _, stage := range govCourseMergeSnapshotStages {
		stage := stage
		t.Run(stage, func(t *testing.T) {
			f := newGovIntentFixture(t)
			f.seedGovSnapshotRows(t)
			svc := f.service()

			input := CourseMergeInput{
				KeeperSubjectID: f.subjectA.ID,
				LoserSubjectIDs: []uint{f.subjectB.ID},
				TeacherPairs: []CourseMergeTeacherPair{{
					LoserTeacherID: f.loserC.ID, KeeperTeacherID: f.keeperA.ID,
				}},
			}
			govSnapshotReadFault = func(s string) error {
				if s == stage {
					return govInjectedReadFailure
				}
				return nil
			}
			t.Cleanup(func() { govSnapshotReadFault = nil })

			result, err := svc.PreviewCourseMerge(input)
			requireInternalSnapshotError(t, err, stage)
			if result != nil {
				t.Fatalf("读取失败时不得返回预览结果，实际 token=%q", result.SnapshotToken)
			}
		})
	}
}

// GOV-07：真实的「没有评价」与「读取失败」必须可区分，界面才不会显示虚假零影响。
func TestTeacherMergePreviewSeparatesEmptyFromFailedRatings(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	plan, err := svc.PreviewMerge(f.teacherMergeInput())
	if err != nil {
		t.Fatalf("无评价时预览应成功: %v", err)
	}
	if plan.TotalRatingsMigrated != 0 {
		t.Fatalf("无评价时迁移数应为 0，实际 %d", plan.TotalRatingsMigrated)
	}

	govSnapshotReadFault = func(s string) error {
		if s == govSnapStageRatings {
			return govInjectedReadFailure
		}
		return nil
	}
	t.Cleanup(func() { govSnapshotReadFault = nil })

	if _, err := svc.PreviewMerge(f.teacherMergeInput()); err == nil {
		t.Fatalf("评价读取失败时预览不得成功返回「0 条迁移」")
	}
}

// GOV-08/GOV-09：事务内快照读取失败要整单回滚，数据库恢复后重试仍然可用。
func TestTeacherMergeRollsBackWhenInTxSnapshotReadFails(t *testing.T) {
	f := newGovIntentFixture(t)
	f.seedGovSnapshotRows(t)
	svc := f.service()

	preview, err := svc.PreviewMerge(f.teacherMergeInput())
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	// Merge 会先在事务外构建计划（第 1 次读 ratings），再在持锁事务内复核（第 2 次）。
	ratingsReads := 0
	govSnapshotReadFault = func(s string) error {
		if s != govSnapStageRatings {
			return nil
		}
		ratingsReads++
		if ratingsReads == 2 {
			return govInjectedReadFailure
		}
		return nil
	}

	input := f.teacherMergeInput()
	input.SnapshotToken = preview.SnapshotToken
	_, err = svc.Merge(f.admin.ID, input)
	requireInternalSnapshotError(t, err, govSnapStageRatings)

	if f.mergedInto(t, f.loserB.ID) != nil {
		t.Fatalf("事务内读取失败后不得留下半完成的合并")
	}
	var mergeRecords int64
	if err := f.db.Model(&models.TeacherMergeRecord{}).Count(&mergeRecords).Error; err != nil {
		t.Fatalf("统计合并记录失败: %v", err)
	}
	if mergeRecords != 0 {
		t.Fatalf("失败的合并不得写审计记录，实际 %d 条", mergeRecords)
	}
	var movedVotes int64
	if err := f.db.Model(&models.TeacherRatingVote{}).
		Joins("JOIN teacher_ratings ON teacher_ratings.id = teacher_rating_votes.rating_id").
		Where("teacher_ratings.teacher_id = ?", f.keeperA.ID).Count(&movedVotes).Error; err != nil {
		t.Fatalf("统计投票失败: %v", err)
	}
	if movedVotes != 0 {
		t.Fatalf("失败的合并不得迁移投票，实际 %d 条", movedVotes)
	}

	// GOV-09：数据库恢复后用同一凭证重试应当成功。
	govSnapshotReadFault = nil
	if _, err := svc.Merge(f.admin.ID, input); err != nil {
		t.Fatalf("恢复后重试失败: %v", err)
	}
	if merged := f.mergedInto(t, f.loserB.ID); merged == nil || *merged != f.keeperA.ID {
		t.Fatalf("重试后 loser 应并入 keeper，实际 %v", merged)
	}
}

// GOV-04：完全相同意图的成功重试不重复迁移、不重复写审计。
func TestTeacherMergeIdenticalRetryDoesNotDuplicateAudit(t *testing.T) {
	f := newGovIntentFixture(t)
	f.seedGovSnapshotRows(t)
	svc := f.service()

	preview, err := svc.PreviewMerge(f.teacherMergeInput())
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}
	input := f.teacherMergeInput()
	input.SnapshotToken = preview.SnapshotToken
	if _, err := svc.Merge(f.admin.ID, input); err != nil {
		t.Fatalf("首次合并失败: %v", err)
	}

	recordsAfterFirst := countGovRows(t, f, &models.TeacherMergeRecord{})
	logsAfterFirst := countGovRows(t, f, &models.AdminLog{})

	if _, err := svc.Merge(f.admin.ID, input); err != nil {
		t.Fatalf("相同意图重试应幂等成功，实际报错: %v", err)
	}
	if got := countGovRows(t, f, &models.TeacherMergeRecord{}); got != recordsAfterFirst {
		t.Fatalf("重复执行写入了新的合并记录：%d → %d", recordsAfterFirst, got)
	}
	if got := countGovRows(t, f, &models.AdminLog{}); got != logsAfterFirst {
		t.Fatalf("重复执行写入了新的管理日志：%d → %d", logsAfterFirst, got)
	}
}

func countGovRows(t *testing.T, f *govIntentFixture, model interface{}) int64 {
	t.Helper()
	var count int64
	if err := f.db.Model(model).Count(&count).Error; err != nil {
		t.Fatalf("统计失败: %v", err)
	}
	return count
}

// GOV-05：预览凭证不是授权凭据，缺少管理员身份时不得执行。
func TestGovernanceTokenIsNotAuthorization(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	teacherPreview, err := svc.PreviewMerge(f.teacherMergeInput())
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}
	input := f.teacherMergeInput()
	input.SnapshotToken = teacherPreview.SnapshotToken
	if _, err := svc.Merge(0, input); err == nil {
		t.Fatalf("adminID=0 不应执行教师合并")
	} else {
		var govErr *TeacherGovernanceError
		if !errors.As(err, &govErr) || govErr.Code != CodeTeacherGovernanceForbidden {
			t.Fatalf("教师合并应返回 %s，实际 %v", CodeTeacherGovernanceForbidden, err)
		}
	}
	if f.mergedInto(t, f.loserB.ID) != nil {
		t.Fatalf("未授权调用不得改动数据")
	}

	coursePreview, err := svc.PreviewCourseMerge(CourseMergeInput{
		KeeperSubjectID: f.subjectA.ID,
		LoserSubjectIDs: []uint{f.subjectB.ID},
		TeacherPairs: []CourseMergeTeacherPair{{
			LoserTeacherID: f.loserC.ID, KeeperTeacherID: f.keeperA.ID,
		}},
	})
	if err != nil {
		t.Fatalf("课程预览失败: %v", err)
	}
	courseInput := CourseMergeInput{
		KeeperSubjectID: f.subjectA.ID,
		LoserSubjectIDs: []uint{f.subjectB.ID},
		TeacherPairs: []CourseMergeTeacherPair{{
			LoserTeacherID: f.loserC.ID, KeeperTeacherID: f.keeperA.ID,
		}},
		SnapshotToken: coursePreview.SnapshotToken,
	}
	if _, err := svc.CourseMerge(0, courseInput); err == nil {
		t.Fatalf("adminID=0 不应执行课程合并")
	} else {
		var govErr *TeacherGovernanceError
		if !errors.As(err, &govErr) || govErr.Code != CodeTeacherGovernanceForbidden {
			t.Fatalf("课程合并应返回 %s，实际 %v", CodeTeacherGovernanceForbidden, err)
		}
	}
	var stillActive int64
	if err := f.db.Model(&models.CourseSubject{}).
		Where("id = ? AND merged_into_id IS NULL", f.subjectB.ID).Count(&stillActive).Error; err != nil {
		t.Fatalf("统计课程失败: %v", err)
	}
	if stillActive != 1 {
		t.Fatalf("未授权调用不得改动课程数据")
	}
}

// GOV-02 反例：语义无关的数组顺序（loser 列表、教师配对）不得让凭证失效。
func TestGovernanceTokenIgnoresSemanticallyIrrelevantOrder(t *testing.T) {
	f := newGovIntentFixture(t)
	f.seedGovSnapshotRows(t)
	svc := f.service()

	third := models.Teacher{
		Name: "张三讲义", Course: f.subjectA.Name, CourseSubjectID: &f.subjectA.ID,
		NameNormalized: models.NormalizeTeacherName("张三讲义"), Verified: true,
	}
	if err := f.db.Create(&third).Error; err != nil {
		t.Fatalf("创建教师失败: %v", err)
	}
	preview, err := svc.PreviewMerge(MergeInput{
		KeeperID: f.keeperA.ID,
		LoserIDs: []uint{f.loserB.ID, third.ID},
	})
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}
	reordered := MergeInput{
		KeeperID: f.keeperA.ID,
		LoserIDs: []uint{third.ID, 0, f.loserB.ID},
	}
	reordered.SnapshotToken = preview.SnapshotToken
	if _, err := svc.Merge(f.admin.ID, reordered); err != nil {
		t.Fatalf("仅改变无语义的顺序与冗余 0 不应让凭证失效: %v", err)
	}
}

// GOV-02/GOV-03：最终名称、评价与投票任一变化，旧凭证都必须失效。
func TestTeacherMergeTokenBindsNameAndRatingState(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	base := f.teacherMergeInput()
	base.FinalTeacherName = "张三"
	preview, err := svc.PreviewMerge(base)
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	renamed := base
	renamed.FinalTeacherName = "张三丰"
	renamed.SnapshotToken = preview.SnapshotToken
	requireStaleToken(t, func() error {
		_, err := svc.Merge(f.admin.ID, renamed)
		return err
	}())
	if f.mergedInto(t, f.loserB.ID) != nil {
		t.Fatalf("改名后的旧凭证不得执行合并")
	}

	// 数据侧：管理员确认预览后，用户新增一条评价。
	input := f.teacherMergeInput()
	fresh, err := svc.PreviewMerge(input)
	if err != nil {
		t.Fatalf("第二次预览失败: %v", err)
	}
	rating := models.TeacherRating{TeacherID: f.loserB.ID, UserID: 5001, Star: 4, Comment: "新评价", Status: "normal"}
	if err := f.db.Create(&rating).Error; err != nil {
		t.Fatalf("创建评价失败: %v", err)
	}
	vote := models.TeacherRatingVote{RatingID: rating.ID, UserID: 5002, VoteType: "up"}
	if err := f.db.Create(&vote).Error; err != nil {
		t.Fatalf("创建投票失败: %v", err)
	}

	stale := input
	stale.SnapshotToken = fresh.SnapshotToken
	requireStaleToken(t, func() error {
		_, err := svc.Merge(f.admin.ID, stale)
		return err
	}())
	if f.mergedInto(t, f.loserB.ID) != nil {
		t.Fatalf("评价/投票变化后旧凭证不得执行合并")
	}

	after, err := svc.PreviewMerge(input)
	if err != nil {
		t.Fatalf("第三次预览失败: %v", err)
	}
	if after.SnapshotToken == fresh.SnapshotToken {
		t.Fatalf("新增评价与投票后数据快照未变化")
	}
	if after.TotalRatingsMigrated != 1 {
		t.Fatalf("预览应报告 1 条评价迁移，实际 %d", after.TotalRatingsMigrated)
	}
	retry := input
	retry.SnapshotToken = after.SnapshotToken
	if _, err := svc.Merge(f.admin.ID, retry); err != nil {
		t.Fatalf("使用最新凭证执行失败: %v", err)
	}
}

// GOV-02：课程合并的最终课程名与配对教师名变化，旧凭证必须失效。
func TestCourseMergeTokenBindsFinalNames(t *testing.T) {
	f := newGovIntentFixture(t)
	svc := f.service()

	base := CourseMergeInput{
		KeeperSubjectID: f.subjectA.ID,
		LoserSubjectIDs: []uint{f.subjectB.ID},
		FinalCourseName: f.subjectA.Name,
		TeacherPairs: []CourseMergeTeacherPair{{
			LoserTeacherID: f.loserC.ID, KeeperTeacherID: f.keeperA.ID, FinalTeacherName: "张三",
		}},
	}
	preview, err := svc.PreviewCourseMerge(base)
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	renamedCourse := base
	renamedCourse.FinalCourseName = "高等数学A1（合并）"
	renamedCourse.SnapshotToken = preview.SnapshotToken
	cErr := func() error {
		_, err := svc.CourseMerge(f.admin.ID, renamedCourse)
		return err
	}()
	requireStaleToken(t, cErr)

	renamedTeacher := base
	renamedTeacher.TeacherPairs = []CourseMergeTeacherPair{{
		LoserTeacherID: f.loserC.ID, KeeperTeacherID: f.keeperA.ID, FinalTeacherName: "张三丰",
	}}
	renamedTeacher.SnapshotToken = preview.SnapshotToken
	requireStaleToken(t, func() error {
		_, err := svc.CourseMerge(f.admin.ID, renamedTeacher)
		return err
	}())

	var stillActive int64
	if err := f.db.Model(&models.CourseSubject{}).
		Where("id = ? AND merged_into_id IS NULL", f.subjectB.ID).Count(&stillActive).Error; err != nil {
		t.Fatalf("统计课程失败: %v", err)
	}
	if stillActive != 1 {
		t.Fatalf("被拒绝的课程合并不得改动数据")
	}
}

// GOV-02 反例：教师配对数组的顺序无语义，不得让课程合并凭证失效。
func TestCourseMergeTokenIgnoresPairOrder(t *testing.T) {
	f := newGovIntentFixture(t)
	f.seedGovSnapshotRows(t)
	svc := f.service()

	newTeacher := func(name string, subject *models.CourseSubject) *models.Teacher {
		teacher := models.Teacher{
			Name: name, Course: subject.Name, CourseSubjectID: &subject.ID,
			NameNormalized: models.NormalizeTeacherName(name), Verified: true,
		}
		if err := f.db.Create(&teacher).Error; err != nil {
			t.Fatalf("创建教师 %s 失败: %v", name, err)
		}
		return &teacher
	}
	keeper2 := newTeacher("李四", f.subjectA)
	loser2 := newTeacher("李四老师", f.subjectB)

	firstPair := CourseMergeTeacherPair{LoserTeacherID: f.loserC.ID, KeeperTeacherID: f.keeperA.ID}
	secondPair := CourseMergeTeacherPair{LoserTeacherID: loser2.ID, KeeperTeacherID: keeper2.ID}

	base := CourseMergeInput{
		KeeperSubjectID: f.subjectA.ID,
		LoserSubjectIDs: []uint{f.subjectB.ID},
		TeacherPairs:    []CourseMergeTeacherPair{firstPair, secondPair},
	}
	preview, err := svc.PreviewCourseMerge(base)
	if err != nil {
		t.Fatalf("预览失败: %v", err)
	}

	reordered := base
	reordered.TeacherPairs = []CourseMergeTeacherPair{secondPair, firstPair}
	reordered.SnapshotToken = preview.SnapshotToken
	if _, err := svc.CourseMerge(f.admin.ID, reordered); err != nil {
		t.Fatalf("仅调整配对顺序不应让凭证失效: %v", err)
	}
	if merged := f.mergedInto(t, f.loserC.ID); merged == nil || *merged != f.keeperA.ID {
		t.Fatalf("配对未被执行，loserC 指向 %v", merged)
	}
}
