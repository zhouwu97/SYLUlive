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
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.UserFollow{},
		&models.File{},
		&models.FileUploadGrant{},
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

	aroundPage := performMessageRequest(
		t,
		handler.GetMessages,
		http.MethodGet,
		fmt.Sprintf("/api/messages/conversations/%d?limit=2&around_id=4", conversation.ID),
		gin.Params{{Key: "id", Value: fmt.Sprint(conversation.ID)}},
		1,
		"",
	)
	if aroundPage.Code != http.StatusOK {
		t.Fatalf("around page status=%d body=%s", aroundPage.Code, aroundPage.Body.String())
	}
	var aroundMessages []models.Message
	if err := json.Unmarshal(aroundPage.Body.Bytes(), &aroundMessages); err != nil {
		t.Fatalf("decode around messages: %v", err)
	}
	if len(aroundMessages) != 2 ||
		aroundMessages[0].Content != "message-3" ||
		aroundMessages[1].Content != "message-4" {
		t.Fatalf("unexpected around page: %s", aroundPage.Body.String())
	}

	readEvents, unsubscribeReadEvents := handler.events.subscribe(2)
	defer unsubscribeReadEvents()
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
	select {
	case event := <-readEvents:
		if event.Type != "message.read" || event.ReadThroughID != messages[1].ID {
			t.Fatalf("unexpected read event: %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for read event")
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

	// 对方先回复后即为已建立会话，不再受陌生人首条消息规则限制。
	reply := performMessageRequest(
		t,
		handler.Send,
		http.MethodPost,
		"/api/messages/1",
		gin.Params{{Key: "user_id", Value: "1"}},
		2,
		`{"content":"reply"}`,
	)
	if reply.Code != http.StatusCreated {
		t.Fatalf("reply status=%d body=%s", reply.Code, reply.Body.String())
	}

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

func TestMessageSendIsIdempotentByClientMessageID(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	createMessageTestUser(t, db, 3, "Carol")
	handler := NewMessageHandler(db)

	body := `{"content":"hello","client_message_id":"client-001"}`
	first := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1, body,
	)
	second := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1, body,
	)
	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("idempotent statuses=%d/%d bodies=%s / %s",
			first.Code, second.Code, first.Body.String(), second.Body.String())
	}
	if second.Header().Get("X-Idempotent-Replay") != "true" {
		t.Fatalf("missing replay header: %#v", second.Header())
	}

	var firstMessage, secondMessage models.Message
	if err := json.Unmarshal(first.Body.Bytes(), &firstMessage); err != nil {
		t.Fatalf("decode first message: %v", err)
	}
	if err := json.Unmarshal(second.Body.Bytes(), &secondMessage); err != nil {
		t.Fatalf("decode second message: %v", err)
	}
	if firstMessage.ID != secondMessage.ID {
		t.Fatalf("message ids differ: %d/%d", firstMessage.ID, secondMessage.ID)
	}
	var count int64
	db.Model(&models.Message{}).Count(&count)
	if count != 1 {
		t.Fatalf("message count=%d want=1", count)
	}

	conflict := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/3",
		gin.Params{{Key: "user_id", Value: "3"}}, 1, body,
	)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("cross-conversation replay status=%d body=%s", conflict.Code, conflict.Body.String())
	}
}

func TestMessageConversationLookupReturnsExistingOrNull(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	createMessageTestUser(t, db, 3, "Carol")
	handler := NewMessageHandler(db)
	conversation := models.Conversation{User1ID: 1, User2ID: 2}
	if err := db.Create(&conversation).Error; err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	existing := performMessageRequest(
		t, handler.GetConversationWithUser, http.MethodGet,
		"/api/messages/users/2/conversation",
		gin.Params{{Key: "target_user_id", Value: "2"}}, 1, "",
	)
	if existing.Code != http.StatusOK ||
		!strings.Contains(existing.Body.String(), fmt.Sprintf(`"id":%d`, conversation.ID)) {
		t.Fatalf("existing lookup status=%d body=%s", existing.Code, existing.Body.String())
	}

	empty := performMessageRequest(
		t, handler.GetConversationWithUser, http.MethodGet,
		"/api/messages/users/3/conversation",
		gin.Params{{Key: "target_user_id", Value: "3"}}, 1, "",
	)
	if empty.Code != http.StatusOK || !strings.Contains(empty.Body.String(), `"conversation":null`) {
		t.Fatalf("empty lookup status=%d body=%s", empty.Code, empty.Body.String())
	}
}

