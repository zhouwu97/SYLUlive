package models

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func newCourseEvaluationTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "course-eval.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	// Windows 下必须先关闭连接，否则 t.TempDir() 清理时文件仍被占用。
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("获取底层连接失败: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&Teacher{}, &TeacherRating{}, &TeacherRatingVote{}); err != nil {
		t.Fatalf("准备既有表失败: %v", err)
	}
	return db
}

func TestNormalizeCourseSubjectNameKeepsSuffixDistinct(t *testing.T) {
	cases := []struct{ in, want string }{
		{"高等数学A1", "高等数学a1"},
		{"高等数学A2", "高等数学a2"},
		{"  高等数学  A1  ", "高等数学 a1"},
		{"高等数学　A1", "高等数学 a1"},
		{"高等数学Ａ１", "高等数学a1"},
		// 全角标点折叠为半角等价字符，但括号本身保留。
		{"线性代数（上）", "线性代数(上)"},
		{"线性代数(上)", "线性代数(上)"},
	}
	for _, c := range cases {
		if got := NormalizeCourseSubjectName(c.in); got != c.want {
			t.Errorf("NormalizeCourseSubjectName(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if NormalizeCourseSubjectName("高等数学A1") == NormalizeCourseSubjectName("高等数学A2") {
		t.Fatal("A1 与 A2 必须保持不同实体")
	}
}

func TestCourseEvaluationCommentTruncationUsesRunes(t *testing.T) {
	long := ""
	for i := 0; i < 250; i++ {
		long += "评"
	}
	truncated := TruncateCourseEvaluationComment(long)
	if CourseEvaluationCommentLength(truncated) != CourseEvaluationCommentMaxRunes {
		t.Fatalf("截断后长度 = %d, want %d", CourseEvaluationCommentLength(truncated), CourseEvaluationCommentMaxRunes)
	}
}

func TestCourseEvaluationDedupKeyIgnoresScheduleFields(t *testing.T) {
	a := CourseEvaluationDedupKey(7, "高等数学 A1", "张三")
	b := CourseEvaluationDedupKey(7, "  高等数学　A1 ", "张三")
	if a != b {
		t.Fatalf("规范化后去重键应一致: %q vs %q", a, b)
	}
	if CourseEvaluationDedupKey(8, "高等数学 A1", "张三") == a {
		t.Fatal("不同用户的去重键必须不同")
	}
}

func TestEnsureCourseEvaluationSchemaBackfillsSubjectsAndTeachers(t *testing.T) {
	db := newCourseEvaluationTestDB(t)
	db.Create(&Teacher{Name: "张三", Course: "高等数学A1", Verified: true, CreatedBy: 1})
	db.Create(&Teacher{Name: "李四", Course: "高等数学A2", Verified: true, CreatedBy: 1})

	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("首次迁移失败: %v", err)
	}

	var subjects []CourseSubject
	if err := db.Order("id ASC").Find(&subjects).Error; err != nil {
		t.Fatalf("读取学科失败: %v", err)
	}
	if len(subjects) != 2 {
		t.Fatalf("应创建 2 个学科，实际 %d", len(subjects))
	}

	var teacher Teacher
	if err := db.Where("name = ?", "张三").First(&teacher).Error; err != nil {
		t.Fatalf("读取教师失败: %v", err)
	}
	if teacher.CourseSubjectID == nil || *teacher.CourseSubjectID == 0 {
		t.Fatal("教师应已回填标准学科")
	}
	if teacher.NameNormalized != NormalizeTeacherName("张三") {
		t.Fatalf("教师规范化姓名未回填: %q", teacher.NameNormalized)
	}

	// 幂等：重复执行不应报错，也不应产生新学科。
	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("重复迁移失败: %v", err)
	}
	var count int64
	db.Model(&CourseSubject{}).Count(&count)
	if count != 2 {
		t.Fatalf("重复迁移后学科数应仍为 2，实际 %d", count)
	}
}

