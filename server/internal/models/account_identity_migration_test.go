package models

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func TestAccountIdentityMigrationPreservesLegacyQQAccounts(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("未配置 TEST_POSTGRES_DSN，跳过 PostgreSQL 迁移集成测试")
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("打开 PostgreSQL 测试数据库失败: %v", err)
	}
	defer db.Close()
	// 迁移脚本含有 BEGIN/COMMIT，固定为单连接以确保 search_path 全程指向隔离 schema。
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if err := db.Ping(); err != nil {
		t.Fatalf("连接 PostgreSQL 测试数据库失败: %v", err)
	}

	schema := fmt.Sprintf("account_identity_migration_%d", os.Getpid())
	if _, err := db.Exec("CREATE SCHEMA " + schema); err != nil {
		t.Fatalf("创建迁移测试 schema 失败: %v", err)
	}
	defer func() {
		if _, err := db.Exec("DROP SCHEMA " + schema + " CASCADE"); err != nil {
			t.Errorf("清理迁移测试 schema 失败: %v", err)
		}
	}()
	if _, err := db.Exec("SET search_path TO " + schema + ", public"); err != nil {
		t.Fatalf("设置迁移测试 schema 失败: %v", err)
	}

	createLegacyAccountIdentitySchema(t, db)
	seedLegacyAccountIdentityUsers(t, db)
	applyAccountIdentityMigration(t, db)

	assertLegacyQQMigration(t, db)
	assertStudentIdentityPartialUniqueIndex(t, db)
	assertEduBindingPendingStudentIDColumn(t, db)
}

func createLegacyAccountIdentitySchema(t *testing.T, db *sql.DB) {
	t.Helper()
	statements := []string{
		`CREATE TABLE users (
			id bigserial PRIMARY KEY,
			student_id varchar(20) NOT NULL,
			qq varchar(20) NOT NULL DEFAULT '',
			edu_student_id varchar(20) NOT NULL DEFAULT '',
			edu_bound boolean NOT NULL DEFAULT false,
			edu_password varchar(255) NOT NULL DEFAULT '',
			edu_cookie varchar(1000) NOT NULL DEFAULT '',
			created_at timestamptz NOT NULL DEFAULT now()
		)`,
		`CREATE UNIQUE INDEX idx_users_student_id ON users(student_id)`,
		`CREATE TABLE user_legal_consents (
			id bigserial PRIMARY KEY,
			user_id bigint NOT NULL REFERENCES users(id),
			document varchar(64) NOT NULL,
			version varchar(64) NOT NULL,
			scene varchar(64) NOT NULL DEFAULT ''
		)`,
		`CREATE UNIQUE INDEX idx_user_legal_document_version ON user_legal_consents(user_id, document, version)`,
		`CREATE TABLE edu_credential_cleanup_jobs (
			id bigserial PRIMARY KEY,
			user_id bigint NOT NULL REFERENCES users(id),
			attempts integer NOT NULL DEFAULT 0,
			next_attempt_at timestamptz NOT NULL DEFAULT now(),
			completed_at timestamptz,
			locked_at timestamptz,
			lock_token varchar(36) NOT NULL DEFAULT '',
			last_error varchar(1000) NOT NULL DEFAULT '',
			created_at timestamptz NOT NULL DEFAULT now(),
			updated_at timestamptz NOT NULL DEFAULT now()
		)`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("创建旧版迁移测试表失败: %v", err)
		}
	}
}

func seedLegacyAccountIdentityUsers(t *testing.T, db *sql.DB) {
	t.Helper()
	rows := []struct {
		studentID    string
		qq           string
		eduStudentID string
		eduBound     bool
	}{
		{studentID: "1000000001", qq: "1000000001"},
		{studentID: "1000000002", qq: "1000000002"},
		{studentID: "1000000003", qq: "1000000003", eduStudentID: "2026000001", eduBound: true},
		{studentID: "2026000002", eduStudentID: "2026000002", eduBound: true},
		{studentID: "2026000003", eduStudentID: "2026000003", eduBound: true},
	}
	for _, row := range rows {
		if _, err := db.Exec(
			`INSERT INTO users (student_id, qq, edu_student_id, edu_bound) VALUES ($1, $2, $3, $4)`,
			row.studentID,
			row.qq,
			row.eduStudentID,
			row.eduBound,
		); err != nil {
			t.Fatalf("写入旧版用户数据失败: %v", err)
		}
	}
}

