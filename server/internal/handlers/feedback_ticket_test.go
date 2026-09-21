package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func setupTestFeedbackDB(t *testing.T) (*gorm.DB, *FeedbackTicketHandler) {
	gin.SetMode(gin.TestMode)
	uploadDir := t.TempDir()

	db, err := gorm.Open(sqlite.Open("file:"+strings.ReplaceAll(t.Name(), "/", "_")+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}

	err = db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.Notification{},
		&models.FeedbackTicket{},
		&models.FeedbackMessage{},
		&models.FeedbackAttachment{},
		&models.FeedbackStatusHistory{},
	)
	if err != nil {
		t.Fatal(err)
	}

	// 创建测试用户与管理员
	user := models.User{ID: 10, StudentID: "20220001", Nickname: "普通同学", Role: models.RoleUser}
	admin := models.User{ID: 99, StudentID: "admin01", Nickname: "管理员小林", Role: models.RoleAdmin}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatal(err)
	}

	handler := NewFeedbackTicketHandler(db, uploadDir, nil)
	return db, handler
}

func TestFeedbackSnippetForColumnLimitsRunes(t *testing.T) {
	value := strings.Repeat("管理员状态说明", 60)
	snippet := feedbackSnippetForColumn(value, 255)
	if len([]rune(snippet)) > 255 {
		t.Fatalf("摘要超过数据库列长度: %d", len([]rune(snippet)))
	}
	if !strings.HasSuffix(snippet, "...") {
		t.Fatalf("超长摘要应保留截断标记: %q", snippet[len(snippet)-minInt(len(snippet), 10):])
	}
}

func TestFeedbackTicket_ConcurrencyReopenVsConfirmResolved(t *testing.T) {
	db, handler := setupTestFeedbackDB(t)

	ticket := models.FeedbackTicket{
		TicketNo:    "SY2609142001",
		UserID:      10,
		Type:        models.FeedbackTypeBug,
		Title:       "并发状态测试工单",
		Description: "测试重新打开与确认解决的并发互斥",
		Status:      models.FeedbackStatusResolved,
	}
	if err := db.Create(&ticket).Error; err != nil {
		t.Fatal(err)
	}

	userRouter := gin.New()
	userRouter.POST("/tickets/:id/reopen", func(c *gin.Context) {
		c.Set("user_id", uint(10))
		handler.ReopenTicket(c)
	})
	userRouter.POST("/tickets/:id/confirm-resolved", func(c *gin.Context) {
		c.Set("user_id", uint(10))
		handler.ConfirmResolved(c)
	})

	// 请求 B 先执行 ReopenTicket
	wReopen := httptest.NewRecorder()
	reopenBody, _ := json.Marshal(map[string]string{"reason": "问题依然在复现"})
	reqReopen := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/tickets/%d/reopen", ticket.ID), bytes.NewReader(reopenBody))
	userRouter.ServeHTTP(wReopen, reqReopen)
	if wReopen.Code != http.StatusOK {
		t.Fatalf("reopen want 200, got %d, body=%s", wReopen.Code, wReopen.Body.String())
	}

	// 此时工单状态已变成 investigating
	// 请求 A 稍后执行 ConfirmResolved，必须返回 409 Conflict，禁止覆盖状态为 closed
	wConfirm := httptest.NewRecorder()
	reqConfirm := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/tickets/%d/confirm-resolved", ticket.ID), nil)
	userRouter.ServeHTTP(wConfirm, reqConfirm)
	if wConfirm.Code != http.StatusConflict {
		t.Fatalf("confirm-resolved on investigating ticket want 409 Conflict, got %d, body=%s", wConfirm.Code, wConfirm.Body.String())
	}

	var finalTicket models.FeedbackTicket
	if err := db.First(&finalTicket, ticket.ID).Error; err != nil {
		t.Fatal(err)
	}
	if finalTicket.Status != models.FeedbackStatusInvestigating {
		t.Fatalf("ticket status should remain investigating, got %s", finalTicket.Status)
	}
}