func TestEnsureCourseEvaluationSchemaMergesDuplicateTeachers(t *testing.T) {
	db := newCourseEvaluationTestDB(t)
	winner := Teacher{Name: "张三", Course: "高等数学A1", Verified: true, CreatedBy: 1}
	db.Create(&winner)
	loser := Teacher{Name: " 张三 ", Course: "高等数学A1", Verified: false, CreatedBy: 2}
	db.Create(&loser)

	// winner 与 loser 各有一条评价，其中 user 9 在两边都有评价。
	db.Create(&TeacherRating{TeacherID: winner.ID, UserID: 9, Star: 5, Comment: "保留", Status: "normal"})
	db.Create(&TeacherRating{TeacherID: loser.ID, UserID: 9, Star: 3, Comment: "重复", Status: "normal"})
	db.Create(&TeacherRating{TeacherID: loser.ID, UserID: 10, Star: 4, Comment: "迁移", Status: "normal"})
	db.Create(&TeacherRatingVote{RatingID: 3, UserID: 11, VoteType: "up"})

	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}

	var remaining int64
	db.Model(&Teacher{}).Where("name_normalized = ?", NormalizeTeacherName("张三")).Count(&remaining)
	if remaining != 1 {
		t.Fatalf("重复教师应合并为 1 条，实际 %d", remaining)
	}

	var liveRatings []TeacherRating
	if err := db.Where("teacher_id = ? AND user_id = ?", winner.ID, 9).Find(&liveRatings).Error; err != nil {
		t.Fatalf("读取评价失败: %v", err)
	}
	if len(liveRatings) != 1 {
		t.Fatalf("user 9 在合并后应只剩 1 条在架评价，实际 %d", len(liveRatings))
	}
	if liveRatings[0].Comment != "保留" {
		t.Fatalf("应保留 winner 的评价，实际 %q", liveRatings[0].Comment)
	}

	var migrated TeacherRating
	if err := db.Where("teacher_id = ? AND user_id = ?", winner.ID, 10).First(&migrated).Error; err != nil {
		t.Fatalf("user 10 的评价应重挂到 winner: %v", err)
	}
	if migrated.HelpfulCount != 1 {
		t.Fatalf("投票计数应重算为 1，实际 %d", migrated.HelpfulCount)
	}
}

func TestEnsureCourseEvaluationSchemaCreatesUniqueIndexes(t *testing.T) {
	db := newCourseEvaluationTestDB(t)
	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	for _, name := range []string{
		"uq_course_subjects_normalized_name",
		"uq_teachers_subject_name",
		"uq_course_evaluation_submission_dedup",
	} {
		var count int64
		if err := db.Raw("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?", name).Scan(&count).Error; err != nil {
			t.Fatalf("检查索引 %s 失败: %v", name, err)
		}
		if count != 1 {
			t.Fatalf("索引 %s 未创建", name)
		}
	}

	// 唯一索引生效：同一学科下重复教师名应被拒绝。
	var subject CourseSubject
	db.Where("normalized_name = ?", NormalizeCourseSubjectName("高等数学A1")).First(&subject)
	if subject.ID == 0 {
		subject = CourseSubject{Name: "高等数学A1", NormalizedName: NormalizeCourseSubjectName("高等数学A1"), Verified: true}
		db.Create(&subject)
	}
	dup := Teacher{Name: "王五", Course: "高等数学A1", NameNormalized: NormalizeTeacherName("王五"), CourseSubjectID: &subject.ID}
	if err := db.Create(&dup).Error; err != nil {
		t.Fatalf("首次创建教师失败: %v", err)
	}
	dup.ID = 0
	if err := db.Create(&dup).Error; err == nil {
		t.Fatal("唯一索引应拒绝同一学科下的重复教师名")
	}
}

func TestIsCourseEvaluationStatus(t *testing.T) {
	for _, ok := range []string{"pending", "published", "needs_edit"} {
		if !IsCourseEvaluationStatus(ok) {
			t.Fatalf("%s 应为合法状态", ok)
		}
	}
	if IsCourseEvaluationStatus("approved") {
		t.Fatal("approved 不是合法状态")
	}
}

func TestMigrationKeepsSubmissionRevisionFields(t *testing.T) {
	db := newCourseEvaluationTestDB(t)
	if err := EnsureCourseEvaluationSchema(db); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	now := time.Now()
	sub := CourseEvaluationSubmission{
		UserID:      1,
		DedupKey:    CourseEvaluationDedupKey(1, "高等数学A1", "张三"),
		Source:      CourseEvaluationSourceSchedule,
		CourseName:  "高等数学A1",
		TeacherName: "张三",
		Star:        5,
		Status:      CourseEvaluationStatusPending,
		Revision:    1,
		ReviewedAt:  &now,
	}
	if err := db.Create(&sub).Error; err != nil {
		t.Fatalf("创建提交记录失败: %v", err)
	}
	if sub.Revision != 1 {
		t.Fatalf("revision 默认应为 1，实际 %d", sub.Revision)
	}
}
