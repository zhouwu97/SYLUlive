package handlers

import (
	"encoding/json"
	"errors"
	"io"
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

const competitionPlanActionType = "add_competition_to_plan"

type competitionPlanDraftResponse struct {
	ID         uint                `json:"id"`
	ActionType string              `json:"action_type"`
	Status     string              `json:"status"`
	ExpiresAt  time.Time           `json:"expires_at"`
	Event      CompetitionEventDTO `json:"event"`
	PlanItemID *uint               `json:"plan_item_id,omitempty"`
}

func (h *CompetitionHandler) CreateCompetitionPlanActionDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input struct {
		EventID uint `json:"event_id"`
	}
	if !decodeStrictAIActionBody(c, &input) || input.EventID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_draft", "message": "仅允许提交有效的 event_id"})
		return
	}
	idempotencyKey := strings.TrimSpace(c.GetHeader("Idempotency-Key"))
	if idempotencyKey == "" {
		idempotencyKey = uuid.NewString()
	}
	if len(idempotencyKey) > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_idempotency_key", "message": "幂等键过长"})
		return
	}
	now := time.Now().UTC()
	var response competitionPlanDraftResponse
	created := false
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		var existing models.AIActionDraft
		err := tx.Where("user_id = ? AND idempotency_key = ?", userID, idempotencyKey).First(&existing).Error
		if err == nil {
			if existing.CompetitionEventID != input.EventID {
				return errAIActionIdempotencyConflict
			}
			var loadErr error
			response, loadErr = h.loadCompetitionPlanDraftResponse(tx, existing)
			return loadErr
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		// 同一赛事已有有效待确认草稿时直接复用，避免模型重试制造重复草稿。
		if err := tx.Where("user_id = ? AND action_type = ? AND competition_event_id = ? AND status = ? AND expires_at > ?",
			userID, competitionPlanActionType, input.EventID, "pending", now).
			Order("id DESC").First(&existing).Error; err == nil {
			var loadErr error
			response, loadErr = h.loadCompetitionPlanDraftResponse(tx, existing)
			return loadErr
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		snapshot, event, err := h.createCompetitionRecommendationSnapshot(tx, userID, input.EventID, now)
		if err != nil {
			return err
		}
		draft := models.AIActionDraft{
			UserID: userID, ActionType: competitionPlanActionType, Status: "pending",
			CompetitionEventID: input.EventID, RecommendationSnapshotID: snapshot.ID,
			PayloadHash: competitionPlanDraftPayloadHash(snapshot, event), IdempotencyKey: idempotencyKey,
			CreatedAt: now, ExpiresAt: snapshot.ExpiresAt,
		}
		if err := tx.Create(&draft).Error; err != nil {
			return err
		}
		if err := createAIActionAudit(tx, draft, "draft_created", c.GetHeader("X-Client-Request-ID"), "pending", now); err != nil {
			return err
		}
		created = true
		response = competitionPlanDraftResponse{ID: draft.ID, ActionType: draft.ActionType, Status: draft.Status, ExpiresAt: draft.ExpiresAt, Event: event}
		return nil
	})
	if err != nil {
		handleCompetitionPlanDraftError(c, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	c.JSON(status, response)
}

func (h *CompetitionHandler) GetAIActionDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	draftID, ok := parseAIActionDraftID(c)
	if !ok {
		return
	}
	now := time.Now().UTC()
	var response competitionPlanDraftResponse
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		var draft models.AIActionDraft
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", draftID, userID).First(&draft).Error; err != nil {
			return errAIActionDraftNotFound
		}
		if draft.Status == "pending" && !draft.ExpiresAt.After(now) {
			if err := expireAIActionDraft(tx, &draft, now, c.GetHeader("X-Client-Request-ID")); err != nil {
				return err
			}
		}
		var err error
		response, err = h.loadCompetitionPlanDraftResponse(tx, draft)
		if err != nil {
			return err
		}
		return createAIActionAudit(tx, draft, "draft_viewed", c.GetHeader("X-Client-Request-ID"), draft.Status, now)
	})
	if err != nil {
		handleCompetitionPlanDraftError(c, err)
		return
	}
	c.JSON(http.StatusOK, response)
}

