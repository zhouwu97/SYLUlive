package models

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestNormalizeExamPaperMetadataBuildsServerTitle(t *testing.T) {
	metadata, err := NormalizeExamPaperMetadata(
		"  高等数学  ",
		"2025-2026",
		ExamPaperSemesterFirst,
		ExamPaperTypeFinal,
	)
	if err != nil {
		t.Fatalf("规范化元数据失败: %v", err)
	}
	if metadata.CourseName != "高等数学" {
		t.Fatalf("课程名未去除首尾空格: %q", metadata.CourseName)
	}
	if metadata.Title != "高等数学 · 2025-2026 · 第一学期 · 期末" {
		t.Fatalf("服务端标题不符合约定: %q", metadata.Title)
	}
}

func TestNormalizeExamPaperMetadataRejectsInvalidValues(t *testing.T) {
	tests := []struct {
		name         string
		courseName   string
		academicYear string
		semester     ExamPaperSemester
		examType     ExamPaperType
	}{
		{name: "课程名为空", courseName: "  ", academicYear: "2025-2026", semester: ExamPaperSemesterFirst, examType: ExamPaperTypeFinal},
		{name: "学年不连续", courseName: "高等数学", academicYear: "2025-2027", semester: ExamPaperSemesterFirst, examType: ExamPaperTypeFinal},
		{name: "学年格式错误", courseName: "高等数学", academicYear: "2025/2026", semester: ExamPaperSemesterFirst, examType: ExamPaperTypeFinal},
		{name: "学期非法", courseName: "高等数学", academicYear: "2025-2026", semester: ExamPaperSemester("third"), examType: ExamPaperTypeFinal},
		{name: "考试类型非法", courseName: "高等数学", academicYear: "2025-2026", semester: ExamPaperSemesterFirst, examType: ExamPaperType("quiz")},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := NormalizeExamPaperMetadata(tt.courseName, tt.academicYear, tt.semester, tt.examType); err == nil {
				t.Fatal("预期返回元数据校验错误")
			}
		})
	}
}

func TestEnsureExamPaperIndexesOnlyBlocksActiveDuplicateHashes(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{TranslateError: true})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&User{}, &ExamPaper{}); err != nil {
		t.Fatalf("迁移测试数据库失败: %v", err)
	}
	if err := EnsureExamPaperIndexes(db); err != nil {
		t.Fatalf("创建试卷索引失败: %v", err)
	}

	user := User{StudentID: "exam-index-user", PasswordHash: "test", Nickname: "投稿人"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}

	base := ExamPaper{
		Source:       ExamPaperSourceUser,
		SubmitterID:  user.ID,
		CourseName:   "高等数学",
		AcademicYear: "2025-2026",
		Semester:     ExamPaperSemesterFirst,
		ExamType:     ExamPaperTypeFinal,
		Title:        "高等数学 · 2025-2026 · 第一学期 · 期末",
		FileKey:      "first.pdf",
		FileSize:     128,
		SHA256:       "same-hash",
	}

	pending := base
	pending.Status = ExamPaperStatusPending
	if err := db.Create(&pending).Error; err != nil {
		t.Fatalf("创建待审核试卷失败: %v", err)
	}

	published := base
	published.Status = ExamPaperStatusPublished
	published.FileKey = "second.pdf"
	if err := db.Create(&published).Error; err == nil {
		t.Fatal("相同哈希的待审核/已发布记录应被部分唯一索引拒绝")
	}

	unpublished := base
	unpublished.Status = ExamPaperStatusUnpublished
	unpublished.FileKey = ""
	if err := db.Create(&unpublished).Error; err != nil {
		t.Fatalf("已下架记录不应阻止相同哈希再次保存: %v", err)
	}
}
