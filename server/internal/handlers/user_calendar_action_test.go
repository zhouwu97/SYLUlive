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

func newUserCalendarActionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db := newCompetitionTestDB(t)
	if err := db.AutoMigrate(
		&models.UserCalendar{},
		&models.UserCalendarEvent{},
		&models.UserCalendarReminder{},
		&models.UserCalendarActionDraft{},
		&models.UserCalendarActionAudit{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

func createCalendarActionTestUser(t *testing.T, db *gorm.DB, suffix string) models.User {
	t.Helper()
	user := models.User{StudentID: "calendar-action-" + suffix, PasswordHash: "x", Nickname: "日历用户"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	return user
}

func createCalendarActionTestEvent(t *testing.T, db *gorm.DB, userID uint, suffix string) models.UserCalendarEvent {
	t.Helper()
	calendar := models.UserCalendar{UserID: userID, Name: "我的日历-" + suffix, Timezone: calendarDefaultTimezone, IsDefault: true}
	if err := db.Create(&calendar).Error; err != nil {
		t.Fatal(err)
	}
	event := models.UserCalendarEvent{
		UserID: userID, CalendarID: calendar.ID, Title: "原始事件", Description: "原始描述",
		StartAt: time.Date(2026, 8, 23, 9, 0, 0, 0, time.UTC), EndAt: time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC),
		Timezone: calendarDefaultTimezone, SourceType: models.UserCalendarSourceManual,
		SyncMode: "snapshot", CreatedBy: models.UserCalendarCreatedByUser,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	return event
}

func calendarActionRequest(t *testing.T, handler func(*gin.Context), method, path, body string, userID, id uint) *httptest.ResponseRecorder {
	t.Helper()
	params := gin.Params{}
	if id != 0 {
		params = gin.Params{{Key: "id", Value: fmt.Sprint(id)}}
	}
	return performAIActionRequest(t, method, path, body, userID, params, map[string]string{"Idempotency-Key": fmt.Sprintf("test-%d", time.Now().UnixNano())}, handler)
}

func TestCalendarActionDraftSupportsCreateUpdateDeleteAndReminder(t *testing.T) {
	db := newUserCalendarActionTestDB(t)
	handler := NewUserCalendarHandler(db)
	user := createCalendarActionTestUser(t, db, "lifecycle")
	event := createCalendarActionTestEvent(t, db, user.ID, "lifecycle")

	create := calendarActionRequest(t, handler.CreateCalendarEventDraft, http.MethodPost, "/ai/action-drafts/calendar-event", `{"action_type":"calendar_event_create","title":"新事件","start_at":"2026-08-24T09:00:00Z","end_at":"2026-08-24T10:00:00Z"}`, user.ID, 0)
	if create.Code != http.StatusCreated {
		t.Fatalf("create draft status=%d body=%s", create.Code, create.Body.String())
	}
	var createResponse calendarActionResponse
	if err := json.Unmarshal(create.Body.Bytes(), &createResponse); err != nil {
		t.Fatal(err)
	}
	confirmedCreate := calendarActionRequest(t, handler.ConfirmCalendarEventDraft, http.MethodPost, fmt.Sprintf("/user/calendar-action-drafts/%d/confirm", createResponse.ID), `{}`, user.ID, createResponse.ID)
	if confirmedCreate.Code != http.StatusOK || !containsJSON(confirmedCreate.Body.Bytes(), "executed") {
		t.Fatalf("confirm create status=%d body=%s", confirmedCreate.Code, confirmedCreate.Body.String())
	}

	update := calendarActionRequest(t, handler.CreateCalendarEventDraft, http.MethodPost, "/ai/action-drafts/calendar-event", fmt.Sprintf(`{"action_type":"calendar_event_update","event_id":%d,"title":"更新后的事件"}`, event.ID), user.ID, 0)
	if update.Code != http.StatusCreated {
		t.Fatalf("update draft status=%d body=%s", update.Code, update.Body.String())
	}
	var updateResponse calendarActionResponse
	if err := json.Unmarshal(update.Body.Bytes(), &updateResponse); err != nil {
		t.Fatal(err)
	}
	confirmedUpdate := calendarActionRequest(t, handler.ConfirmCalendarEventDraft, http.MethodPost, "/confirm", `{}`, user.ID, updateResponse.ID)
	if confirmedUpdate.Code != http.StatusOK {
		t.Fatalf("confirm update status=%d body=%s", confirmedUpdate.Code, confirmedUpdate.Body.String())
	}
	var stored models.UserCalendarEvent
	if err := db.First(&stored, event.ID).Error; err != nil || stored.Title != "更新后的事件" {
		t.Fatalf("updated event=%+v err=%v", stored, err)
	}

	reminder := calendarActionRequest(t, handler.CreateCalendarReminderDraft, http.MethodPost, "/ai/action-drafts/calendar-reminder", fmt.Sprintf(`{"event_id":%d,"reminder_minutes_before":30}`, event.ID), user.ID, 0)
	if reminder.Code != http.StatusCreated {
		t.Fatalf("reminder draft status=%d body=%s", reminder.Code, reminder.Body.String())
	}
	var reminderResponse calendarActionResponse
	if err := json.Unmarshal(reminder.Body.Bytes(), &reminderResponse); err != nil {
		t.Fatal(err)
	}
	confirmedReminder := calendarActionRequest(t, handler.ConfirmCalendarEventDraft, http.MethodPost, "/confirm", `{}`, user.ID, reminderResponse.ID)
	if confirmedReminder.Code != http.StatusOK {
		t.Fatalf("confirm reminder status=%d body=%s", confirmedReminder.Code, confirmedReminder.Body.String())
	}
	var reminders []models.UserCalendarReminder
	if err := db.Where("event_id = ?", event.ID).Find(&reminders).Error; err != nil || len(reminders) != 1 || reminders[0].MinutesBefore != 30 {
		t.Fatalf("reminders=%+v err=%v", reminders, err)
	}

	deleteDraft := calendarActionRequest(t, handler.CreateCalendarEventDraft, http.MethodPost, "/ai/action-drafts/calendar-event", fmt.Sprintf(`{"action_type":"calendar_event_delete","event_id":%d}`, event.ID), user.ID, 0)
	if deleteDraft.Code != http.StatusCreated {
		t.Fatalf("delete draft status=%d body=%s", deleteDraft.Code, deleteDraft.Body.String())
	}
	var deleteResponse calendarActionResponse
	if err := json.Unmarshal(deleteDraft.Body.Bytes(), &deleteResponse); err != nil {
		t.Fatal(err)
	}
	confirmedDelete := calendarActionRequest(t, handler.ConfirmCalendarEventDraft, http.MethodPost, "/confirm", `{}`, user.ID, deleteResponse.ID)
	if confirmedDelete.Code != http.StatusOK {
		t.Fatalf("confirm delete status=%d body=%s", confirmedDelete.Code, confirmedDelete.Body.String())
	}
	var deleted models.UserCalendarEvent
	if err := db.Unscoped().First(&deleted, event.ID).Error; err != nil || !deleted.DeletedAt.Valid {
		t.Fatalf("deleted event=%+v err=%v", deleted, err)
	}
}

func TestCalendarActionDraftIsIdempotentAndOwned(t *testing.T) {
	db := newUserCalendarActionTestDB(t)
	handler := NewUserCalendarHandler(db)
	owner := createCalendarActionTestUser(t, db, "owner")
	other := createCalendarActionTestUser(t, db, "other")
	payload := `{"action_type":"calendar_event_create","title":"幂等事件","start_at":"2026-08-24T09:00:00Z","end_at":"2026-08-24T10:00:00Z"}`
	first := performAIActionRequest(t, http.MethodPost, "/ai/action-drafts/calendar-event", payload, owner.ID, nil, map[string]string{"Idempotency-Key": "same-key"}, handler.CreateCalendarEventDraft)
	if first.Code != http.StatusCreated {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	retry := performAIActionRequest(t, http.MethodPost, "/ai/action-drafts/calendar-event", payload, owner.ID, nil, map[string]string{"Idempotency-Key": "same-key"}, handler.CreateCalendarEventDraft)
	if retry.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s", retry.Code, retry.Body.String())
	}
	var firstResponse, retryResponse calendarActionResponse
	_ = json.Unmarshal(first.Body.Bytes(), &firstResponse)
	_ = json.Unmarshal(retry.Body.Bytes(), &retryResponse)
	if firstResponse.ID != retryResponse.ID {
		t.Fatalf("idempotency IDs differ: %d vs %d", firstResponse.ID, retryResponse.ID)
	}
	otherConfirm := calendarActionRequest(t, handler.ConfirmCalendarEventDraft, http.MethodPost, "/confirm", `{}`, other.ID, firstResponse.ID)
	if otherConfirm.Code != http.StatusNotFound {
		t.Fatalf("ownership status=%d body=%s", otherConfirm.Code, otherConfirm.Body.String())
	}
}

func containsJSON(body []byte, value string) bool {
	return string(body) != "" && bytes.Contains(body, []byte(value))
}
