package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const calendarDefaultTimezone = "Asia/Shanghai"

type UserCalendarHandler struct{ db *gorm.DB }

func NewUserCalendarHandler(db *gorm.DB) *UserCalendarHandler { return &UserCalendarHandler{db: db} }

type calendarEventInput struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	StartAt     string `json:"start_at"`
	EndAt       string `json:"end_at"`
	AllDay      bool   `json:"all_day"`
	Location    string `json:"location"`
	Timezone    string `json:"timezone"`
}

type calendarEventPatchInput struct {
	Title       *string `json:"title"`
	Description *string `json:"description"`
	StartAt     *string `json:"start_at"`
	EndAt       *string `json:"end_at"`
	AllDay      *bool   `json:"all_day"`
	Location    *string `json:"location"`
	Timezone    *string `json:"timezone"`
	Version     *int64  `json:"version"`
}

type calendarActionDraftInput struct {
	ActionType            string  `json:"action_type"`
	EventID               uint    `json:"event_id"`
	Title                 *string `json:"title"`
	Description           *string `json:"description"`
	StartAt               *string `json:"start_at"`
	EndAt                 *string `json:"end_at"`
	AllDay                *bool   `json:"all_day"`
	Location              *string `json:"location"`
	Timezone              *string `json:"timezone"`
	ReminderMinutesBefore *int    `json:"reminder_minutes_before"`
}

type calendarActionResponse struct {
	ID              uint                      `json:"id"`
	ActionType      string                    `json:"action_type"`
	Status          string                    `json:"status"`
	Title           string                    `json:"title"`
	Description     string                    `json:"description"`
	StartAt         time.Time                 `json:"start_at"`
	EndAt           time.Time                 `json:"end_at"`
	AllDay          bool                      `json:"all_day"`
	Location        string                    `json:"location"`
	Timezone        string                    `json:"timezone"`
	ExpiresAt       time.Time                 `json:"expires_at"`
	TargetEventID   *uint                     `json:"target_event_id,omitempty"`
	ReminderMinutes *int                      `json:"reminder_minutes_before,omitempty"`
	CalendarEventID *uint                     `json:"calendar_event_id,omitempty"`
	Event           *models.UserCalendarEvent `json:"event,omitempty"`
}

func (h *UserCalendarHandler) ListEvents(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	query := h.db.WithContext(c.Request.Context()).Where("user_id = ?", userID)
	if value := strings.TrimSpace(c.Query("from")); value != "" {
		from, err := parseCalendarTime(value)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_range"})
			return
		}
		query = query.Where("start_at >= ?", from)
	}
	if value := strings.TrimSpace(c.Query("to")); value != "" {
		to, err := parseCalendarTime(value)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_range"})
			return
		}
		query = query.Where("start_at < ?", to)
	}
	var events []models.UserCalendarEvent
	if err := query.Order("start_at ASC").Order("id ASC").Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_unavailable", "message": "读取日历失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"events": events})
}

func (h *UserCalendarHandler) CreateEvent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input calendarEventInput
	if !decodeStrictAIActionBody(c, &input) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_event"})
		return
	}
	event, err := h.buildEvent(userID, input, models.UserCalendarCreatedByUser)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_event", "message": err.Error()})
		return
	}
	err = h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		calendar, err := h.ensureDefaultCalendarTx(tx, userID)
		if err != nil {
			return err
		}
		event.CalendarID = calendar.ID
		return tx.Create(&event).Error
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_write_failed", "message": "创建日历事件失败"})
		return
	}
	c.JSON(http.StatusCreated, event)
}

