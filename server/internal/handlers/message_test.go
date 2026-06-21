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

type fakeMessageNotifier struct {
	calls chan fakeMessageNotifyCall
}

type fakeMessageNotifyCall struct {
	UserID  uint
	Title   string
	Content string
	Extras  map[string]interface{}
}

func newFakeMessageNotifier() *fakeMessageNotifier {
	return &fakeMessageNotifier{calls: make(chan fakeMessageNotifyCall, 4)}
}

func (n *fakeMessageNotifier) Notify(userID uint, title, content string, extras map[string]interface{}) error {
	n.calls <- fakeMessageNotifyCall{
		UserID:  userID,
		Title:   title,
		Content: content,
		Extras:  extras,
	}
	return nil
}

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
	if strings.Contains(list.Body.String(), "student_id") {
		t.Fatalf("conversation summary leaked full user fields: %s", list.Body.String())
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

	afterPage := performMessageRequest(
		t,
		handler.GetMessages,
		http.MethodGet,
		fmt.Sprintf("/api/messages/conversations/%d?limit=10&after_id=2&before_id=5", conversation.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(conversation.ID)}},
		1,
		"",
	)
	if afterPage.Code != http.StatusOK {
		t.Fatalf("after page status=%d body=%s", afterPage.Code, afterPage.Body.String())
	}
	var afterMessages []models.Message
	if err := json.Unmarshal(afterPage.Body.Bytes(), &afterMessages); err != nil {
		t.Fatalf("decode after messages: %v", err)
	}
	if len(afterMessages) != 3 ||
		afterMessages[0].Content != "message-3" ||
		afterMessages[2].Content != "message-5" {
		t.Fatalf("unexpected after page: %s", afterPage.Body.String())
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

func TestMessageSendRateLimit(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	handler := NewMessageHandler(db)

	for i := 0; i < maxPairMessagesPerMin; i++ {
		response := performMessageRequest(
			t,
			handler.Send,
			http.MethodPost,
			"/api/messages/2",
			gin.Params{{Key: "user_id", Value: "2"}},
			1,
			fmt.Sprintf(`{"content":"hello-%d"}`, i),
		)
		if response.Code != http.StatusCreated {
			t.Fatalf("send %d status=%d body=%s", i, response.Code, response.Body.String())
		}
	}

	limited := performMessageRequest(
		t,
		handler.Send,
		http.MethodPost,
		"/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}},
		1,
		`{"content":"too much"}`,
	)
	if limited.Code != http.StatusTooManyRequests {
		t.Fatalf("limited status=%d body=%s", limited.Code, limited.Body.String())
	}
}

func TestMessageSendImageResponseAndPush(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	file := models.File{
		Hash:     "image-hash",
		Path:     "/uploads/image.png",
		Size:     128,
		MimeType: "image/png",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}
	notifier := newFakeMessageNotifier()
	handler := NewMessageHandler(db, notifier)

	response := performMessageRequest(
		t,
		handler.Send,
		http.MethodPost,
		"/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}},
		1,
		fmt.Sprintf(`{"content":"","file_id":%d}`, file.ID),
	)
	if response.Code != http.StatusCreated {
		t.Fatalf("send image status=%d body=%s", response.Code, response.Body.String())
	}
	var message models.Message
	if err := json.Unmarshal(response.Body.Bytes(), &message); err != nil {
		t.Fatalf("decode image message: %v", err)
	}
	if message.File == nil || message.File.Path != file.Path {
		t.Fatalf("expected response to include image file: %s", response.Body.String())
	}

	select {
	case call := <-notifier.calls:
		if call.UserID != 2 || call.Title != "Alice" || call.Content != "[图片]" {
			t.Fatalf("unexpected push call: %#v", call)
		}
		conversationID := call.Extras["conversation_id"]
		if call.Extras["type"] != "private_message" ||
			conversationID == nil ||
			call.Extras["message_id"] == nil ||
			call.Extras["sender_id"] != uint(1) ||
			call.Extras["sender_name"] != "Alice" ||
			call.Extras["override_msg_id"] != fmt.Sprintf("private_message_conversation_%v", conversationID) {
			t.Fatalf("unexpected push extras: %#v", call.Extras)
		}
	case <-time.After(time.Second):
		t.Fatal("expected private message push call")
	}
}
