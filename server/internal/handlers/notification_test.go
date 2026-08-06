package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestReplyPushExtrasIncludesRecipient(t *testing.T) {
	extras := replyPushExtras(7, 11, 13)

	if extras["type"] != "reply" ||
		extras["recipient_user_id"] != uint(7) ||
		extras["reply_id"] != uint(11) ||
		extras["post_id"] != uint(13) {
		t.Fatalf("回复推送参数不完整: %#v", extras)
	}
}

func TestNotificationHandlerExcludesRetiredMarketPostNotifications(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.Notification{}); err != nil {
		t.Fatalf("迁移通知表失败: %v", err)
	}
	if err := db.Create(&[]models.Notification{
		{UserID: 1, Type: "reply", Content: "回复内容"},
		{UserID: 1, Type: models.RetiredNotificationTypeMarketPost, Content: "商品内容"},
	}).Error; err != nil {
		t.Fatalf("写入通知失败: %v", err)
	}

	gin.SetMode(gin.TestMode)
	handler := NewNotificationHandler(db)

	listRecorder := httptest.NewRecorder()
	listContext, _ := gin.CreateTestContext(listRecorder)
	listContext.Request = httptest.NewRequest(http.MethodGet, "/notifications", nil)
	listContext.Set("user_id", uint(1))
	handler.GetNotifications(listContext)
	if listRecorder.Code != http.StatusOK {
		t.Fatalf("通知列表状态码=%d，响应=%s", listRecorder.Code, listRecorder.Body.String())
	}
	var notifications []models.Notification
	if err := json.Unmarshal(listRecorder.Body.Bytes(), &notifications); err != nil {
		t.Fatalf("解析通知列表失败: %v", err)
	}
	if len(notifications) != 1 || notifications[0].Type != "reply" {
		t.Fatalf("通知列表=%+v，期望仅包含回复通知", notifications)
	}

	countRecorder := httptest.NewRecorder()
	countContext, _ := gin.CreateTestContext(countRecorder)
	countContext.Request = httptest.NewRequest(http.MethodGet, "/notifications/unread-count", nil)
	countContext.Set("user_id", uint(1))
	handler.GetUnreadCount(countContext)
	if countRecorder.Code != http.StatusOK {
		t.Fatalf("未读数状态码=%d，响应=%s", countRecorder.Code, countRecorder.Body.String())
	}
	var unread struct {
		Count int64 `json:"count"`
	}
	if err := json.Unmarshal(countRecorder.Body.Bytes(), &unread); err != nil {
		t.Fatalf("解析未读数失败: %v", err)
	}
	if unread.Count != 1 {
		t.Fatalf("未读数=%d，期望=1", unread.Count)
	}
}
