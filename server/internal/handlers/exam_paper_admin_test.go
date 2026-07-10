package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func performExamPaperJSONRequest(handler gin.HandlerFunc, method, path string, params gin.Params, userID uint, payload map[string]any) *httptest.ResponseRecorder {
	body, err := json.Marshal(payload)
	if err != nil {
		panic(err)
	}
	return performExamPaperRequest(handler, method, path, params, userID, body, "application/json")
}

func TestAdminApproveExamPaperRewardsOnceAndCreatesOneMessageAndLog(t *testing.T) {
	env := newExamPaperTestEnv(t)
	contributor := createExamPaperTestUser(t, env.db, "approve-contributor", models.RoleUser, true, 40)
	admin := createExamPaperTestUser(t, env.db, "approve-admin", models.RoleAdmin, false, 0)
	paper := createStoredExamPaper(t, env, contributor, models.ExamPaperStatusPending)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}
	payload := map[string]any{
		"course_name":   "\u7ebf\u6027\u4ee3\u6570",
		"academic_year": "2024-2025",
		"semester":      "second",
		"exam_type":     "midterm",
		"reason":        "\u5185\u5bb9\u6e05\u6670\uff0c\u53ef\u4ee5\u53d1\u5e03",
	}

	first := performExamPaperJSONRequest(env.handler.AdminApprove, http.MethodPost, "/api/admin/exam-papers/1/approve", params, admin.ID, payload)
	if first.Code != http.StatusOK || !strings.Contains(first.Body.String(), `"status":"published"`) {
		t.Fatalf("approve failed: status=%d body=%s", first.Code, first.Body.String())
	}
	second := performExamPaperJSONRequest(env.handler.AdminApprove, http.MethodPost, "/api/admin/exam-papers/1/approve", params, admin.ID, payload)
	if second.Code != http.StatusConflict || decodeErrorCode(t, second) != "exam_paper_not_pending" {
		t.Fatalf("repeated approve must conflict: status=%d body=%s", second.Code, second.Body.String())
	}

	var refreshedPaper models.ExamPaper
	if err := env.db.First(&refreshedPaper, paper.ID).Error; err != nil {
		t.Fatalf("load approved paper: %v", err)
	}
	if refreshedPaper.Status != models.ExamPaperStatusPublished || refreshedPaper.Title != "\u7ebf\u6027\u4ee3\u6570 \u00b7 2024-2025 \u00b7 \u7b2c\u4e8c\u5b66\u671f \u00b7 \u671f\u4e2d" {
		t.Fatalf("approved metadata mismatch: %#v", refreshedPaper)
	}
	if refreshedPaper.RewardedAt == nil || refreshedPaper.PublishedAt == nil || refreshedPaper.ReviewerID == nil || *refreshedPaper.ReviewerID != admin.ID {
		t.Fatalf("approval audit fields missing: %#v", refreshedPaper)
	}
	var refreshedUser models.User
	env.db.First(&refreshedUser, contributor.ID)
	if refreshedUser.Exp != 50 {
		t.Fatalf("approval reward must be exactly 10 exp: %d", refreshedUser.Exp)
	}
	var messageCount int64
	env.db.Model(&models.Message{}).Count(&messageCount)
	if messageCount != 1 {
		t.Fatalf("approval must create exactly one system message: %d", messageCount)
	}
	var logCount int64
	env.db.Model(&models.AdminLog{}).Where("action = ?", "\u5ba1\u6838\u901a\u8fc7\u8bd5\u5377").Count(&logCount)
	if logCount != 1 {
		t.Fatalf("approval must create exactly one admin log: %d", logCount)
	}
}

func TestAdminRejectExamPaperRequiresReasonAndDeletesRecordAndFile(t *testing.T) {
	env := newExamPaperTestEnv(t)
	contributor := createExamPaperTestUser(t, env.db, "reject-contributor", models.RoleUser, true, 0)
	admin := createExamPaperTestUser(t, env.db, "reject-admin", models.RoleAdmin, false, 0)
	paper := createStoredExamPaper(t, env, contributor, models.ExamPaperStatusPending)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	empty := performExamPaperJSONRequest(env.handler.AdminReject, http.MethodPost, "/api/admin/exam-papers/1/reject", params, admin.ID, map[string]any{"reason": "  "})
	if empty.Code != http.StatusBadRequest || decodeErrorCode(t, empty) != "review_reason_required" {
		t.Fatalf("empty reject reason must fail: status=%d body=%s", empty.Code, empty.Body.String())
	}
	response := performExamPaperJSONRequest(env.handler.AdminReject, http.MethodPost, "/api/admin/exam-papers/1/reject", params, admin.ID, map[string]any{"reason": "\u5305\u542b\u5b66\u53f7\u4fe1\u606f"})
	if response.Code != http.StatusOK {
		t.Fatalf("reject failed: status=%d body=%s", response.Code, response.Body.String())
	}
	var paperCount int64
	env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&paperCount)
	if paperCount != 0 {
		t.Fatalf("rejected paper record must be hard deleted: %d", paperCount)
	}
	if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); !os.IsNotExist(err) {
		t.Fatalf("rejected PDF must be physically deleted: %v", err)
	}
	var messageCount int64
	env.db.Model(&models.Message{}).Count(&messageCount)
	if messageCount != 1 {
		t.Fatalf("reject must create one system message: %d", messageCount)
	}
	var logCount int64
	env.db.Model(&models.AdminLog{}).Where("action = ?", "\u62d2\u7edd\u8bd5\u5377\u6295\u7a3f").Count(&logCount)
	if logCount != 1 {
		t.Fatalf("reject must create one admin log: %d", logCount)
	}
}

