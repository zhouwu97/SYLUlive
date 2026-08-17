package handlers

import (
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

func TestGetUnreadReplyNotifications(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Post{}, &models.Notification{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	now := time.Now().UTC()
	users := []models.User{
		{ID: 1, Nickname: "当前用户"},
		{ID: 2, Nickname: "回复者A", Avatar: "a.png"},
		{ID: 3, Nickname: "回复者B", Avatar: "b.png"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatalf("写入用户失败: %v", err)
	}
	posts := []models.Post{{ID: 100, Title: "第一篇帖子"}, {ID: 101, Title: "第二篇帖子"}}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatalf("写入帖子失败: %v", err)
	}
	notifications := []models.Notification{
		{ID: 1, UserID: 1, Type: "reply", Content: "较早回复", PostID: 100, RelatedID: 501, FromUID: 2, IsRead: false, CreatedAt: now.Add(-2 * time.Hour)},
		{ID: 2, UserID: 1, Type: "reply", Content: "最新回复", PostID: 101, RelatedID: 502, FromUID: 3, IsRead: false, CreatedAt: now.Add(-time.Hour)},
		{ID: 3, UserID: 1, Type: "reply", Content: "已读回复", PostID: 100, RelatedID: 503, FromUID: 2, IsRead: true, CreatedAt: now},
		{ID: 4, UserID: 1, Type: "like", Content: "点赞", PostID: 100, RelatedID: 504, FromUID: 3, IsRead: false, CreatedAt: now},
		{ID: 5, UserID: 2, Type: "reply", Content: "其他用户回复", PostID: 100, RelatedID: 505, FromUID: 1, IsRead: false, CreatedAt: now},
	}
	if err := db.Create(&notifications).Error; err != nil {
		t.Fatalf("写入通知失败: %v", err)
	}

	gin.SetMode(gin.TestMode)
	handler := NewNotificationHandler(db)
	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(http.MethodGet, "/notifications/replies/unread?limit=1", nil)
	ctx.Set("user_id", uint(1))
	handler.GetUnreadReplyNotifications(ctx)
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码=%d，响应=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Count int `json:"count"`
		Items []struct {
			ID        uint   `json:"id"`
			PostID    uint   `json:"post_id"`
			RelatedID uint   `json:"related_id"`
			Content   string `json:"content"`
			PostTitle string `json:"post_title"`
			CreatedAt string `json:"created_at"`
			FromUser  struct {
				ID       uint   `json:"id"`
				Nickname string `json:"nickname"`
				Avatar   string `json:"avatar"`
			} `json:"from_user"`
		} `json:"items"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析响应失败: %v", err)
	}
	if response.Count != 2 || len(response.Items) != 1 {
		t.Fatalf("响应 count/items=%d/%d，期望 2/1: %s", response.Count, len(response.Items), recorder.Body.String())
	}
	item := response.Items[0]
	if item.ID != 2 || item.PostID != 101 || item.RelatedID != 502 || item.Content != "最新回复" || item.PostTitle != "第二篇帖子" || item.FromUser.ID != 3 || item.FromUser.Nickname != "回复者B" || item.FromUser.Avatar != "b.png" || item.CreatedAt == "" {
		t.Fatalf("返回条目不符合预期: %+v", item)
	}
}