func (h *UserCalendarHandler) UpdateEvent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	var input calendarEventPatchInput
	if !decodeStrictAIActionBody(c, &input) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_event"})
		return
	}
	var event models.UserCalendarEvent
	if err := h.db.Where("id = ? AND user_id = ?", id, userID).First(&event).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_event_not_found"})
		return
	}
	if input.Version != nil && *input.Version != event.Version {
		c.JSON(http.StatusConflict, gin.H{"code": "calendar_event_version_conflict"})
		return
	}
	if input.Title != nil {
		event.Title = *input.Title
	}
	if input.Description != nil {
		event.Description = *input.Description
	}
	if input.AllDay != nil {
		event.AllDay = *input.AllDay
	}
	if input.Location != nil {
		event.Location = *input.Location
	}
	if input.Timezone != nil {
		event.Timezone = strings.TrimSpace(*input.Timezone)
	}
	if input.StartAt != nil {
		parsed, err := parseCalendarTime(*input.StartAt)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_event_time"})
			return
		}
		event.StartAt = parsed
	}
	if input.EndAt != nil {
		parsed, err := parseCalendarTime(*input.EndAt)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_event_time"})
			return
		}
		event.EndAt = parsed
	}
	if err := validateCalendarEvent(event.Title, event.Description, event.StartAt, event.EndAt, event.Location, event.Timezone); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_event", "message": err.Error()})
		return
	}
	event.Version++
	if err := h.db.Model(&event).Select("title", "description", "start_at", "end_at", "all_day", "location", "timezone", "version").Updates(&event).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_write_failed"})
		return
	}
	c.JSON(http.StatusOK, event)
}

func (h *UserCalendarHandler) DeleteEvent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	result := h.db.Where("id = ? AND user_id = ?", id, userID).Delete(&models.UserCalendarEvent{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_write_failed"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_event_not_found"})
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *UserCalendarHandler) ListReminders(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	eventID, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	if !h.ownsEvent(userID, eventID) {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_event_not_found"})
		return
	}
	var reminders []models.UserCalendarReminder
	if err := h.db.Where("event_id = ? AND user_id = ?", eventID, userID).Order("minutes_before ASC").Find(&reminders).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_unavailable"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"reminders": reminders})
}

func (h *UserCalendarHandler) CreateReminder(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	eventID, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	if !h.ownsEvent(userID, eventID) {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_event_not_found"})
		return
	}
	var input struct {
		MinutesBefore int `json:"minutes_before"`
	}
	if !decodeStrictAIActionBody(c, &input) || input.MinutesBefore < 0 || input.MinutesBefore > 7*24*60 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_reminder"})
		return
	}
	reminder := models.UserCalendarReminder{UserID: userID, EventID: eventID, MinutesBefore: input.MinutesBefore, CreatedBy: models.UserCalendarCreatedByUser}
	if err := h.db.Where("user_id = ? AND event_id = ? AND minutes_before = ?", userID, eventID, input.MinutesBefore).First(&reminder).Error; err == nil {
		c.JSON(http.StatusOK, reminder)
		return
	}
	if err := h.db.Create(&reminder).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_write_failed"})
		return
	}
	c.JSON(http.StatusCreated, reminder)
}

func (h *UserCalendarHandler) DeleteReminder(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	eventID, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	reminderID, err := strconv.ParseUint(c.Param("reminder_id"), 10, 64)
	if err != nil || reminderID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_reminder"})
		return
	}
	result := h.db.Where("id = ? AND event_id = ? AND user_id = ?", reminderID, eventID, userID).Delete(&models.UserCalendarReminder{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_write_failed"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_reminder_not_found"})
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *UserCalendarHandler) Unified(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var events []models.UserCalendarEvent
	if err := h.db.Where("user_id = ?", userID).Order("start_at ASC").Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_unavailable"})
		return
	}
	var competitionCalendar models.UserCompetitionCalendar
	var competitionItems []models.UserCompetitionCalendarItem
	if err := h.db.Where("user_id = ?", userID).First(&competitionCalendar).Error; err == nil {
		if err := h.db.Where("calendar_id = ?", competitionCalendar.ID).Order("is_pinned DESC").Order("sort_date ASC").Find(&competitionItems).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"code": "calendar_unavailable"})
			return
		}
	}
	c.JSON(http.StatusOK, gin.H{"events": events, "competition_items": competitionItems, "generated_at": time.Now().UTC()})
}

