//go:build integration

package handlers

import (
	"bytes"
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func openFeedbackTicketPG(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("TEST_DATABASE_DSN"))
	if dsn == "" {
		requireIntegrationEnv(t, "TEST_DATABASE_DSN 未设置，跳过反馈工单 PostgreSQL 并发集成测试")
	}

	adminDB, err := sql.Open("pgx", dsn)
	require.NoError(t, err)
	adminDB.SetMaxOpenConns(1)
	adminDB.SetMaxIdleConns(1)
	require.NoError(t, adminDB.Ping())

	schema := fmt.Sprintf("feedback_ticket_%d_%d", os.Getpid(), time.Now().UnixNano())
	quotedSchema := `"` + schema + `"`
	_, err = adminDB.Exec("CREATE SCHEMA " + quotedSchema)
	require.NoError(t, err)

	db, err := gorm.Open(postgres.Open(withFeedbackTicketSearchPath(dsn, schema)), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(16)
	sqlDB.SetMaxIdleConns(16)

	t.Cleanup(func() {
		_ = sqlDB.Close()
		if _, err := adminDB.Exec("DROP SCHEMA IF EXISTS " + quotedSchema + " CASCADE"); err != nil {
			t.Errorf("清理反馈工单测试 schema 失败: %v", err)
		}
		_ = adminDB.Close()
	})

	require.NoError(t, db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.Notification{},
		&models.FeedbackTicket{},
		&models.FeedbackMessage{},
		&models.FeedbackAttachment{},
		&models.FeedbackStatusHistory{},
	))
	requireIntegrationTestDatabase(t, db)
	return db
}

func withFeedbackTicketSearchPath(dsn, schema string) string {
	option := "-c search_path=" + schema + ",public"
	parsed, err := url.Parse(dsn)
	if err == nil && parsed.Scheme != "" {
		query := parsed.Query()
		query.Set("options", option)
		parsed.RawQuery = query.Encode()
		return parsed.String()
	}
	return strings.TrimSpace(dsn) + " options='" + option + "'"
}

func seedFeedbackTicketPGUser(t *testing.T, db *gorm.DB, suffix string) models.User {
	t.Helper()
	user := models.User{
		StudentID:    "feedback-pg-" + suffix,
		PasswordHash: "hash",
		Nickname:     "反馈并发用户-" + suffix,
		Role:         models.RoleUser,
	}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func createFeedbackTicketPGRequest(
	handler *FeedbackTicketHandler,
	userID uint,
	seed string,
) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodPost,
		"/api/feedback/tickets",
		bytes.NewBufferString(fmt.Sprintf(
			`{"type":"bug","title":"并发工单-%s","description":"测试同账号频控"}`,
			seed,
		)),
	)
	context.Request.Header.Set("Content-Type", "application/json")
	context.Set("user_id", userID)
	handler.CreateTicket(context)
	return recorder
}

func feedbackTicketUserRequest(
	handler *FeedbackTicketHandler,
	method string,
	path string,
	userID uint,
	body string,
) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	router := gin.New()
	router.Use(func(context *gin.Context) {
		context.Set("user_id", userID)
		context.Next()
	})
	router.POST("/api/feedback/tickets/:id/messages", handler.AddMessage)
	router.POST("/api/feedback/tickets/:id/confirm-resolved", handler.ConfirmResolved)
	request := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, request)
	return recorder
}

func TestFeedbackTicketCreateRateLimitPostgres(t *testing.T) {
	db := openFeedbackTicketPG(t)
	user := seedFeedbackTicketPGUser(t, db, "create")
	now := time.Now()
	for index := 0; index < maxUserHourlyTickets-1; index++ {
		ticket := models.FeedbackTicket{
			TicketNo:    fmt.Sprintf("SYPG%04d", index),
			UserID:      user.ID,
			Type:        models.FeedbackTypeBug,
			Title:       "历史工单",
			Description: "占用频控额度",
			Status:      models.FeedbackStatusPending,
			CreatedAt:   now,
			UpdatedAt:   now,
		}
		require.NoError(t, db.Create(&ticket).Error)
	}

	handler := NewFeedbackTicketHandler(db, t.TempDir(), nil)
	const concurrency = 8
	start := make(chan struct{})
	responses := make(chan *httptest.ResponseRecorder, concurrency)
	var group sync.WaitGroup
	for index := 0; index < concurrency; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			<-start
			responses <- createFeedbackTicketPGRequest(handler, user.ID, strconv.Itoa(index))
		}(index)
	}
	close(start)
	group.Wait()
	close(responses)

	created, limited := 0, 0
	for response := range responses {
		switch response.Code {
		case http.StatusCreated:
			created++
		case http.StatusTooManyRequests:
			limited++
		default:
			t.Fatalf("并发创建工单返回异常状态 %d: %s", response.Code, response.Body.String())
		}
	}
	require.Equal(t, 1, created)
	require.Equal(t, concurrency-1, limited)

	var total int64
	require.NoError(t, db.Model(&models.FeedbackTicket{}).
		Where("user_id = ? AND created_at >= ?", user.ID, now.Add(-time.Hour)).
		Count(&total).Error)
	require.EqualValues(t, maxUserHourlyTickets, total)
}

func TestFeedbackTicketMessageClosePostgres(t *testing.T) {
	db := openFeedbackTicketPG(t)
	user := seedFeedbackTicketPGUser(t, db, "message-close")
	now := time.Now()
	ticket := models.FeedbackTicket{
		TicketNo:    "SYPGCLOSE",
		UserID:      user.ID,
		Type:        models.FeedbackTypeBug,
		Title:       "消息与关闭竞争",
		Description: "验证同一工单行锁",
		Status:      models.FeedbackStatusResolved,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	require.NoError(t, db.Create(&ticket).Error)

	handler := NewFeedbackTicketHandler(db, t.TempDir(), nil)
	start := make(chan struct{})
	responses := make(chan int, 2)
	var group sync.WaitGroup
	group.Add(2)
	go func() {
		defer group.Done()
		<-start
		response := feedbackTicketUserRequest(
			handler,
			http.MethodPost,
			fmt.Sprintf("/api/feedback/tickets/%d/messages", ticket.ID),
			user.ID,
			`{"content":"补充复现信息"}`,
		)
		responses <- response.Code
	}()
	go func() {
		defer group.Done()
		<-start
		response := feedbackTicketUserRequest(
			handler,
			http.MethodPost,
			fmt.Sprintf("/api/feedback/tickets/%d/confirm-resolved", ticket.ID),
			user.ID,
			"",
		)
		responses <- response.Code
	}()
	close(start)
	group.Wait()
	close(responses)

	statuses := make([]int, 0, 2)
	for status := range responses {
		statuses = append(statuses, status)
	}
	require.Len(t, statuses, 2)
	for _, status := range statuses {
		require.Contains(t, []int{http.StatusOK, http.StatusConflict}, status)
	}
	require.Contains(t, statuses, http.StatusOK)

	var stored models.FeedbackTicket
	require.NoError(t, db.First(&stored, ticket.ID).Error)
	require.Equal(t, models.FeedbackStatusClosed, stored.Status)
	var userMessages int64
	require.NoError(t, db.Model(&models.FeedbackMessage{}).
		Where("ticket_id = ? AND sender_type = ?", ticket.ID, "user").
		Count(&userMessages).Error)
	require.LessOrEqual(t, userMessages, int64(1))
	var historyCount int64
	require.NoError(t, db.Model(&models.FeedbackStatusHistory{}).
		Where("ticket_id = ?", ticket.ID).
		Count(&historyCount).Error)
	require.EqualValues(t, 1, historyCount)
}