func TestFeedbackTicket_CreateAndDetailFlow(t *testing.T) {
	db, handler := setupTestFeedbackDB(t)

	// 1. 用户创建工单
	router := gin.New()
	router.POST("/tickets", func(c *gin.Context) {
		c.Set("user_id", uint(10))
		handler.CreateTicket(c)
	})

	body, _ := json.Marshal(map[string]interface{}{
		"type":               "bug",
		"title":              "课表刷新后无变化",
		"description":        "重新同步后周三的课还是旧的",
		"steps_to_reproduce": "1. 登录教务\n2. 点击刷新课表",
		"actual_result":      "课表没有变动",
		"expected_result":    "显示最新课表",
		"app_version":        "2.8.2",
		"diagnostics_json":   `{"route":"/schedule","jwt":"secret_jwt_token"}`,
	})

	req := httptest.NewRequest(http.MethodPost, "/tickets", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("want 201, got %d, body=%s", w.Code, w.Body.String())
	}

	var createResp struct {
		Ticket models.FeedbackTicket `json:"ticket"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &createResp)
	ticketID := createResp.Ticket.ID
	if ticketID == 0 {
		t.Fatal("ticket_id should not be 0")
	}
	if !strings.HasPrefix(createResp.Ticket.TicketNo, "SY") {
		t.Fatalf("ticket_no %s should start with SY", createResp.Ticket.TicketNo)
	}
	// 验证敏感信息已被过滤
	if strings.Contains(createResp.Ticket.DiagnosticsJSON, "secret_jwt_token") {
		t.Fatalf("jwt token must be sanitized, got: %s", createResp.Ticket.DiagnosticsJSON)
	}

	// 2. 普通用户获取详情
	userRouter := gin.New()
	userRouter.GET("/tickets/:id", func(c *gin.Context) {
		c.Set("user_id", uint(10))
		handler.GetTicketDetail(c)
	})

	w2 := httptest.NewRecorder()
	req2 := httptest.NewRequest(http.MethodGet, "/tickets/1", nil)
	userRouter.ServeHTTP(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w2.Code)
	}

	// 3. 管理员发送内部备注与公开回复
	adminRouter := gin.New()
	adminRouter.POST("/admin/tickets/:id/messages", func(c *gin.Context) {
		c.Set("user_id", uint(99))
		handler.AdminAddMessage(c)
	})

	// 3.1 内部备注 (visible_to_user = false)
	noteBody, _ := json.Marshal(map[string]interface{}{
		"content":         "疑似 ScheduleOverrideRepository.merge() 冲突",
		"visible_to_user": false,
	})
	wNote := httptest.NewRecorder()
	reqNote := httptest.NewRequest(http.MethodPost, "/admin/tickets/1/messages", bytes.NewReader(noteBody))
	reqNote.Header.Set("Content-Type", "application/json")
	adminRouter.ServeHTTP(wNote, reqNote)
	if wNote.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", wNote.Code)
	}

	// 3.2 公开回复 (visible_to_user = true)
	replyBody, _ := json.Marshal(map[string]interface{}{
		"content":         "您好，我们正在排查此问题，请问使用的是安卓还是 iOS？",
		"visible_to_user": true,
	})
	wReply := httptest.NewRecorder()
	reqReply := httptest.NewRequest(http.MethodPost, "/admin/tickets/1/messages", bytes.NewReader(replyBody))
	reqReply.Header.Set("Content-Type", "application/json")
	adminRouter.ServeHTTP(wReply, reqReply)
	if wReply.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", wReply.Code)
	}

	// 4. 验证用户查询详情时严格不可见内部备注！
	wCheckUser := httptest.NewRecorder()
	reqCheckUser := httptest.NewRequest(http.MethodGet, "/tickets/1", nil)
	userRouter.ServeHTTP(wCheckUser, reqCheckUser)

	var userDetailResp struct {
		Ticket   models.FeedbackTicket    `json:"ticket"`
		Messages []models.FeedbackMessage `json:"messages"`
	}
	_ = json.Unmarshal(wCheckUser.Body.Bytes(), &userDetailResp)

	for _, m := range userDetailResp.Messages {
		if strings.Contains(m.Content, "ScheduleOverrideRepository") {
			t.Fatalf("FATAL: internal_note leaked to user endpoint! Content=%s", m.Content)
		}
		if !m.VisibleToUser {
			t.Fatalf("FATAL: invisible message returned to user: %+v", m)
		}
	}

	// 5. 管理员端查询详情能够看到内部备注
	adminDetailRouter := gin.New()
	adminDetailRouter.GET("/admin/tickets/:id", func(c *gin.Context) {
		c.Set("user_id", uint(99))
		handler.AdminGetTicketDetail(c)
	})
	wAdminDetail := httptest.NewRecorder()
	reqAdminDetail := httptest.NewRequest(http.MethodGet, "/admin/tickets/1", nil)
	adminDetailRouter.ServeHTTP(wAdminDetail, reqAdminDetail)

	var adminDetailResp struct {
		Ticket            models.FeedbackTicket    `json:"ticket"`
		InitialSubmission map[string]interface{}   `json:"initial_submission"`
		Messages          []models.FeedbackMessage `json:"messages"`
	}
	_ = json.Unmarshal(wAdminDetail.Body.Bytes(), &adminDetailResp)
	if adminDetailResp.InitialSubmission == nil {
		t.Fatal("详情应返回独立的 initial_submission")
	}

	hasInternalNote := false
	for _, m := range adminDetailResp.Messages {
		if strings.Contains(m.Content, "ScheduleOverrideRepository") {
			hasInternalNote = true
		}
	}
	if !hasInternalNote {
		t.Fatal("Admin must be able to see internal notes")
	}

	// 6. 管理员标记更新状态并请求补充信息
	adminStatusRouter := gin.New()
	adminStatusRouter.POST("/admin/tickets/:id/request-info", func(c *gin.Context) {
		c.Set("user_id", uint(99))
		handler.AdminRequestInfo(c)
	})

	reqInfoBody, _ := json.Marshal(map[string]interface{}{
		"requested_items": []string{"screenshot", "steps"},
		"comment":         "请补充具体的课程名称和修改前后的上课时间",
	})
	wReqInfo := httptest.NewRecorder()
	reqReqInfo := httptest.NewRequest(http.MethodPost, "/admin/tickets/1/request-info", bytes.NewReader(reqInfoBody))
	reqReqInfo.Header.Set("Content-Type", "application/json")
	adminStatusRouter.ServeHTTP(wReqInfo, reqReqInfo)
	if wReqInfo.Code != http.StatusOK {
		t.Fatalf("want 200, got %d, body=%s", wReqInfo.Code, wReqInfo.Body.String())
	}

	// 检查数据库中工单状态为 waiting_user
	var updatedTicket models.FeedbackTicket
	if err := db.First(&updatedTicket, ticketID).Error; err != nil {
		t.Fatal(err)
	}
	if updatedTicket.Status != models.FeedbackStatusWaitingUser {
		t.Fatalf("status should be waiting_user, got %s", updatedTicket.Status)
	}

	// 7. 用户回复后状态自动流转为 accepted
	userReplyRouter := gin.New()
	userReplyRouter.POST("/tickets/:id/messages", func(c *gin.Context) {
		c.Set("user_id", uint(10))
		handler.AddMessage(c)
	})
	uReplyBody, _ := json.Marshal(map[string]interface{}{
		"content": "课程是高等数学，周三下午第一节改到上午第三节了",
	})
	wUReply := httptest.NewRecorder()
	reqUReply := httptest.NewRequest(http.MethodPost, "/tickets/1/messages", bytes.NewReader(uReplyBody))
	reqUReply.Header.Set("Content-Type", "application/json")
	userReplyRouter.ServeHTTP(wUReply, reqUReply)
	if wUReply.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", wUReply.Code)
	}

	_ = db.First(&updatedTicket, ticketID)
	if updatedTicket.Status != models.FeedbackStatusAccepted {
		t.Fatalf("after user added info, status should be accepted, got %s", updatedTicket.Status)
	}

	// 8. 管理员解决工单
	adminUpdateStatusRouter := gin.New()
	adminUpdateStatusRouter.PATCH("/admin/tickets/:id/status", func(c *gin.Context) {
		c.Set("user_id", uint(99))
		handler.AdminUpdateStatus(c)
	})
	resolveBody, _ := json.Marshal(map[string]interface{}{
		"status":      "resolved",
		"status_note": "已在 v2.8.3 中修复",
	})
	wResolve := httptest.NewRecorder()
	reqResolve := httptest.NewRequest(http.MethodPatch, "/admin/tickets/1/status", bytes.NewReader(resolveBody))
	reqResolve.Header.Set("Content-Type", "application/json")
	adminUpdateStatusRouter.ServeHTTP(wResolve, reqResolve)
	if wResolve.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", wResolve.Code)
	}

	_ = db.First(&updatedTicket, ticketID)
	if updatedTicket.Status != models.FeedbackStatusResolved {
		t.Fatalf("status should be resolved, got %s", updatedTicket.Status)
	}

	// 9. 用户点击「仍有问题」，重新打开工单
	userReopenRouter := gin.New()
	userReopenRouter.POST("/tickets/:id/reopen", func(c *gin.Context) {
		c.Set("user_id", uint(10))
		handler.ReopenTicket(c)
	})
	reopenBody, _ := json.Marshal(map[string]interface{}{
		"reason": "更新到最新内测版后周五的实验课还是没有显示",
	})
	wReopen := httptest.NewRecorder()
	reqReopen := httptest.NewRequest(http.MethodPost, "/tickets/1/reopen", bytes.NewReader(reopenBody))
	reqReopen.Header.Set("Content-Type", "application/json")
	userReopenRouter.ServeHTTP(wReopen, reqReopen)
	if wReopen.Code != http.StatusOK {
		t.Fatalf("want 200, got %d, body=%s", wReopen.Code, wReopen.Body.String())
	}

	_ = db.First(&updatedTicket, ticketID)
	if updatedTicket.Status != models.FeedbackStatusInvestigating {
		t.Fatalf("status after reopen should be investigating, got %s", updatedTicket.Status)
	}
}

func TestFeedbackTicket_AdminStatusUsesExpectedStateAndNoOp(t *testing.T) {
	db, handler := setupTestFeedbackDB(t)
	ticket := models.FeedbackTicket{
		TicketNo:    "SY2609143001",
		UserID:      10,
		Type:        models.FeedbackTypeBug,
		Title:       "状态并发测试",
		Description: "验证状态条件更新",
		Status:      models.FeedbackStatusPending,
		StatusNote:  "等待管理员查看",
	}
	if err := db.Create(&ticket).Error; err != nil {
		t.Fatal(err)
	}

	router := gin.New()
	router.PATCH("/tickets/:id/status", func(c *gin.Context) {
		c.Set("user_id", uint(99))
		handler.AdminUpdateStatus(c)
	})

	request := func(body map[string]string) *httptest.ResponseRecorder {
		payload, _ := json.Marshal(body)
		response := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPatch, fmt.Sprintf("/tickets/%d/status", ticket.ID), bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		router.ServeHTTP(response, req)
		return response
	}

	if response := request(map[string]string{
		"status": "accepted", "expected_status": "pending",
	}); response.Code != http.StatusOK {
		t.Fatalf("首次受理 want 200, got %d, body=%s", response.Code, response.Body.String())
	}

	var historyCount, messageCount, notificationCount int64
	db.Model(&models.FeedbackStatusHistory{}).Where("ticket_id = ?", ticket.ID).Count(&historyCount)
	db.Model(&models.FeedbackMessage{}).Where("ticket_id = ?", ticket.ID).Count(&messageCount)
	db.Model(&models.Notification{}).Where("related_id = ? AND user_id = ?", ticket.ID, 10).Count(&notificationCount)

	if response := request(map[string]string{
		"status": "accepted", "expected_status": "pending",
	}); response.Code != http.StatusConflict {
		t.Fatalf("过期 expected_status want 409, got %d, body=%s", response.Code, response.Body.String())
	}

	if response := request(map[string]string{
		"status": "accepted", "expected_status": "accepted",
	}); response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"no_change":true`) {
		t.Fatalf("重复状态更新应 no-op，got %d, body=%s", response.Code, response.Body.String())
	}

	var nextHistoryCount, nextMessageCount, nextNotificationCount int64
	db.Model(&models.FeedbackStatusHistory{}).Where("ticket_id = ?", ticket.ID).Count(&nextHistoryCount)
	db.Model(&models.FeedbackMessage{}).Where("ticket_id = ?", ticket.ID).Count(&nextMessageCount)
	db.Model(&models.Notification{}).Where("related_id = ? AND user_id = ?", ticket.ID, 10).Count(&nextNotificationCount)
	if nextHistoryCount != historyCount || nextMessageCount != messageCount || nextNotificationCount != notificationCount {
		t.Fatalf("重复状态更新不应新增历史、消息或通知: history %d->%d, message %d->%d, notification %d->%d", historyCount, nextHistoryCount, messageCount, nextMessageCount, notificationCount, nextNotificationCount)
	}

	if response := request(map[string]string{
		"status": "closed", "expected_status": "accepted",
	}); response.Code != http.StatusConflict {
		t.Fatalf("非法跳转 want 409, got %d, body=%s", response.Code, response.Body.String())
	}
}