func (h *UserCalendarHandler) CreateCalendarEventDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input calendarActionDraftInput
	if !decodeStrictAIActionBody(c, &input) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_draft"})
		return
	}
	draft, created, err := h.createCalendarActionDraft(c, userID, input, models.UserCalendarActionCreate)
	if err != nil {
		writeCalendarActionDraftError(c, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	c.JSON(status, calendarActionDraftResponse(draft))
}

func (h *UserCalendarHandler) CreateCalendarReminderDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input calendarActionDraftInput
	if !decodeStrictAIActionBody(c, &input) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_draft"})
		return
	}
	draft, created, err := h.createCalendarActionDraft(c, userID, input, models.UserCalendarActionReminderCreate)
	if err != nil {
		writeCalendarActionDraftError(c, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	c.JSON(status, calendarActionDraftResponse(draft))
}

func (h *UserCalendarHandler) createCalendarActionDraft(
	c *gin.Context,
	userID uint,
	input calendarActionDraftInput,
	forcedAction string,
) (models.UserCalendarActionDraft, bool, error) {
	actionType := strings.TrimSpace(input.ActionType)
	if actionType == "" {
		actionType = forcedAction
	}
	if actionType != models.UserCalendarActionCreate &&
		actionType != models.UserCalendarActionUpdate &&
		actionType != models.UserCalendarActionDelete &&
		actionType != models.UserCalendarActionReminderCreate {
		return models.UserCalendarActionDraft{}, false, errors.New("calendar_action_type_unsupported")
	}
	if forcedAction == models.UserCalendarActionReminderCreate && actionType != forcedAction {
		return models.UserCalendarActionDraft{}, false, errors.New("calendar_action_type_unsupported")
	}
	if forcedAction != models.UserCalendarActionReminderCreate && actionType == models.UserCalendarActionReminderCreate {
		return models.UserCalendarActionDraft{}, false, errors.New("calendar_action_type_unsupported")
	}

	var target *models.UserCalendarEvent
	if actionType != models.UserCalendarActionCreate {
		if input.EventID == 0 {
			return models.UserCalendarActionDraft{}, false, errors.New("calendar_event_not_found")
		}
		var event models.UserCalendarEvent
		if err := h.db.Where("id = ? AND user_id = ?", input.EventID, userID).First(&event).Error; err != nil {
			return models.UserCalendarActionDraft{}, false, errors.New("calendar_event_not_found")
		}
		target = &event
	}
	event, err := h.actionEventPreview(userID, input, target, actionType)
	if err != nil {
		return models.UserCalendarActionDraft{}, false, err
	}
	if actionType == models.UserCalendarActionReminderCreate &&
		(input.ReminderMinutesBefore == nil || *input.ReminderMinutesBefore < 0 || *input.ReminderMinutesBefore > 7*24*60) {
		return models.UserCalendarActionDraft{}, false, errors.New("invalid_calendar_reminder")
	}
	idempotencyKey := strings.TrimSpace(c.GetHeader("Idempotency-Key"))
	if idempotencyKey == "" {
		idempotencyKey = uuid.NewString()
	}
	if len(idempotencyKey) > 100 {
		return models.UserCalendarActionDraft{}, false, errors.New("invalid_idempotency_key")
	}
	payloadHash := hashCalendarActionPayload(actionType, input.EventID, event, input.ReminderMinutesBefore)
	now := time.Now().UTC()
	var draft models.UserCalendarActionDraft
	created := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("user_id = ? AND idempotency_key = ?", userID, idempotencyKey).First(&draft).Error; err == nil {
			if draft.PayloadHash != payloadHash {
				return errors.New("calendar_action_idempotency_conflict")
			}
			return nil
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		draft = models.UserCalendarActionDraft{
			UserID: userID, ActionType: actionType, Status: "waiting_confirmation",
			Title: event.Title, Description: event.Description, StartAt: event.StartAt, EndAt: event.EndAt,
			AllDay: event.AllDay, Location: event.Location, Timezone: event.Timezone,
			PayloadHash: payloadHash, IdempotencyKey: idempotencyKey, ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
			TargetEventID: targetEventID(target), TargetEventVersion: targetEventVersion(target), ReminderMinutes: input.ReminderMinutesBefore,
		}
		created = true
		if err := tx.Create(&draft).Error; err != nil {
			return err
		}
		return tx.Create(&models.UserCalendarActionAudit{
			DraftID: draft.ID, UserID: userID, Action: "draft_created",
			ClientRequestID: strings.TrimSpace(c.GetHeader("X-Client-Request-ID")), Result: draft.Status, CreatedAt: now,
		}).Error
	})
	return draft, created, err
}