func (h *CompetitionHandler) ConfirmAIActionDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	if !decodeStrictAIActionBody(c, &struct{}{}) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_confirmation", "message": "确认操作不接受业务字段"})
		return
	}
	draftID, ok := parseAIActionDraftID(c)
	if !ok {
		return
	}
	now := time.Now().UTC()
	var response competitionPlanDraftResponse
	responseCode := http.StatusOK
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		var draft models.AIActionDraft
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", draftID, userID).First(&draft).Error; err != nil {
			return errAIActionDraftNotFound
		}
		if draft.ActionType != competitionPlanActionType {
			return errAIActionTypeUnsupported
		}
		if draft.Status == "executed" {
			var err error
			response, err = h.loadCompetitionPlanDraftResponse(tx, draft)
			return err
		}
		if draft.Status != "pending" {
			return aiActionStatusError(draft.Status)
		}
		if !draft.ExpiresAt.After(now) {
			if err := expireAIActionDraft(tx, &draft, now, c.GetHeader("X-Client-Request-ID")); err != nil {
				return err
			}
			responseCode = http.StatusConflict
			response, _ = h.loadCompetitionPlanDraftResponse(tx, draft)
			return nil
		}

		if item, found, err := findExistingOfficialPlanItem(tx, userID, draft.CompetitionEventID); err != nil {
			return err
		} else if found {
			return executeAIActionDraftWithItem(tx, &draft, item, now, c.GetHeader("X-Client-Request-ID"), "existing_plan_item", &response, h)
		}

		var oldSnapshot models.CompetitionRecommendationSnapshot
		if err := tx.Where("id = ? AND user_id = ?", draft.RecommendationSnapshotID, userID).First(&oldSnapshot).Error; err != nil {
			return errAIActionDraftInvalid
		}
		currentSnapshot, event, buildErr := h.buildCompetitionRecommendationSnapshot(tx, userID, draft.CompetitionEventID, now)
		if buildErr != nil {
			if errors.Is(buildErr, errCompetitionAlreadyPlanned) {
				existing, found, findErr := findExistingOfficialPlanItem(tx, userID, draft.CompetitionEventID)
				if findErr != nil {
					return findErr
				}
				if found {
					return executeAIActionDraftWithItem(
						tx,
						&draft,
						existing,
						now,
						c.GetHeader("X-Client-Request-ID"),
						"existing_plan_item",
						&response,
						h,
					)
				}
				return buildErr
			}
			if err := failAIActionDraft(tx, &draft, now, buildErr.Error(), c.GetHeader("X-Client-Request-ID")); err != nil {
				return err
			}
			responseCode = http.StatusConflict
			response, _ = h.loadCompetitionPlanDraftResponse(tx, draft)
			return nil
		}
		if oldSnapshot.EventCriticalHash != currentSnapshot.EventCriticalHash {
			if err := failAIActionDraft(tx, &draft, now, "event_critical_fields_changed", c.GetHeader("X-Client-Request-ID")); err != nil {
				return err
			}
			responseCode = http.StatusConflict
			response, _ = h.loadCompetitionPlanDraftResponse(tx, draft)
			return nil
		}
		currentPayloadHash := competitionPlanDraftPayloadHash(currentSnapshot, event)
		if oldSnapshot.EventVersion != currentSnapshot.EventVersion || draft.PayloadHash != currentPayloadHash {
			if err := tx.Create(&currentSnapshot).Error; err != nil {
				return err
			}
			draft.RecommendationSnapshotID = currentSnapshot.ID
			draft.PayloadHash = currentPayloadHash
			draft.ExpiresAt = currentSnapshot.ExpiresAt
			if err := tx.Model(&draft).Updates(map[string]interface{}{
				"recommendation_snapshot_id": currentSnapshot.ID, "payload_hash": currentPayloadHash,
				"expires_at": currentSnapshot.ExpiresAt,
			}).Error; err != nil {
				return err
			}
			if err := createAIActionAudit(tx, draft, "draft_viewed", c.GetHeader("X-Client-Request-ID"), "preview_refreshed", now); err != nil {
				return err
			}
			responseCode = http.StatusConflict
			response = competitionPlanDraftResponse{ID: draft.ID, ActionType: draft.ActionType, Status: draft.Status, ExpiresAt: draft.ExpiresAt, Event: event}
			return nil
		}

		calendar, err := h.ensureCalendarTx(tx, userID)
		if err != nil {
			return err
		}
		item := calendarItemFromEvent(calendar.ID, userID, event.CompetitionEvent, "official", &event.ID, "", nil)
		result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&item)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			existing, found, err := findExistingOfficialPlanItem(tx, userID, draft.CompetitionEventID)
			if err != nil {
				return err
			}
			if !found {
				return errAIActionDraftInvalid
			}
			item = existing
		}
		return executeAIActionDraftWithItem(tx, &draft, item, now, c.GetHeader("X-Client-Request-ID"), "created_plan_item", &response, h)
	})
	if err != nil {
		handleCompetitionPlanDraftError(c, err)
		return
	}
	if responseCode == http.StatusConflict {
		code := "action_draft_invalid"
		message := "该建议已经失效，请重新获取最新推荐"
		if response.Status == "pending" {
			code = "action_draft_preview_changed"
			message = "赛事信息已更新，请查看最新预览后重新确认"
		} else if response.Status == "expired" {
			code = "action_draft_expired"
		}
		c.JSON(responseCode, gin.H{"code": code, "message": message, "draft": response})
		return
	}
	c.JSON(http.StatusOK, response)
}