func TestMessageSendRejectsForeignImageReference(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	file := models.File{
		Hash: "foreign-image", Path: "/uploads/foreign.png", Size: 12,
		MimeType: "image/png", UploaderID: 2,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create file: %v", err)
	}
	handler := NewMessageHandler(db)

	response := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1,
		fmt.Sprintf(`{"file_id":%d}`, file.ID),
	)
	if response.Code != http.StatusForbidden {
		t.Fatalf("foreign image status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestMessageSendImageResponseAndPush(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	file := models.File{
		Hash:       "image-hash",
		Path:       "/uploads/image.png",
		Size:       128,
		MimeType:   "image/png",
		UploaderID: 1,
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
			call.Extras["sender_avatar"] == nil ||
			call.Extras["recipient_user_id"] != uint(2) {
			t.Fatalf("unexpected push extras: %#v", call.Extras)
		}
	case <-time.After(time.Second):
		t.Fatal("expected private message push call")
	}
}

func TestMessageSendStickerValidatesCatalogAndPersistsID(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	handler := NewMessageHandler(db)

	invalid := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1,
		`{"sticker_id":"not-in-catalog"}`,
	)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid sticker status=%d body=%s", invalid.Code, invalid.Body.String())
	}

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	imageWithSticker := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1,
		`{"file_id":1,"sticker_id":"`+stickerID+`"}`,
	)
	if imageWithSticker.Code != http.StatusBadRequest {
		t.Fatalf("image with sticker status=%d body=%s", imageWithSticker.Code, imageWithSticker.Body.String())
	}

	response := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1,
		`{"sticker_id":"`+stickerID+`"}`,
	)
	if response.Code != http.StatusCreated {
		t.Fatalf("send sticker status=%d body=%s", response.Code, response.Body.String())
	}
	var message models.Message
	if err := json.Unmarshal(response.Body.Bytes(), &message); err != nil {
		t.Fatalf("decode sticker message: %v", err)
	}
	if message.StickerID == nil || *message.StickerID != stickerID {
		t.Fatalf("sticker_id=%v body=%s", message.StickerID, response.Body.String())
	}
	if message.Content != stickerFallbackText {
		t.Fatalf("fallback content=%q", message.Content)
	}
}

func TestMessageSendAllowsTextWithSticker(t *testing.T) {
	db := newMessageTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	handler := NewMessageHandler(db)

	const stickerID = "0cc4a3688e7b222b977fef3a078619b6"
	response := performMessageRequest(
		t, handler.Send, http.MethodPost, "/api/messages/2",
		gin.Params{{Key: "user_id", Value: "2"}}, 1,
		`{"content":"晚安","sticker_id":"`+stickerID+`"}`,
	)
	if response.Code != http.StatusCreated {
		t.Fatalf("send text with sticker status=%d body=%s", response.Code, response.Body.String())
	}

	var message models.Message
	if err := json.Unmarshal(response.Body.Bytes(), &message); err != nil {
		t.Fatalf("decode text with sticker message: %v", err)
	}
	if message.Content != "晚安" {
		t.Fatalf("content=%q", message.Content)
	}
	if message.StickerID == nil || *message.StickerID != stickerID {
		t.Fatalf("sticker_id=%v body=%s", message.StickerID, response.Body.String())
	}
}

func TestMessageEventBrokerPublishesOnlyToSubscribedUsers(t *testing.T) {
	broker := newMessageEventBroker()
	userEvents, unsubscribe := broker.subscribe(7)
	defer unsubscribe()
	event := privateMessageEvent{Type: "message.created", ConversationID: 42}

	broker.publish([]uint{7, 7, 8}, event)
	select {
	case received := <-userEvents:
		if received.Type != event.Type || received.ConversationID != event.ConversationID {
			t.Fatalf("unexpected event: %#v", received)
		}
	case <-time.After(time.Second):
		t.Fatal("expected realtime message event")
	}
	select {
	case duplicate := <-userEvents:
		t.Fatalf("received duplicate event: %#v", duplicate)
	default:
	}
}