func (h *UserCalendarHandler) actionEventPreview(
	userID uint,
	input calendarActionDraftInput,
	target *models.UserCalendarEvent,
	actionType string,
) (models.UserCalendarEvent, error) {
	if actionType == models.UserCalendarActionDelete || actionType == models.UserCalendarActionReminderCreate {
		if target == nil {
			return models.UserCalendarEvent{}, errors.New("calendar_event_not_found")
		}
		return *target, nil
	}
	if actionType == models.UserCalendarActionCreate {
		if input.Title == nil || input.StartAt == nil || input.EndAt == nil {
			return models.UserCalendarEvent{}, errors.New("calendar_event_fields_required")
		}
		return h.buildEvent(userID, calendarEventInput{
			Title: *input.Title, Description: stringValue(input.Description), StartAt: *input.StartAt, EndAt: *input.EndAt,
			AllDay: boolValue(input.AllDay), Location: stringValue(input.Location), Timezone: stringValue(input.Timezone),
		}, models.UserCalendarCreatedByAgent)
	}
	if target == nil {
		return models.UserCalendarEvent{}, errors.New("calendar_event_not_found")
	}
	event := *target
	if input.Title != nil {
		event.Title = strings.TrimSpace(*input.Title)
	}
	if input.Description != nil {
		event.Description = strings.TrimSpace(*input.Description)
	}
	if input.AllDay != nil {
		event.AllDay = *input.AllDay
	}
	if input.Location != nil {
		event.Location = strings.TrimSpace(*input.Location)
	}
	if input.Timezone != nil {
		event.Timezone = strings.TrimSpace(*input.Timezone)
	}
	if input.StartAt != nil {
		parsed, err := parseCalendarTime(*input.StartAt)
		if err != nil {
			return models.UserCalendarEvent{}, errors.New("invalid_calendar_event_time")
		}
		event.StartAt = parsed
	}
	if input.EndAt != nil {
		parsed, err := parseCalendarTime(*input.EndAt)
		if err != nil {
			return models.UserCalendarEvent{}, errors.New("invalid_calendar_event_time")
		}
		event.EndAt = parsed
	}
	if err := validateCalendarEvent(event.Title, event.Description, event.StartAt, event.EndAt, event.Location, event.Timezone); err != nil {
		return models.UserCalendarEvent{}, err
	}
	return event, nil
}

func targetEventID(event *models.UserCalendarEvent) *uint {
	if event == nil {
		return nil
	}
	id := event.ID
	return &id
}

func targetEventVersion(event *models.UserCalendarEvent) int64 {
	if event == nil {
		return 0
	}
	return event.Version
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
func boolValue(value *bool) bool { return value != nil && *value }

func hashCalendarActionPayload(actionType string, eventID uint, event models.UserCalendarEvent, reminder *int) string {
	payload, _ := json.Marshal([]interface{}{actionType, eventID, event.Title, event.Description, event.StartAt, event.EndAt, event.AllDay, event.Location, event.Timezone, reminder})
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}

func writeCalendarActionDraftError(c *gin.Context, err error) {
	code := err.Error()
	status := http.StatusBadRequest
	switch code {
	case "calendar_action_idempotency_conflict":
		status, code = http.StatusConflict, "calendar_action_idempotency_conflict"
	case "calendar_event_not_found":
		status, code = http.StatusNotFound, "calendar_event_not_found"
	case "calendar_action_type_unsupported":
		status, code = http.StatusBadRequest, "calendar_action_type_unsupported"
	case "invalid_idempotency_key":
		status, code = http.StatusBadRequest, "invalid_idempotency_key"
	case "calendar_event_fields_required":
		status, code = http.StatusBadRequest, "calendar_event_fields_required"
	}
	c.JSON(status, gin.H{"code": code, "message": code})
}

func (h *UserCalendarHandler) GetCalendarEventDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	var draft models.UserCalendarActionDraft
	if err := h.db.Where("id = ? AND user_id = ?", id, userID).First(&draft).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_action_draft_not_found"})
		return
	}
	c.JSON(http.StatusOK, calendarActionDraftResponse(draft))
}

