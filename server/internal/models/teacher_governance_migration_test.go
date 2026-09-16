package models

import (
	"fmt"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func newTeacherGovernanceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:gov_test_%d?mode=memory&cache=shared", time.Now().UnixNano())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("创建内存数据库失败: %v", err)
	}
	return db
}

func TestTeacherGovernanceMigration(t *testing.T) {
	db := newTeacherGovernanceTestDB(t)

	if err := db.AutoMigrate(&CourseSubject{}, &Teacher{}, &TeacherRating{}, &TeacherRatingVote{}, &CourseEvaluationSubmission{}); err != nil {
		t.Fatalf("基础建表失败: %v", err)
	}
	// 生产启动时 EnsureRatingInteractionSchema 先建立此唯一索引，测试必须包含该索引
	if err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS uq_teacher_rating_user 
		ON teacher_ratings (teacher_id, user_id) 
		WHERE deleted_at IS NULL;
	`).Error; err != nil {
		t.Fatalf("创建唯一索引失败: %v", err)
	}

	// 插入学科
	mathSubject := CourseSubject{
		Name:            "高等数学A1",
		NormalizedName:  NormalizeCourseSubjectName("高等数学A1"),
		Verified:        true,
		CanonicalSource: "", // 空值待回填
	}
	if err := db.Create(&mathSubject).Error; err != nil {
		t.Fatalf("创建学科失败: %v", err)
	}

	// 插入历史 exact duplicates：同一学科下两个完全相同的张三，且都没有 canonical_source
	t1 := Teacher{
		Name:            "张三",
		Course:          "高等数学A1",
		CourseSubjectID: &mathSubject.ID,
		NameNormalized:  NormalizeTeacherName("张三"),
		Verified:        true,
		CanonicalSource: "",
	}
	t2 := Teacher{
		Name:            "张三",
		Course:          "高等数学A1",
		CourseSubjectID: &mathSubject.ID,
		NameNormalized:  NormalizeTeacherName("张三"),
		Verified:        false,
		CanonicalSource: "",
	}
	if err := db.Create(&t1).Error; err != nil {
		t.Fatalf("插入教师1失败: %v", err)
	}
	if err := db.Create(&t2).Error; err != nil {
		t.Fatalf("插入教师2失败: %v", err)
	}

	// 为 t1 和 t2 插入评价、投票和提交
	// 用户 101 评价 t1，用户 102 评价 t1 和 t2（发生评价冲突）
	r1 := TeacherRating{TeacherID: t1.ID, UserID: 101, Star: 5, Comment: "讲得好"}
	r2_1 := TeacherRating{TeacherID: t1.ID, UserID: 102, Star: 4, Comment: "老评价", CreatedAt: time.Now().Add(-time.Hour)}
	r2_2 := TeacherRating{TeacherID: t2.ID, UserID: 102, Star: 5, Comment: "新评价", CreatedAt: time.Now()}
	if err := db.Create(&r1).Error; err != nil || db.Create(&r2_1).Error != nil || db.Create(&r2_2).Error != nil {
		t.Fatalf("创建评价失败")
	}

	// 用户 201 投票 r2_1，用户 201 也投票 r2_2（投票冲突，去重后重挂）
	v1 := TeacherRatingVote{RatingID: r2_1.ID, UserID: 201, VoteType: "up", UpdatedAt: time.Now().Add(-time.Minute)}
	v2 := TeacherRatingVote{RatingID: r2_2.ID, UserID: 201, VoteType: "up", UpdatedAt: time.Now()}
	if err := db.Create(&v1).Error; err != nil || db.Create(&v2).Error != nil {
		t.Fatalf("创建投票失败")
	}

	// 提交记录
	sub1 := CourseEvaluationSubmission{
		UserID:          102,
		DedupKey:        "102|sub1",
		CourseName:      "高等数学A1",
		TeacherName:     "张三",
		TeacherID:       &t2.ID,
		TeacherRatingID: &r2_2.ID,
		Status:          CourseEvaluationStatusPublished,
	}
	sub2 := CourseEvaluationSubmission{
		UserID:          102,
		DedupKey:        "102|sub2",
		CourseName:      "高等数学A1",
		TeacherName:     "张三",
		TeacherID:       &t1.ID,
		TeacherRatingID: &r2_1.ID,
		Status:          CourseEvaluationStatusPublished,
	}
	if err := db.Create(&sub1).Error; err != nil || db.Create(&sub2).Error != nil {
		t.Fatalf("创建提交失败")
	}

	// --- 第一次执行迁移 ---
	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("第一次运行 EnsureCourseEvaluationSchema 失败: %v", err)
	}
	if err := EnsureTeacherGovernanceSchema(db); err != nil {
		t.Fatalf("第一次运行 EnsureTeacherGovernanceSchema 失败: %v", err)
	}

	// 1. 验证 canonical_source 回填为 legacy
	var checkSub CourseSubject
	db.First(&checkSub, mathSubject.ID)
	if checkSub.CanonicalSource != TeacherSourceLegacy {
		t.Fatalf("学科 canonical_source 应为 legacy，得到 %q", checkSub.CanonicalSource)
	}

	var checkT1, checkT2 Teacher
	db.First(&checkT1, t1.ID)
	db.First(&checkT2, t2.ID)
	if checkT1.CanonicalSource != TeacherSourceLegacy || checkT2.CanonicalSource != TeacherSourceLegacy {
		t.Fatalf("教师 canonical_source 应为 legacy，得到 t1=%q, t2=%q", checkT1.CanonicalSource, checkT2.CanonicalSource)
	}

	// 2. exact duplicate 转为 merged tombstone，绝不物理删除 loser
	if checkT1.MergedIntoID != nil {
		t.Fatalf("t1 为 keeper，merged_into_id 应为空")
	}
	if checkT2.MergedIntoID == nil || *checkT2.MergedIntoID != t1.ID {
		t.Fatalf("t2 应被合并到 t1(#%d)，得到 %v", t1.ID, checkT2.MergedIntoID)
	}

	// 3. 评价冲突裁决：r2_2 (较新)胜出并重挂至 t1，r2_1 软删除
	var checkR2_1, checkR2_2 TeacherRating
	db.Unscoped().First(&checkR2_1, r2_1.ID)
	db.Unscoped().First(&checkR2_2, r2_2.ID)
	if checkR2_1.DeletedAt.Valid == false {
		t.Fatalf("旧评价 r2_1 应被软删除")
	}
	if checkR2_2.TeacherID != t1.ID {
		t.Fatalf("新评价 r2_2 应重挂到 keeper t1(#%d)，得到 %d", t1.ID, checkR2_2.TeacherID)
	}

	// 4. 提交状态：指向已软删除评价的 sub2 应进入 superseded
	var checkSub2 CourseEvaluationSubmission
	db.First(&checkSub2, sub2.ID)
	if checkSub2.Status != CourseEvaluationStatusSuperseded {
		t.Fatalf("sub2 状态应为 superseded，得到 %q", checkSub2.Status)
	}
	if checkSub2.TeacherRatingID != nil {
		t.Fatalf("superseded 提交的 teacher_rating_id 应置空")
	}

	// 5. 检查审计记录存在
	var mergeRecords []TeacherMergeRecord
	db.Where("loser_id = ?", t2.ID).Find(&mergeRecords)
	if len(mergeRecords) == 0 {
		t.Fatalf("应为 loser #%d 写入 TeacherMergeRecord 审计记录", t2.ID)
	}

	// 6. 验证 active partial index 存在，且 merged row 不占 active unique key
	var activeIndexCount int64
	db.Raw("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'uq_teachers_active_subject_name'").Scan(&activeIndexCount)
	if activeIndexCount != 1 {
		t.Fatalf("活动教师唯一索引 uq_teachers_active_subject_name 未创建")
	}

	// 验证 merged row 不占用唯一键：由于 t2 已经 merged，再创建一个活动“张三”时应当成功或失败？
	// t1 是活动的“张三”，再建一个活动的“张三”应该被拒绝
	activeDup := Teacher{
		Name:            "张三",
		Course:          "高等数学A1",
		CourseSubjectID: &mathSubject.ID,
		NameNormalized:  NormalizeTeacherName("张三"),
	}
	if err := db.Create(&activeDup).Error; err == nil {
		t.Fatalf("活动教师唯一索引应拒绝第二个活动的张三")
	}
	// 但插入一个已经被 merged 的张三应当允许（不占 active unique key）
	mergedDup := Teacher{
		Name:            "张三",
		Course:          "高等数学A1",
		CourseSubjectID: &mathSubject.ID,
		NameNormalized:  NormalizeTeacherName("张三"),
		MergedIntoID:    &t1.ID,
	}
	if err := db.Create(&mergedDup).Error; err != nil {
		t.Fatalf("已合并的教师不应受活动教师唯一索引约束: %v", err)
	}

	// --- 7. 第二次执行迁移（测试幂等性与不物理删除 loser） ---
	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("第二次运行 EnsureCourseEvaluationSchema 失败: %v", err)
	}
	if err := EnsureTeacherGovernanceSchema(db); err != nil {
		t.Fatalf("第二次运行 EnsureTeacherGovernanceSchema 失败: %v", err)
	}

	// 8. 验证第二次运行后，loser t2 仍然存在（未被物理删除）
	var checkT2Again Teacher
	if err := db.First(&checkT2Again, t2.ID).Error; err != nil {
		t.Fatalf("第二次迁移后 loser 教师 t2 应继续保留在数据库中: %v", err)
	}
	if checkT2Again.MergedIntoID == nil || *checkT2Again.MergedIntoID != t1.ID {
		t.Fatalf("t2 仍应指向 keeper t1")
	}
}
