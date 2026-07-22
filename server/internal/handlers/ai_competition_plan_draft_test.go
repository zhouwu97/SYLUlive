package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func createAIActionTestUserAndEvent(t *testing.T, db *gorm.DB, suffix string) (models.User, models.CompetitionEvent) {
	t.Helper()
	user := models.User{
		StudentID: "ai-action-" + suffix, PasswordHash: "x", Nickname: "草稿用户", EduBound: true,
		EduGrade: "2023", EduCollege: "信息科学与工程学院", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	event := models.CompetitionEvent{
		Title: "程序设计赛-" + suffix, Status: "published", Version: 1,
		EligibleMajors: jsonArray([]string{"计算机科学与技术"}), CompetitionRating: "A",
		SchoolRecognitionStatus: "recognized", TimeStatus: "pending", RegistrationTimeText: "待官方确认",
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	return user, event
}

func performAIActionRequest(
	t *testing.T,
	method string,
	path string,
	body string,
	userID uint,
	params gin.Params,
	headers map[string]string,
	handler func(*gin.Context),
) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, bytes.NewBufferString(body))
	context.Request.Header.Set("Content-Type", "application/json")
	for key, value := range headers {
		context.Request.Header.Set(key, value)
	}
	context.Params = params
	context.Set("user_id", userID)
	handler(context)
	return recorder
}

func createCompetitionPlanDraftForTest(t *testing.T, handler *CompetitionHandler, userID, eventID uint, key string) competitionPlanDraftResponse {
	t.Helper()
	recorder := performAIActionRequest(
		t, http.MethodPost, "/api/ai/action-drafts/competition-plan",
		fmt.Sprintf(`{"event_id":%d}`, eventID), userID, nil,
		map[string]string{"Idempotency-Key": key}, handler.CreateCompetitionPlanActionDraft,
	)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response competitionPlanDraftResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func confirmCompetitionPlanDraftForTest(t *testing.T, handler *CompetitionHandler, userID, draftID uint) *httptest.ResponseRecorder {
	t.Helper()
	return performAIActionRequest(
		t, http.MethodPost, fmt.Sprintf("/api/user/ai-action-drafts/%d/confirm", draftID), "{}", userID,
		gin.Params{{Key: "id", Value: fmt.Sprint(draftID)}}, nil, handler.ConfirmAIActionDraft,
	)
}

func TestCompetitionPlanDraftRejectsForgedRecommendationFieldsAndIsIdempotent(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	user, event := createAIActionTestUserAndEvent(t, db, "strict")
	recorder := performAIActionRequest(
		t, http.MethodPost, "/api/ai/action-drafts/competition-plan",
		fmt.Sprintf(`{"event_id":%d,"personalized_score":99,"fit_reasons":["伪造"]}`, event.ID),
		user.ID, nil, nil, handler.CreateCompetitionPlanActionDraft,
	)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var count int64
	if err := db.Model(&models.AIActionDraft{}).Count(&count).Error; err != nil || count != 0 {
		t.Fatalf("draft count=%d err=%v", count, err)
	}

	first := createCompetitionPlanDraftForTest(t, handler, user.ID, event.ID, "same-request")
	retry := performAIActionRequest(
		t, http.MethodPost, "/api/ai/action-drafts/competition-plan", fmt.Sprintf(`{"event_id":%d}`, event.ID),
		user.ID, nil, map[string]string{"Idempotency-Key": "same-request"}, handler.CreateCompetitionPlanActionDraft,
	)
	if retry.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s", retry.Code, retry.Body.String())
	}
	var second competitionPlanDraftResponse
	if err := json.Unmarshal(retry.Body.Bytes(), &second); err != nil || second.ID != first.ID {
		t.Fatalf("retry response=%+v err=%v", second, err)
	}
	if err := db.Model(&models.CompetitionRecommendationSnapshot{}).Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("snapshot count=%d err=%v", count, err)
	}
}