func (h *UserCalendarHandler) ConfirmCalendarEventDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	if !decodeStrictAIActionBody(c, &struct{}{}) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_confirmation"})
		return
	}
	id, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	now := time.Now().UTC()
	var response calendarActionResponse
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var draft models.UserCalendarActionDraft
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", id, userID).First(&draft).Error; err != nil {
			return gorm.ErrRecordNotFound
		}
		if draft.Status == "executed" {
			var event *models.UserCalendarEvent
			if draft.CalendarEventID != nil {
				var created models.UserCalendarEvent
				if err := tx.First(&created, *draft.CalendarEventID).Error; err == nil {
					event = &created
				}
			} else if draft.TargetEventID != nil {
				var target models.UserCalendarEvent
				if err := tx.First(&target, *draft.TargetEventID).Error; err == nil {
					event = &target
				}
			}
			response = calendarActionDraftResponseWithEvent(draft, event)
			return nil
		}
		if draft.Status != "waiting_confirmation" {
			return errors.New("calendar_action_status_" + draft.Status)
		}
		if !draft.ExpiresAt.After(now) {
			draft.Status = "expired"
			draft.FailureReason = "draft_expired"
			if err := tx.Model(&draft).Updates(map[string]interface{}{"status": draft.Status, "failure_reason": draft.FailureReason}).Error; err != nil {
				return err
			}
			response = calendarActionDraftResponse(draft)
			return nil
		}
		var event *models.UserCalendarEvent
		switch draft.ActionType {
		case models.UserCalendarActionCreate:
			calendar, err := h.ensureDefaultCalendarTx(tx, userID)
			if err != nil {
				return err
			}
			created := models.UserCalendarEvent{
				UserID: userID, CalendarID: calendar.ID, Title: draft.Title, Description: draft.Description,
				StartAt: draft.StartAt, EndAt: draft.EndAt, AllDay: draft.AllDay, Location: draft.Location,
				Timezone: draft.Timezone, SourceType: models.UserCalendarSourceAgentAction,
				SourceID: strconv.FormatUint(uint64(draft.ID), 10), SyncMode: "snapshot", CreatedBy: models.UserCalendarCreatedByAgent,
			}
			if err := tx.Create(&created).Error; err != nil {
				return err
			}
			event = &created
			draft.CalendarEventID = &created.ID
		case models.UserCalendarActionUpdate:
			if draft.TargetEventID == nil {
				return errors.New("calendar_event_not_found")
			}
			var target models.UserCalendarEvent
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", *draft.TargetEventID, userID).First(&target).Error; err != nil {
				return errors.New("calendar_event_not_found")
			}
			if draft.TargetEventVersion != 0 && target.Version != draft.TargetEventVersion {
				return errors.New("calendar_action_target_changed")
			}
			target.Title = draft.Title
			target.Description = draft.Description
			target.StartAt = draft.StartAt
			target.EndAt = draft.EndAt
			target.AllDay = draft.AllDay
			target.Location = draft.Location
			target.Timezone = draft.Timezone
			if err := validateCalendarEvent(target.Title, target.Description, target.StartAt, target.EndAt, target.Location, target.Timezone); err != nil {
				return err
			}
			target.Version++
			if err := tx.Model(&target).Select("title", "description", "start_at", "end_at", "all_day", "location", "timezone", "version").Updates(&target).Error; err != nil {
				return err
			}
			event = &target
		case models.UserCalendarActionDelete:
			if draft.TargetEventID == nil {
				return errors.New("calendar_event_not_found")
			}
			var target models.UserCalendarEvent
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", *draft.TargetEventID, userID).First(&target).Error; err != nil {
				return errors.New("calendar_event_not_found")
			}
			if draft.TargetEventVersion != 0 && target.Version != draft.TargetEventVersion {
				return errors.New("calendar_action_target_changed")
			}
			if err := tx.Delete(&target).Error; err != nil {
				return err
			}
		case models.UserCalendarActionReminderCreate:
			if draft.TargetEventID == nil || draft.ReminderMinutes == nil {
				return errors.New("calendar_event_not_found")
			}
			var target models.UserCalendarEvent
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", *draft.TargetEventID, userID).First(&target).Error; err != nil {
				return errors.New("calendar_event_not_found")
			}
			if draft.TargetEventVersion != 0 && target.Version != draft.TargetEventVersion {
				return errors.New("calendar_action_target_changed")
			}
			var reminder models.UserCalendarReminder
			err := tx.Where("event_id = ? AND user_id = ? AND minutes_before = ?", target.ID, userID, *draft.ReminderMinutes).First(&reminder).Error
			if errors.Is(err, gorm.ErrRecordNotFound) {
				reminder = models.UserCalendarReminder{UserID: userID, EventID: target.ID, MinutesBefore: *draft.ReminderMinutes, CreatedBy: models.UserCalendarCreatedByAgent}
				if err := tx.Create(&reminder).Error; err != nil {
					return err
				}
			} else if err != nil {
				return err
			}
			event = &target
		default:
			return errors.New("calendar_action_type_unsupported")
		}

		draft.Status = "executed"
		draft.ConfirmedAt = &now
		draft.ExecutedAt = &now
		updates := map[string]interface{}{"status": draft.Status, "confirmed_at": now, "executed_at": now}
		if draft.CalendarEventID != nil {
			updates["calendar_event_id"] = *draft.CalendarEventID
		}
		if err := tx.Model(&draft).Updates(updates).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.UserCalendarActionAudit{DraftID: draft.ID, UserID: userID, Action: "confirmed", ClientRequestID: strings.TrimSpace(c.GetHeader("X-Client-Request-ID")), Result: "executed", CreatedAt: now}).Error; err != nil {
			return err
		}
		response = calendarActionDraftResponseWithEvent(draft, event)
		return nil
	})
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"code": "calendar_action_draft_not_found"})
		} else if err.Error() == "calendar_action_target_changed" {
			c.JSON(http.StatusConflict, gin.H{"code": "calendar_action_target_changed", "message": "日历事件已发生变化，请重新确认最新草稿"})
		} else {
			c.JSON(http.StatusConflict, gin.H{"code": "calendar_action_draft_invalid"})
		}
		return
	}
	c.JSON(http.StatusOK, response)
}