func TestAdminUpdateAndUnpublishExamPaper(t *testing.T) {
	env := newExamPaperTestEnv(t)
	contributor := createExamPaperTestUser(t, env.db, "unpublish-contributor", models.RoleUser, true, 80)
	admin := createExamPaperTestUser(t, env.db, "unpublish-admin", models.RoleAdmin, false, 0)
	paper := createStoredExamPaper(t, env, contributor, models.ExamPaperStatusPublished)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	update := performExamPaperJSONRequest(env.handler.AdminUpdate, http.MethodPatch, "/api/admin/exam-papers/1", params, admin.ID, map[string]any{
		"course_name": "\u5927\u5b66\u7269\u7406", "academic_year": "2025-2026", "semester": "first", "exam_type": "final",
	})
	if update.Code != http.StatusOK || !strings.Contains(update.Body.String(), "\u5927\u5b66\u7269\u7406") {
		t.Fatalf("update published paper failed: status=%d body=%s", update.Code, update.Body.String())
	}

	empty := performExamPaperJSONRequest(env.handler.AdminUnpublish, http.MethodPost, "/api/admin/exam-papers/1/unpublish", params, admin.ID, map[string]any{"reason": ""})
	if empty.Code != http.StatusBadRequest || decodeErrorCode(t, empty) != "unpublish_reason_required" {
		t.Fatalf("empty unpublish reason must fail: status=%d body=%s", empty.Code, empty.Body.String())
	}
	response := performExamPaperJSONRequest(env.handler.AdminUnpublish, http.MethodPost, "/api/admin/exam-papers/1/unpublish", params, admin.ID, map[string]any{"reason": "\u7248\u6743\u65b9\u8981\u6c42\u4e0b\u67b6"})
	if response.Code != http.StatusOK {
		t.Fatalf("unpublish failed: status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "\u7248\u6743\u65b9\u8981\u6c42\u4e0b\u67b6") {
		t.Fatalf("unpublish response must include reason: %s", response.Body.String())
	}
	var refreshed models.ExamPaper
	env.db.First(&refreshed, paper.ID)
	if refreshed.Status != models.ExamPaperStatusUnpublished || refreshed.FileKey != "" || refreshed.UnpublishedAt == nil || refreshed.UnpublisherID == nil {
		t.Fatalf("unpublish fields mismatch: %#v", refreshed)
	}
	if refreshed.SHA256 == "" || refreshed.RewardedAt != nil {
		t.Fatalf("unpublish must retain hash and must not create reward: %#v", refreshed)
	}
	if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); !os.IsNotExist(err) {
		t.Fatalf("unpublished PDF must be removed: %v", err)
	}
	var refreshedUser models.User
	env.db.First(&refreshedUser, contributor.ID)
	if refreshedUser.Exp != 80 {
		t.Fatalf("unpublish must not reclaim exp: %d", refreshedUser.Exp)
	}
	var messages int64
	env.db.Model(&models.Message{}).Count(&messages)
	if messages != 1 {
		t.Fatalf("unpublish must create one system message: %d", messages)
	}
}

