package config

import "testing"

func TestLoadExamPaperDirDefaultsByEnvironmentAndAllowsOverride(t *testing.T) {
	t.Setenv("JWT_SECRET", "test-secret")
	t.Setenv("SUPER_ADMIN_ID", "root-admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "test-password")
	t.Setenv("GIN_MODE", "release")
	t.Setenv("EXAM_PAPER_DIR", "")
	production := Load()
	if production.ExamPaperDir != "/opt/shenliyuan/private/exam-papers" {
		t.Fatalf("生产默认私有目录错误: %q", production.ExamPaperDir)
	}

	t.Setenv("EXAM_PAPER_DIR", "/srv/private/papers")
	overridden := Load()
	if overridden.ExamPaperDir != "/srv/private/papers" {
		t.Fatalf("EXAM_PAPER_DIR 覆盖失败: %q", overridden.ExamPaperDir)
	}
}

func TestLoadReleaseRejectsPlaceholderSecrets(t *testing.T) {
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "your-super-secret-jwt-key-change-this")
	t.Setenv("SUPER_ADMIN_ID", "admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "change_me_in_env")

	assertLoadPanics(t)
}

func TestLoadReleaseRejectsExamPaperDirInsidePublicUploads(t *testing.T) {
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "realistic-release-secret")
	t.Setenv("SUPER_ADMIN_ID", "admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "realistic-admin-password")
	t.Setenv("UPLOAD_DIR", "/opt/shenliyuan/uploads")
	t.Setenv("EXAM_PAPER_DIR", "/opt/shenliyuan/uploads/exam-papers")

	assertLoadPanics(t)
}

func assertLoadPanics(t *testing.T) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatal("Load() 应该拒绝不安全的生产配置")
		}
	}()
	_ = Load()
}