func TestFeedbackAttachment_AuthorizesMatchingReference(t *testing.T) {
	db, handler := setupTestFeedbackDB(t)
	otherUser := models.User{ID: 11, StudentID: "20220002", Nickname: "另一位同学", Role: models.RoleUser}
	if err := db.Create(&otherUser).Error; err != nil {
		t.Fatal(err)
	}

	ticketA := models.FeedbackTicket{
		TicketNo: "SY2609141001", UserID: 10, Type: models.FeedbackTypeBug,
		Title: "工单 A", Description: "内部后公开", Status: models.FeedbackStatusPending,
	}
	ticketB := models.FeedbackTicket{
		TicketNo: "SY2609141002", UserID: 11, Type: models.FeedbackTypeBug,
		Title: "工单 B", Description: "复用相同图片", Status: models.FeedbackStatusPending,
	}
	if err := db.Create(&ticketA).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&ticketB).Error; err != nil {
		t.Fatal(err)
	}

	sharedPath := filepath.Join(handler.uploadDir, "shared.png")
	if err := os.WriteFile(sharedPath, []byte("shared-image"), 0o600); err != nil {
		t.Fatal(err)
	}
	privatePath := filepath.Join(handler.uploadDir, "private.png")
	if err := os.WriteFile(privatePath, []byte("private-image"), 0o600); err != nil {
		t.Fatal(err)
	}
	sharedFile := models.File{Hash: strings.Repeat("a", 64), Path: "/uploads/shared.png", Size: 12, MimeType: "image/png", UploaderID: 99}
	privateFile := models.File{Hash: strings.Repeat("b", 64), Path: "/uploads/private.png", Size: 13, MimeType: "image/png", UploaderID: 99}
	if err := db.Create(&sharedFile).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&privateFile).Error; err != nil {
		t.Fatal(err)
	}

	internal := models.FeedbackMessage{TicketID: ticketA.ID, SenderType: "admin", SenderID: 99, MessageType: models.FeedbackMsgInternalNote, Content: "内部图", VisibleToUser: false}
	publicA := models.FeedbackMessage{TicketID: ticketA.ID, SenderType: "admin", SenderID: 99, MessageType: models.FeedbackMsgImage, Content: "公开图", VisibleToUser: true}
	publicB := models.FeedbackMessage{TicketID: ticketB.ID, SenderType: "admin", SenderID: 99, MessageType: models.FeedbackMsgImage, Content: "公开图", VisibleToUser: true}
	for _, message := range []*models.FeedbackMessage{&internal, &publicA, &publicB} {
		if err := db.Create(message).Error; err != nil {
			t.Fatal(err)
		}
	}
	references := []models.FeedbackAttachment{
		{TicketID: ticketA.ID, MessageID: &internal.ID, FileID: sharedFile.ID, UploaderID: 99},
		{TicketID: ticketA.ID, MessageID: &publicA.ID, FileID: sharedFile.ID, UploaderID: 99},
		{TicketID: ticketB.ID, MessageID: &publicB.ID, FileID: sharedFile.ID, UploaderID: 99},
		{TicketID: ticketA.ID, MessageID: &internal.ID, FileID: privateFile.ID, UploaderID: 99},
	}
	if err := db.Create(&references).Error; err != nil {
		t.Fatal(err)
	}

	requestAs := func(userID, fileID uint) *httptest.ResponseRecorder {
		router := gin.New()
		router.GET("/attachments/:file_id", func(c *gin.Context) {
			c.Set("user_id", userID)
			handler.ServeAttachment(c)
		})
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/attachments/"+fmt.Sprint(fileID), nil))
		return response
	}

	if got := requestAs(10, sharedFile.ID).Code; got != http.StatusOK {
		t.Fatalf("同工单后续公开引用应允许访问，got %d", got)
	}
	if got := requestAs(11, sharedFile.ID).Code; got != http.StatusOK {
		t.Fatalf("相同文件在另一工单的合法引用应允许访问，got %d", got)
	}
	if got := requestAs(10, privateFile.ID).Code; got != http.StatusNotFound {
		t.Fatalf("仅内部备注引用必须拒绝普通用户，got %d", got)
	}
	if got := requestAs(99, privateFile.ID).Code; got != http.StatusOK {
		t.Fatalf("管理员应能访问内部附件，got %d", got)
	}
}