func TestAdminExamPaperListCountAndDetail(t *testing.T) {
	env := newExamPaperTestEnv(t)
	contributor := createExamPaperTestUser(t, env.db, "admin-list-contributor", models.RoleUser, true, 0)
	admin := createExamPaperTestUser(t, env.db, "admin-list-admin", models.RoleAdmin, false, 0)
	for index, status := range []models.ExamPaperStatus{models.ExamPaperStatusPending, models.ExamPaperStatusPublished, models.ExamPaperStatusUnpublished} {
		paper := models.ExamPaper{
			Status: status, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: fmt.Sprintf("course-%d", index), AcademicYear: "2025-2026",
			Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal,
			Title: fmt.Sprintf("course-%d", index), FileKey: fmt.Sprintf("admin-list-%d.pdf", index),
			FileSize: 1, SHA256: fmt.Sprintf("admin-list-hash-%d", index),
		}
		if status == models.ExamPaperStatusUnpublished {
			paper.FileKey = ""
		}
		if err := env.db.Create(&paper).Error; err != nil {
			t.Fatalf("create admin list fixture: %v", err)
		}
	}

	count := performExamPaperRequest(env.handler.AdminPendingCount, http.MethodGet, "/api/admin/exam-papers/pending-count", nil, admin.ID, nil, "")
	if count.Code != http.StatusOK || !strings.Contains(count.Body.String(), `"count":1`) {
		t.Fatalf("pending count mismatch: status=%d body=%s", count.Code, count.Body.String())
	}
	list := performExamPaperRequest(env.handler.AdminList, http.MethodGet, "/api/admin/exam-papers?status=pending", nil, admin.ID, nil, "")
	if list.Code != http.StatusOK || !strings.Contains(list.Body.String(), `"total":1`) {
		t.Fatalf("admin pending list mismatch: status=%d body=%s", list.Code, list.Body.String())
	}
	detail := performExamPaperRequest(env.handler.AdminGet, http.MethodGet, "/api/admin/exam-papers/1", gin.Params{{Key: "id", Value: "1"}}, admin.ID, nil, "")
	if detail.Code != http.StatusOK || !strings.Contains(detail.Body.String(), `"status":"pending"`) {
		t.Fatalf("admin detail mismatch: status=%d body=%s", detail.Code, detail.Body.String())
	}
}

func TestAdminApproveExamPaperConcurrentRequestsRemainIdempotent(t *testing.T) {
	gin.SetMode(gin.TestMode)
	dbPath := filepath.Join(t.TempDir(), "exam-approve.db")
	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{TranslateError: true})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("open sql database: %v", err)
	}
	defer sqlDB.Close()
	if err := db.AutoMigrate(&models.User{}, &models.ExamPaper{}, &models.Conversation{}, &models.Message{}, &models.AdminLog{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	if err := models.EnsureExamPaperIndexes(db); err != nil {
		t.Fatalf("create exam paper indexes: %v", err)
	}
	if err := models.EnsureConversationIndexes(db); err != nil {
		t.Fatalf("create conversation indexes: %v", err)
	}
	fileRoot := t.TempDir()
	files, err := services.NewExamPaperFileService(fileRoot)
	if err != nil {
		t.Fatalf("create file service: %v", err)
	}
	env := examPaperTestEnv{db: db, files: files, handler: NewExamPaperHandler(db, files), root: fileRoot}
	contributor := createExamPaperTestUser(t, db, "concurrent-contributor", models.RoleUser, true, 0)
	admin := createExamPaperTestUser(t, db, "concurrent-admin", models.RoleAdmin, false, 0)
	paper := createStoredExamPaper(t, env, contributor, models.ExamPaperStatusPending)
	payload := map[string]any{
		"course_name": "Advanced Math", "academic_year": "2025-2026", "semester": "first", "exam_type": "final", "reason": "ok",
	}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	start := make(chan struct{})
	responses := make(chan *httptest.ResponseRecorder, 2)
	var wait sync.WaitGroup
	for index := 0; index < 2; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			<-start
			responses <- performExamPaperJSONRequest(env.handler.AdminApprove, http.MethodPost, "/api/admin/exam-papers/1/approve", params, admin.ID, payload)
		}()
	}
	close(start)
	wait.Wait()
	close(responses)

	statusCounts := map[int]int{}
	for response := range responses {
		statusCounts[response.Code]++
	}
	if statusCounts[http.StatusOK] != 1 || statusCounts[http.StatusConflict] != 1 {
		t.Fatalf("concurrent approval responses must be one success and one conflict: %#v", statusCounts)
	}
	var refreshed models.User
	db.First(&refreshed, contributor.ID)
	if refreshed.Exp != 10 {
		t.Fatalf("concurrent approval duplicated reward: %d", refreshed.Exp)
	}
	var messageCount, logCount int64
	db.Model(&models.Message{}).Count(&messageCount)
	db.Model(&models.AdminLog{}).Where("action = ?", "\u5ba1\u6838\u901a\u8fc7\u8bd5\u5377").Count(&logCount)
	if messageCount != 1 || logCount != 1 {
		t.Fatalf("concurrent approval duplicated side effects: messages=%d logs=%d", messageCount, logCount)
	}
}
