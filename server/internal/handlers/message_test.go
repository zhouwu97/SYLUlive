package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newMessageTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.Conversation{},
		&models.Message{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func createMessageTestUser(t *testing.T, db *gorm.DB, id uint, nickname string) models.User {
	t.Helper()
	user := models.User{
		ID:           id,
		StudentID:    fmt.Sprintf("student-%d", id),
		PasswordHash: "test",
		Nickname:     nickname,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func performMessageRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	params gin.Params,
	userID uint,
	body string,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = params
	context.Set("user_id", userID)
	handler(context)
	return recorder
}

func TestMessageSendValidatesInputAndCreatesSingleConversation(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	handler := NewMessageHandler(db)

	empty := performMessageRequest(
		t,
		handler.Send,
		http.MethodPost,
		"/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}},
		1,
		`{"content":"   "}`,
	)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("empty message status=%d body=%s", empty.Code, empty.Body.String())
	}

	missingUser := performMessageRequest(
		t,
		handler.Send,
		http.MethodPost,
		"/api/messages/999",
		gin.Params{{Key: "user_id", Value: "999"}},
		1,
		`{"content":"hello"}`,
	)
	if missingUser.Code != http.StatusNotFound {
		t.Fatalf("missing target status=%d body=%s", missingUser.Code, missingUser.Body.String())
	}

	for _, sender := range []struct {
		from uint
		to   string
	}{
		{from: 1, to: "2"},
		{from: 2, to: "1"},
	} {
		response := performMessageRequest(
			t,
			handler.Send,
			http.MethodPost,
			"/api/messages/"+sender.to,
			gin.Params{{Key: "user_id", Value: sender.to}},
			sender.from,
			`{"content":" hello "}`,
		)
		if response.Code != http.StatusCreated {
			t.Fatalf("send status=%d body=%s", response.Code, response.Body.String())
		}
	}

	var conversationCount int64
	db.Model(&models.Conversation{}).Count(&conversationCount)
	if conversationCount != 1 {
		t.Fatalf("conversation count=%d want=1", conversationCount)
	}

	var messages []models.Message
	db.Order("id ASC").Find(&messages)
	if len(messages) != 2 || messages[0].Content != "hello" {
		t.Fatalf("unexpected messages: %#v", messages)
	}
}

func TestMessageConversationSummaryPaginationAndRead(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	handler := NewMessageHandler(db)

	conversation := models.Conversation{
		User1ID:       1,
		User2ID:       2,
		LastMessageAt: time.Now(),
	}
	if err := db.Create(&conversation).Error; err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	for i := 1; i <= 5; i++ {
		message := models.Message{
			ConversationID: conversation.ID,
			SenderID:       2,
			Content:        fmt.Sprintf("message-%d", i),
		}
		if err := db.Create(&message).Error; err != nil {
			t.Fatalf("create message: %v", err)
		}
	}

	list := performMessageRequest(
		t,
		handler.GetConversations,
		http.MethodGet,
		"/api/messages/conversations",
		nil,
		1,
		"",
	)
	if list.Code != http.StatusOK {
		t.Fatalf("conversation list status=%d body=%s", list.Code, list.Body.String())
	}
	var conversations []struct {
		UnreadCount int64          `json:"unread_count"`
		LastMessage models.Message `json:"last_message"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &conversations); err != nil {
		t.Fatalf("decode conversations: %v", err)
	}
	if len(conversations) != 1 ||
		conversations[0].UnreadCount != 5 ||
		conversations[0].LastMessage.Content != "message-5" {
		t.Fatalf("unexpected conversation response: %s", list.Body.String())
	}

	page := performMessageRequest(
		t,
		handler.GetMessages,
		http.MethodGet,
		fmt.Sprintf("/api/messages/conversations/%d?limit=2", conversation.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(conversation.ID)}},
		1,
		"",
	)
	if page.Code != http.StatusOK {
		t.Fatalf("message page status=%d body=%s", page.Code, page.Body.String())
	}
	var messages []models.Message
	if err := json.Unmarshal(page.Body.Bytes(), &messages); err != nil {
		t.Fatalf("decode messages: %v", err)
	}
	if len(messages) != 2 || messages[0].Content != "message-4" || messages[1].Content != "message-5" {
		t.Fatalf("unexpected page: %s", page.Body.String())
	}

	read := performMessageRequest(
		t,
		handler.MarkRead,
		http.MethodPost,
		fmt.Sprintf("/api/messages/conversations/%d/read", conversation.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(conversation.ID)}},
		1,
		"",
	)
	if read.Code != http.StatusOK {
		t.Fatalf("mark read status=%d body=%s", read.Code, read.Body.String())
	}
	var unread int64
	db.Model(&models.Message{}).
		Where("conversation_id = ? AND sender_id != ? AND read_at IS NULL", conversation.ID, 1).
		Count(&unread)
	if unread != 0 {
		t.Fatalf("unread count=%d want=0", unread)
	}

	unreadResponse := performMessageRequest(
		t,
		handler.GetUnreadCount,
		http.MethodGet,
		"/api/messages/unread_count",
		nil,
		1,
		"",
	)
	if unreadResponse.Code != http.StatusOK ||
		!strings.Contains(unreadResponse.Body.String(), `"count":0`) {
		t.Fatalf("unread response status=%d body=%s",
			unreadResponse.Code, unreadResponse.Body.String())
	}
}