func TestCompetitionPlanDraftOwnershipAndRepeatedConfirmation(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	owner, event := createAIActionTestUserAndEvent(t, db, "owner")
	other := models.User{StudentID: "ai-action-other", PasswordHash: "x", Nickname: "其他用户"}
	if err := db.Create(&other).Error; err != nil {
		t.Fatal(err)
	}
	draft := createCompetitionPlanDraftForTest(t, handler, owner.ID, event.ID, "owner-request")
	otherConfirm := confirmCompetitionPlanDraftForTest(t, handler, other.ID, draft.ID)
	if otherConfirm.Code != http.StatusNotFound {
		t.Fatalf("other status=%d body=%s", otherConfirm.Code, otherConfirm.Body.String())
	}

	first := confirmCompetitionPlanDraftForTest(t, handler, owner.ID, draft.ID)
	if first.Code != http.StatusOK {
		t.Fatalf("confirm status=%d body=%s", first.Code, first.Body.String())
	}
	second := confirmCompetitionPlanDraftForTest(t, handler, owner.ID, draft.ID)
	if second.Code != http.StatusOK {
		t.Fatalf("repeat status=%d body=%s", second.Code, second.Body.String())
	}
	var items []models.UserCompetitionCalendarItem
	if err := db.Where("user_id = ? AND source_event_id = ?", owner.ID, event.ID).Find(&items).Error; err != nil || len(items) != 1 {
		t.Fatalf("items=%d err=%v", len(items), err)
	}
	var stored models.AIActionDraft
	if err := db.First(&stored, draft.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Status != "executed" || stored.ResultResourceID == nil || *stored.ResultResourceID != items[0].ID {
		t.Fatalf("stored draft=%+v", stored)
	}
	var actions []string
	if err := db.Model(&models.AIActionAuditLog{}).Where("draft_id = ?", draft.ID).Order("id").Pluck("action", &actions).Error; err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(actions) != "[draft_created draft_confirmed draft_executed]" {
		t.Fatalf("actions=%v", actions)
	}
}

func TestCompetitionPlanDraftExpiresAndCancelledDraftCannotExecute(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	user, expiredEvent := createAIActionTestUserAndEvent(t, db, "expired")
	expired := createCompetitionPlanDraftForTest(t, handler, user.ID, expiredEvent.ID, "expired-request")
	if err := db.Model(&models.AIActionDraft{}).Where("id = ?", expired.ID).Update("expires_at", time.Now().Add(-time.Minute)).Error; err != nil {
		t.Fatal(err)
	}
	result := confirmCompetitionPlanDraftForTest(t, handler, user.ID, expired.ID)
	if result.Code != http.StatusConflict || !bytes.Contains(result.Body.Bytes(), []byte("action_draft_expired")) {
		t.Fatalf("expired status=%d body=%s", result.Code, result.Body.String())
	}

	_, cancelEvent := createAIActionTestUserAndEvent(t, db, "cancel")
	// 第二个测试用户事件仍对当前用户满足通用专业资格。
	cancelled := createCompetitionPlanDraftForTest(t, handler, user.ID, cancelEvent.ID, "cancel-request")
	cancel := performAIActionRequest(
		t, http.MethodPost, fmt.Sprintf("/api/user/ai-action-drafts/%d/cancel", cancelled.ID), "{}", user.ID,
		gin.Params{{Key: "id", Value: fmt.Sprint(cancelled.ID)}}, nil, handler.CancelAIActionDraft,
	)
	if cancel.Code != http.StatusOK {
		t.Fatalf("cancel status=%d body=%s", cancel.Code, cancel.Body.String())
	}
	afterCancel := confirmCompetitionPlanDraftForTest(t, handler, user.ID, cancelled.ID)
	if afterCancel.Code != http.StatusConflict {
		t.Fatalf("confirm cancelled status=%d body=%s", afterCancel.Code, afterCancel.Body.String())
	}
	var count int64
	if err := db.Model(&models.UserCompetitionCalendarItem{}).Where("user_id = ?", user.ID).Count(&count).Error; err != nil || count != 0 {
		t.Fatalf("plan count=%d err=%v", count, err)
	}
}

func TestCompetitionPlanDraftRefreshesPresentationButRejectsCriticalChanges(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	user, event := createAIActionTestUserAndEvent(t, db, "refresh")
	draft := createCompetitionPlanDraftForTest(t, handler, user.ID, event.ID, "refresh-request")
	if err := db.Model(&event).Updates(map[string]interface{}{"title": "更新后的比赛名称", "version": event.Version + 1}).Error; err != nil {
		t.Fatal(err)
	}
	refresh := confirmCompetitionPlanDraftForTest(t, handler, user.ID, draft.ID)
	if refresh.Code != http.StatusConflict || !bytes.Contains(refresh.Body.Bytes(), []byte("action_draft_preview_changed")) {
		t.Fatalf("refresh status=%d body=%s", refresh.Code, refresh.Body.String())
	}
	confirmed := confirmCompetitionPlanDraftForTest(t, handler, user.ID, draft.ID)
	if confirmed.Code != http.StatusOK {
		t.Fatalf("confirm refreshed status=%d body=%s", confirmed.Code, confirmed.Body.String())
	}

	_, criticalEvent := createAIActionTestUserAndEvent(t, db, "critical")
	critical := createCompetitionPlanDraftForTest(t, handler, user.ID, criticalEvent.ID, "critical-request")
	if err := db.Model(&criticalEvent).Updates(map[string]interface{}{
		"eligible_majors": jsonArray([]string{"机械设计制造及其自动化"}), "version": criticalEvent.Version + 1,
	}).Error; err != nil {
		t.Fatal(err)
	}
	rejected := confirmCompetitionPlanDraftForTest(t, handler, user.ID, critical.ID)
	if rejected.Code != http.StatusConflict || !bytes.Contains(rejected.Body.Bytes(), []byte("action_draft_invalid")) {
		t.Fatalf("critical status=%d body=%s", rejected.Code, rejected.Body.String())
	}
	var stored models.AIActionDraft
	if err := db.First(&stored, critical.ID).Error; err != nil || stored.Status != "failed" {
		t.Fatalf("stored=%+v err=%v", stored, err)
	}
}

func TestCompetitionPlanDraftBindsExistingPlanItem(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	user, event := createAIActionTestUserAndEvent(t, db, "existing")
	draft := createCompetitionPlanDraftForTest(t, handler, user.ID, event.ID, "existing-request")
	calendar, err := handler.ensureCalendarTx(db, user.ID)
	if err != nil {
		t.Fatal(err)
	}
	item := calendarItemFromEvent(calendar.ID, user.ID, event, "official", &event.ID, "", nil)
	if err := db.Create(&item).Error; err != nil {
		t.Fatal(err)
	}
	confirmed := confirmCompetitionPlanDraftForTest(t, handler, user.ID, draft.ID)
	if confirmed.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", confirmed.Code, confirmed.Body.String())
	}
	var stored models.AIActionDraft
	if err := db.First(&stored, draft.ID).Error; err != nil || stored.ResultResourceID == nil || *stored.ResultResourceID != item.ID {
		t.Fatalf("stored=%+v err=%v", stored, err)
	}
}