func (h *CompetitionHandler) CancelAIActionDraft(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	if !decodeStrictAIActionBody(c, &struct{}{}) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_cancellation", "message": "取消操作不接受业务字段"})
		return
	}
	draftID, ok := parseAIActionDraftID(c)
	if !ok {
		return
	}
	now := time.Now().UTC()
	var response competitionPlanDraftResponse
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		var draft models.AIActionDraft
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", draftID, userID).First(&draft).Error; err != nil {
			return errAIActionDraftNotFound
		}
		if draft.Status == "cancelled" {
			var err error
			response, err = h.loadCompetitionPlanDraftResponse(tx, draft)
			return err
		}
		if draft.Status != "pending" {
			return aiActionStatusError(draft.Status)
		}
		draft.Status = "cancelled"
		draft.CancelledAt = &now
		if err := tx.Model(&draft).Updates(map[string]interface{}{"status": "cancelled", "cancelled_at": now}).Error; err != nil {
			return err
		}
		if err := createAIActionAudit(tx, draft, "draft_cancelled", c.GetHeader("X-Client-Request-ID"), "cancelled", now); err != nil {
			return err
		}
		var err error
		response, err = h.loadCompetitionPlanDraftResponse(tx, draft)
		return err
	})
	if err != nil {
		handleCompetitionPlanDraftError(c, err)
		return
	}
	c.JSON(http.StatusOK, response)
}

var (
	errAIActionDraftNotFound       = errors.New("ai_action_draft_not_found")
	errAIActionDraftInvalid        = errors.New("ai_action_draft_invalid")
	errAIActionIdempotencyConflict = errors.New("ai_action_idempotency_conflict")
	errAIActionTypeUnsupported     = errors.New("ai_action_type_unsupported")
)

func aiActionStatusError(status string) error { return errors.New("ai_action_status_" + status) }

func decodeStrictAIActionBody(c *gin.Context, target interface{}) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return false
	}
	return decoder.Decode(&struct{}{}) == io.EOF
}

func parseAIActionDraftID(c *gin.Context) (uint, bool) {
	value, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || value == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_action_draft_id", "message": "草稿 ID 无效"})
		return 0, false
	}
	return uint(value), true
}

func competitionPlanDraftPayloadHash(snapshot models.CompetitionRecommendationSnapshot, event CompetitionEventDTO) string {
	return hashCompetitionSnapshotValue([]interface{}{
		snapshot.EventID, snapshot.EventVersion, snapshot.EventTitle,
		snapshot.CompetitionID, snapshot.DatasetVersion, snapshot.RecordHash,
		snapshot.Mode, snapshot.GroupKey, snapshot.MatchDimensions,
		snapshot.AIExplanationHash, snapshot.CapabilityHash, snapshot.FitReasons,
		event.CompetitionRating,
		event.ManualRating, event.SchoolRecognitionStatus, event.SchoolRecognitionGrade,
		event.TimeStatus, event.RegistrationTimeText,
	})
}

func (h *CompetitionHandler) loadCompetitionPlanDraftResponse(tx *gorm.DB, draft models.AIActionDraft) (competitionPlanDraftResponse, error) {
	var event models.CompetitionEvent
	if err := tx.Unscoped().First(&event, draft.CompetitionEventID).Error; err != nil {
		return competitionPlanDraftResponse{}, errAIActionDraftInvalid
	}
	var snapshot models.CompetitionRecommendationSnapshot
	if err := tx.Where("id = ? AND user_id = ?", draft.RecommendationSnapshotID, draft.UserID).First(&snapshot).Error; err != nil {
		return competitionPlanDraftResponse{}, errAIActionDraftInvalid
	}
	event.PersonalizedScore = snapshot.PersonalizedScore
	event.RecommendationTier = snapshot.RecommendationTier
	_ = json.Unmarshal(snapshot.FitReasons, &event.FitReasons)
	return competitionPlanDraftResponse{
		ID: draft.ID, ActionType: draft.ActionType, Status: draft.Status, ExpiresAt: draft.ExpiresAt,
		Event: competitionEventDTO(event), PlanItemID: draft.ResultResourceID,
	}, nil
}

