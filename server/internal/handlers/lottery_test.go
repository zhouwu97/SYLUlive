package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newLotteryHandlerTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.LotteryEvent{},
		&models.LotteryParticipant{},
		&models.Announcement{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func performJSONRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	body map[string]any,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, bytes.NewReader(payload))
	context.Request.Header.Set("Content-Type", "application/json")
	handler(context)
	return recorder
}

func TestCreateLotteryEventPublishesNewCurrentEventAndClosesOldOne(t *testing.T) {
	db := newLotteryHandlerTestDB(t)
	handler := NewSuperAdminHandler(db)

	oldEvent := models.LotteryEvent{
		Title:       "旧活动",
		Description: "旧说明",
		PrizeName:   "旧奖品",
		DrawTime:    time.Now().Add(time.Hour),
		Status:      0,
	}
	if err := db.Create(&oldEvent).Error; err != nil {
		t.Fatalf("create old event: %v", err)
	}

	drawTime := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	recorder := performJSONRequest(t, handler.CreateLotteryEvent, http.MethodPost, "/api/super/lottery", map[string]any{
		"title":       "图片事故补偿抽奖",
		"description": "感谢理解",
		"prize_name":  "奶茶券",
		"draw_time":   drawTime,
	})
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var updatedOld models.LotteryEvent
	if err := db.First(&updatedOld, oldEvent.ID).Error; err != nil {
		t.Fatalf("load old event: %v", err)
	}
	if updatedOld.Status != 1 {
		t.Fatalf("expected old event closed, got status %d", updatedOld.Status)
	}

	var created models.LotteryEvent
	if err := db.Where("title = ?", "图片事故补偿抽奖").First(&created).Error; err != nil {
		t.Fatalf("load created event: %v", err)
	}
	if created.Status != 0 {
		t.Fatalf("expected new event ongoing, got status %d", created.Status)
	}
}

func TestDeleteLotteryEventRemovesEventAndParticipants(t *testing.T) {
	db := newLotteryHandlerTestDB(t)
	handler := NewSuperAdminHandler(db)

	user := models.User{
		StudentID:    "delete-participant-001",
		PasswordHash: "test",
		Nickname:     "参与者",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	event := models.LotteryEvent{
		Title:       "待删除抽奖",
		Description: "测试删除",
		PrizeName:   "奖品",
		DrawTime:    time.Now().Add(time.Hour),
		Status:      0,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatalf("create event: %v", err)
	}

	if err := db.Create(&models.LotteryParticipant{
		LotteryID: event.ID,
		UserID:    user.ID,
		Weight:    1,
	}).Error; err != nil {
		t.Fatalf("create participant: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodDelete, "/api/super/lottery/1", nil)
	context.Params = gin.Params{{Key: "id", Value: "1"}}
	handler.DeleteLotteryEvent(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var eventCount int64
	if err := db.Model(&models.LotteryEvent{}).Where("id = ?", event.ID).Count(&eventCount).Error; err != nil {
		t.Fatalf("count events: %v", err)
	}
	if eventCount != 0 {
		t.Fatalf("expected event deleted, count=%d", eventCount)
	}

	var participantCount int64
	if err := db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&participantCount).Error; err != nil {
		t.Fatalf("count participants: %v", err)
	}
	if participantCount != 0 {
		t.Fatalf("expected participants deleted, count=%d", participantCount)
	}
}

func TestJoinLotteryRejectsAfterDrawTime(t *testing.T) {
	db := newLotteryHandlerTestDB(t)
	handler := NewLotteryHandler(db)

	user := models.User{
		StudentID:    "joiner-001",
		PasswordHash: "test",
		Nickname:     "参与者",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	event := models.LotteryEvent{
		Title:       "已到点活动",
		Description: "测试",
		PrizeName:   "奖品",
		DrawTime:    time.Now().Add(-time.Second),
		Status:      0,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatalf("create event: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/lottery/1/join", nil)
	context.Params = gin.Params{{Key: "id", Value: "1"}}
	context.Set("user_id", user.ID)
	handler.Join(context)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}