func (h *UserCalendarHandler) CancelCalendarEventDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	if !decodeStrictAIActionBody(c, &struct{}{}) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_cancellation"})
		return
	}
	id, ok := parseUserCalendarID(c)
	if !ok {
		return
	}
	var draft models.UserCalendarActionDraft
	if err := h.db.Where("id = ? AND user_id = ?", id, userID).First(&draft).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"code": "calendar_action_draft_not_found"})
		return
	}
	if draft.Status == "waiting_confirmation" {
		now := time.Now().UTC()
		draft.Status = "cancelled"
		draft.CancelledAt = &now
		_ = h.db.Model(&draft).Updates(map[string]interface{}{"status": draft.Status, "cancelled_at": now}).Error
	}
	c.JSON(http.StatusOK, calendarActionDraftResponse(draft))
}

func (h *UserCalendarHandler) buildEvent(userID uint, input calendarEventInput, createdBy string) (models.UserCalendarEvent, error) {
	start, err := parseCalendarTime(input.StartAt)
	if err != nil {
		return models.UserCalendarEvent{}, errors.New("start_at 必须是 RFC3339 时间")
	}
	end, err := parseCalendarTime(input.EndAt)
	if err != nil {
		return models.UserCalendarEvent{}, errors.New("end_at 必须是 RFC3339 时间")
	}
	timezone := strings.TrimSpace(input.Timezone)
	if timezone == "" {
		timezone = calendarDefaultTimezone
	}
	if err := validateCalendarEvent(input.Title, input.Description, start, end, input.Location, timezone); err != nil {
		return models.UserCalendarEvent{}, err
	}
	return models.UserCalendarEvent{UserID: userID, Title: strings.TrimSpace(input.Title), Description: strings.TrimSpace(input.Description), StartAt: start, EndAt: end, AllDay: input.AllDay, Location: strings.TrimSpace(input.Location), Timezone: timezone, SourceType: models.UserCalendarSourceManual, SyncMode: "snapshot", CreatedBy: createdBy}, nil
}