func createAIActionAudit(tx *gorm.DB, draft models.AIActionDraft, action, clientRequestID, result string, now time.Time) error {
	return tx.Create(&models.AIActionAuditLog{
		DraftID: draft.ID, UserID: draft.UserID, Action: action, CreatedAt: now,
		ClientRequestID: strings.TrimSpace(clientRequestID), Result: result,
	}).Error
}

func expireAIActionDraft(tx *gorm.DB, draft *models.AIActionDraft, now time.Time, clientRequestID string) error {
	draft.Status = "expired"
	draft.FailureReason = "draft_expired"
	if err := tx.Model(draft).Updates(map[string]interface{}{"status": "expired", "failure_reason": draft.FailureReason}).Error; err != nil {
		return err
	}
	return createAIActionAudit(tx, *draft, "draft_expired", clientRequestID, "expired", now)
}

func failAIActionDraft(tx *gorm.DB, draft *models.AIActionDraft, now time.Time, reason, clientRequestID string) error {
	draft.Status = "failed"
	draft.FailureReason = reason
	if err := tx.Model(draft).Updates(map[string]interface{}{"status": "failed", "failure_reason": reason}).Error; err != nil {
		return err
	}
	return createAIActionAudit(tx, *draft, "draft_failed", clientRequestID, reason, now)
}

func findExistingOfficialPlanItem(tx *gorm.DB, userID, eventID uint) (models.UserCompetitionCalendarItem, bool, error) {
	var item models.UserCompetitionCalendarItem
	if err := tx.Where("user_id = ? AND source_type = ? AND source_event_id = ?", userID, "official", eventID).First(&item).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return item, false, nil
		}
		return item, false, err
	}
	return item, true, nil
}

func executeAIActionDraftWithItem(
	tx *gorm.DB,
	draft *models.AIActionDraft,
	item models.UserCompetitionCalendarItem,
	now time.Time,
	clientRequestID string,
	result string,
	response *competitionPlanDraftResponse,
	h *CompetitionHandler,
) error {
	draft.Status = "executed"
	draft.ConfirmedAt = &now
	draft.ExecutedAt = &now
	draft.ResultResourceType = "competition_calendar_item"
	draft.ResultResourceID = &item.ID
	if err := tx.Model(draft).Updates(map[string]interface{}{
		"status": "executed", "confirmed_at": now, "executed_at": now,
		"result_resource_type": draft.ResultResourceType, "result_resource_id": item.ID,
	}).Error; err != nil {
		return err
	}
	if err := createAIActionAudit(tx, *draft, "draft_confirmed", clientRequestID, result, now); err != nil {
		return err
	}
	if err := createAIActionAudit(tx, *draft, "draft_executed", clientRequestID, result, now); err != nil {
		return err
	}
	var err error
	*response, err = h.loadCompetitionPlanDraftResponse(tx, *draft)
	return err
}

func handleCompetitionPlanDraftError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, errAIActionDraftNotFound), errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(http.StatusNotFound, gin.H{"code": "action_draft_not_found", "message": "操作草稿不存在"})
	case errors.Is(err, errAIActionIdempotencyConflict):
		c.JSON(http.StatusConflict, gin.H{"code": "action_draft_idempotency_conflict", "message": "同一幂等键不能用于不同操作"})
	case errors.Is(err, errCompetitionProfileUnavailable):
		c.JSON(http.StatusConflict, gin.H{"code": "competition_profile_unavailable", "message": "当前竞赛基础画像不可用"})
	case errors.Is(err, errCompetitionEventUnavailable):
		c.JSON(http.StatusConflict, gin.H{"code": "competition_event_unavailable", "message": "赛事不存在或已下架"})
	case errors.Is(err, errCompetitionNotMatched):
		c.JSON(http.StatusConflict, gin.H{"code": "competition_not_matched", "message": "赛事已不在当前确定性适配结果中"})
	case errors.Is(err, errCompetitionAlreadyPlanned):
		c.JSON(http.StatusConflict, gin.H{"code": "competition_already_planned", "message": "赛事已在我的计划中"})
	case strings.HasPrefix(err.Error(), "ai_action_status_"):
		c.JSON(http.StatusConflict, gin.H{"code": "action_draft_status_conflict", "message": "当前草稿状态不能执行该操作"})
	case errors.Is(err, errAIActionDraftInvalid), errors.Is(err, errAIActionTypeUnsupported):
		c.JSON(http.StatusConflict, gin.H{"code": "action_draft_invalid", "message": "该建议已经失效，请重新获取最新推荐"})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"code": "action_draft_failed", "message": "处理操作草稿失败"})
	}
}
