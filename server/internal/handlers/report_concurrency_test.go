package handlers

import (
	"bytes"
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	_ "github.com/jackc/pgx/v5/stdlib"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestHandleReportPostgresSerializesConcurrentHandling(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := openReportConcurrencyPostgres(t)

	reporter := models.User{
		StudentID:    "report-concurrency-reporter",
		PasswordHash: "hash",
		Nickname:     "Reporter",
		Role:         models.RoleUser,
	}
	owner := models.User{
		StudentID:    "report-concurrency-owner",
		PasswordHash: "hash",
		Nickname:     "Owner",
		Role:         models.RoleUser,
	}
	admin := models.User{
		StudentID:    "report-concurrency-admin",
		PasswordHash: "hash",
		Nickname:     "Admin",
		Role:         models.RoleAdmin,
	}
	for _, user := range []*models.User{&reporter, &owner, &admin} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("创建测试用户失败: %v", err)
		}
	}

	teacher := models.Teacher{Name: "并发测试教师", Course: "并发测试课程", Verified: true}
	if err := db.Create(&teacher).Error; err != nil {
		t.Fatalf("创建测试教师失败: %v", err)
	}
	rating := models.TeacherRating{
		TeacherID: teacher.ID,
		UserID:    owner.ID,
		Star:      1,
		Comment:   "需要审核",
		Status:    "normal",
	}
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("创建测试评价失败: %v", err)
	}
	targetOwnerID := owner.ID
	report := models.Report{
		ReporterID:     reporter.ID,
		TargetType:     "teacher_rating",
		TargetID:       rating.ID,
		Reason:         "并发治理测试",
		TargetAuthorID: &targetOwnerID,
		Status:         models.ReportStatusPending,
	}
	if err := db.Create(&report).Error; err != nil {
		t.Fatalf("创建测试举报失败: %v", err)
	}

	handler := NewReportHandler(db)
	start := make(chan struct{})
	statuses := make(chan int, 2)
	var group sync.WaitGroup
	for range 2 {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			recorder := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(recorder)
			context.Set("user_id", admin.ID)
			context.Params = gin.Params{{
				Key:   "id",
				Value: strconv.FormatUint(uint64(report.ID), 10),
			}}
			context.Request = httptest.NewRequest(
				http.MethodPost,
				fmt.Sprintf("/api/admin/reports/%d/handle", report.ID),
				bytes.NewBufferString(`{"status":"handled","delete_reason":"违反社区规则"}`),
			)
			context.Request.Header.Set("Content-Type", "application/json")
			handler.Handle(context)
			statuses <- recorder.Code
		}()
	}
	close(start)
	group.Wait()
	close(statuses)

	gotStatuses := make([]int, 0, 2)
	for status := range statuses {
		gotStatuses = append(gotStatuses, status)
	}
	sort.Ints(gotStatuses)
	if want := []int{http.StatusOK, http.StatusConflict}; !equalInts(gotStatuses, want) {
		t.Fatalf("并发处理状态=%v，期望一次成功一次冲突", gotStatuses)
	}

	var storedReport models.Report
	if err := db.First(&storedReport, report.ID).Error; err != nil {
		t.Fatalf("读取处理后的举报失败: %v", err)
	}
	if storedReport.Status != models.ReportStatusHandled {
		t.Fatalf("举报状态=%q，期望 handled", storedReport.Status)
	}
	var storedRating models.TeacherRating
	if err := db.First(&storedRating, rating.ID).Error; err != nil {
		t.Fatalf("读取处理后的评价失败: %v", err)
	}
	if storedRating.Status != "hidden" {
		t.Fatalf("评价状态=%q，期望 hidden", storedRating.Status)
	}
	var storedOwner models.User
	if err := db.First(&storedOwner, owner.ID).Error; err != nil {
		t.Fatalf("读取被举报用户失败: %v", err)
	}
	if storedOwner.ReportCount != 1 {
		t.Fatalf("被举报用户 report_count=%d，期望 1", storedOwner.ReportCount)
	}
	var storedAdmin models.User
	if err := db.First(&storedAdmin, admin.ID).Error; err != nil {
		t.Fatalf("读取管理员失败: %v", err)
	}
	if storedAdmin.AdminExp != 1 {
		t.Fatalf("管理员 admin_exp=%d，期望 1", storedAdmin.AdminExp)
	}
	var actionCount int64
	if err := db.Model(&models.AdminActionLog{}).
		Where("action = ? AND target_id = ?", "handle_report", report.ID).
		Count(&actionCount).Error; err != nil {
		t.Fatalf("统计管理员操作日志失败: %v", err)
	}
	if actionCount != 1 {
		t.Fatalf("管理员操作日志数量=%d，期望 1", actionCount)
	}
}

func openReportConcurrencyPostgres(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("TEST_POSTGRES_DSN"))
	if dsn == "" {
		t.Skip("未配置 TEST_POSTGRES_DSN，跳过举报 PostgreSQL 并发集成测试")
	}

	adminDB, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("打开 PostgreSQL 测试数据库失败: %v", err)
	}
	adminDB.SetMaxOpenConns(1)
	adminDB.SetMaxIdleConns(1)
	if err := adminDB.Ping(); err != nil {
		adminDB.Close()
		t.Fatalf("连接 PostgreSQL 测试数据库失败: %v", err)
	}

	schema := fmt.Sprintf("report_concurrency_%d_%d", os.Getpid(), time.Now().UnixNano())
	quotedSchema := `"` + schema + `"`
	if _, err := adminDB.Exec("CREATE SCHEMA " + quotedSchema); err != nil {
		adminDB.Close()
		t.Fatalf("创建举报并发测试 schema 失败: %v", err)
	}

	var testSQLDB *sql.DB
	t.Cleanup(func() {
		if testSQLDB != nil {
			_ = testSQLDB.Close()
		}
		if _, err := adminDB.Exec("DROP SCHEMA IF EXISTS " + quotedSchema + " CASCADE"); err != nil {
			t.Errorf("清理举报并发测试 schema 失败: %v", err)
		}
		_ = adminDB.Close()
	})

	db, err := gorm.Open(postgres.Open(withReportConcurrencySearchPath(dsn, schema)), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开举报并发 GORM 数据库失败: %v", err)
	}
	testSQLDB, err = db.DB()
	if err != nil {
		t.Fatalf("读取举报并发数据库连接池失败: %v", err)
	}
	testSQLDB.SetMaxOpenConns(8)
	testSQLDB.SetMaxIdleConns(8)
	if err := db.AutoMigrate(
		&models.User{},
		&models.Teacher{},
		&models.TeacherRating{},
		&models.Report{},
		&models.AdminActionLog{},
	); err != nil {
		t.Fatalf("迁移举报并发测试表失败: %v", err)
	}
	return db
}

func withReportConcurrencySearchPath(dsn, schema string) string {
	option := "-c search_path=" + schema + ",public"
	if strings.Contains(dsn, "://") {
		parsed, err := url.Parse(dsn)
		if err == nil {
			query := parsed.Query()
			query.Set("options", option)
			parsed.RawQuery = query.Encode()
			return parsed.String()
		}
	}
	return strings.TrimSpace(dsn) + " options='" + option + "'"
}

func equalInts(left, right []int) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