func validateCalendarEvent(title, description string, start, end time.Time, location, timezone string) error {
	if strings.TrimSpace(title) == "" || len([]rune(title)) > 160 {
		return errors.New("标题不能为空且不超过 160 字")
	}
	if len([]rune(description)) > 4000 || len([]rune(location)) > 200 {
		return errors.New("描述或地点过长")
	}
	if !end.After(start) || end.Sub(start) > 366*24*time.Hour {
		return errors.New("事件时间范围无效")
	}
	if _, err := time.LoadLocation(timezone); err != nil {
		return errors.New("timezone 无效")
	}
	return nil
}

func parseCalendarTime(value string) (time.Time, error) {
	parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	return parsed.UTC(), err
}

func (h *UserCalendarHandler) ensureDefaultCalendarTx(tx *gorm.DB, userID uint) (models.UserCalendar, error) {
	var calendar models.UserCalendar
	if err := tx.Where("user_id = ? AND is_default = ?", userID, true).First(&calendar).Error; err == nil {
		return calendar, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return calendar, err
	}
	calendar = models.UserCalendar{UserID: userID, Name: "我的日历", Timezone: calendarDefaultTimezone, IsDefault: true}
	if err := tx.Create(&calendar).Error; err != nil {
		if err := tx.Where("user_id = ? AND is_default = ?", userID, true).First(&calendar).Error; err != nil {
			return calendar, err
		}
	}
	return calendar, nil
}

func (h *UserCalendarHandler) ownsEvent(userID, eventID uint) bool {
	var count int64
	h.db.Model(&models.UserCalendarEvent{}).Where("id = ? AND user_id = ?", eventID, userID).Count(&count)
	return count == 1
}

func parseUserCalendarID(c *gin.Context) (uint, bool) {
	value, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || value == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_calendar_id"})
		return 0, false
	}
	return uint(value), true
}

func hashCalendarEventPayload(event models.UserCalendarEvent) string {
	payload, _ := json.Marshal([]interface{}{event.Title, event.Description, event.StartAt, event.EndAt, event.AllDay, event.Location, event.Timezone})
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}

func calendarActionDraftResponse(draft models.UserCalendarActionDraft) calendarActionResponse {
	return calendarActionResponse{ID: draft.ID, ActionType: draft.ActionType, Status: draft.Status, Title: draft.Title, Description: draft.Description, StartAt: draft.StartAt, EndAt: draft.EndAt, AllDay: draft.AllDay, Location: draft.Location, Timezone: draft.Timezone, ExpiresAt: draft.ExpiresAt, TargetEventID: draft.TargetEventID, ReminderMinutes: draft.ReminderMinutes, CalendarEventID: draft.CalendarEventID}
}
func calendarActionDraftResponseWithEvent(draft models.UserCalendarActionDraft, event *models.UserCalendarEvent) calendarActionResponse {
	response := calendarActionDraftResponse(draft)
	response.Event = event
	return response
}