func applyAccountIdentityMigration(t *testing.T, db *sql.DB) {
	t.Helper()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("定位迁移测试源文件失败")
	}
	migrationPath := filepath.Join(filepath.Dir(sourceFile), "..", "..", "sql", "20260722_account_identity_email_migration.sql")
	migration, err := os.ReadFile(migrationPath)
	if err != nil {
		t.Fatalf("读取账号身份迁移 SQL 失败: %v", err)
	}
	if _, err := db.Exec(string(migration)); err != nil {
		t.Fatalf("执行账号身份迁移失败: %v", err)
	}
}

func assertLegacyQQMigration(t *testing.T, db *sql.DB) {
	t.Helper()
	type migratedUser struct {
		studentID        string
		email            string
		studentVerified  bool
		eduAuthorized    bool
		eduSessionState  string
		authorizationGen int
	}
	loadUser := func(qq string) migratedUser {
		t.Helper()
		var user migratedUser
		err := db.QueryRow(
			`SELECT student_id, email, student_verified_at IS NOT NULL, edu_authorized, edu_session_state, edu_authorization_generation
			 FROM users WHERE qq = $1`,
			qq,
		).Scan(
			&user.studentID,
			&user.email,
			&user.studentVerified,
			&user.eduAuthorized,
			&user.eduSessionState,
			&user.authorizationGen,
		)
		if err != nil {
			t.Fatalf("读取迁移后的 QQ 用户失败: %v", err)
		}
		return user
	}

	for _, qq := range []string{"1000000001", "1000000002"} {
		user := loadUser(qq)
		if user.studentID != "" || user.studentVerified || user.eduAuthorized || user.eduSessionState != "unbound" {
			t.Fatalf("未绑定教务的 QQ 用户迁移状态错误: qq=%s, user=%+v", qq, user)
		}
		if user.email != qq+"@qq.com" {
			t.Fatalf("未绑定教务的 QQ 用户邮箱错误: qq=%s, email=%s", qq, user.email)
		}
	}

	boundQQ := loadUser("1000000003")
	if boundQQ.studentID != "2026000001" || !boundQQ.studentVerified || !boundQQ.eduAuthorized || boundQQ.eduSessionState != "active" || boundQQ.authorizationGen != 1 {
		t.Fatalf("已绑定教务的 QQ 用户迁移状态错误: %+v", boundQQ)
	}
	if boundQQ.email != "1000000003@qq.com" {
		t.Fatalf("已绑定教务的 QQ 用户邮箱错误: %s", boundQQ.email)
	}

	for _, studentID := range []string{"2026000002", "2026000003"} {
		var migratedID string
		if err := db.QueryRow(`SELECT student_id FROM users WHERE student_id = $1`, studentID).Scan(&migratedID); err != nil {
			t.Fatalf("普通学号用户未被正确保留: student_id=%s, err=%v", studentID, err)
		}
	}
}

func assertStudentIdentityPartialUniqueIndex(t *testing.T, db *sql.DB) {
	t.Helper()
	for index := 0; index < 2; index++ {
		if _, err := db.Exec(
			`INSERT INTO users (student_id, email, email_verified_at) VALUES ('', $1, now())`,
			fmt.Sprintf("identity-index-%d@example.com", index),
		); err != nil {
			t.Fatalf("部分唯一索引应允许多个空学号: %v", err)
		}
	}
	if _, err := db.Exec(
		`INSERT INTO users (student_id, email, email_verified_at) VALUES ('2026000002', 'identity-index-duplicate@example.com', now())`,
	); err == nil {
		t.Fatal("部分唯一索引应拒绝重复的非空学号")
	}
}

func assertEduBindingPendingStudentIDColumn(t *testing.T, db *sql.DB) {
	t.Helper()
	var nullable string
	var defaultValue sql.NullString
	err := db.QueryRow(`
		SELECT is_nullable, column_default
		FROM information_schema.columns
		WHERE table_schema = current_schema()
		  AND table_name = 'users'
		  AND column_name = 'edu_binding_pending_student_id'
	`).Scan(&nullable, &defaultValue)
	if err != nil {
		t.Fatalf("迁移未创建待绑定教务学号字段: %v", err)
	}
	if nullable != "NO" || !defaultValue.Valid || defaultValue.String == "" {
		t.Fatalf("待绑定教务学号字段约束错误: nullable=%s default=%q", nullable, defaultValue.String)
	}
}
