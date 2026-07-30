package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/competitioncontext"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const competitionRecommendationSnapshotTTL = 30 * time.Minute

var (
	errCompetitionProfileUnavailable = errors.New("competition_profile_unavailable")
	errCompetitionEventUnavailable   = errors.New("competition_event_unavailable")
	errCompetitionNotMatched         = errors.New("competition_not_matched")
	errCompetitionAlreadyPlanned     = errors.New("competition_already_planned")
)

// createCompetitionRecommendationSnapshot 只接受赛事 ID，评分、分层和理由全部由服务端重新计算。
func (h *CompetitionHandler) createCompetitionRecommendationSnapshot(
	tx *gorm.DB,
	userID uint,
	eventID uint,
	now time.Time,
) (models.CompetitionRecommendationSnapshot, CompetitionEventDTO, error) {
	snapshot, dto, err := h.buildCompetitionRecommendationSnapshot(tx, userID, eventID, now)
	if err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, err
	}
	if err := tx.Create(&snapshot).Error; err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, err
	}
	return snapshot, dto, nil
}

func (h *CompetitionHandler) buildCompetitionRecommendationSnapshot(
	tx *gorm.DB,
	userID uint,
	eventID uint,
	now time.Time,
) (models.CompetitionRecommendationSnapshot, CompetitionEventDTO, error) {
	var existing int64
	if err := tx.Model(&models.UserCompetitionCalendarItem{}).
		Where("user_id = ? AND source_type = ? AND source_event_id = ?", userID, "official", eventID).
		Count(&existing).Error; err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, err
	}
	if existing > 0 {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, errCompetitionAlreadyPlanned
	}

	ctx := tx.Statement.Context
	candidateResult, err := services.NewCompetitionCandidateEngineWithClock(
		tx,
		func() time.Time { return now },
	).BuildCandidates(ctx, userID, services.CandidateFilter{
		Page: 1, PageSize: 1, EventID: eventID,
	})
	if err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, err
	}
	if !candidateResult.ProfileReady {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, errCompetitionProfileUnavailable
	}
	if candidateResult.Total == 0 ||
		len(candidateResult.Groups) == 0 ||
		len(candidateResult.Groups[0].Items) == 0 {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, errCompetitionNotMatched
	}
	candidate := candidateResult.Groups[0].Items[0]

	var event models.CompetitionEvent
	if err := tx.Preload("PrimaryCategory").
		Where("id = ? AND status = ?", eventID, "published").
		First(&event).Error; err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, errCompetitionEventUnavailable
	}
	preference, configured, err := loadCompetitionPreferenceTx(tx, userID)
	if err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, err
	}
	var preferenceUpdatedAt *time.Time
	if configured {
		updatedAt := preference.UpdatedAt
		preferenceUpdatedAt = &updatedAt
	}

	userContext, err := competitioncontext.NewBuilder(tx).
		BuildCompetitionUserContext(ctx, userID)
	if err != nil {
		return models.CompetitionRecommendationSnapshot{}, CompetitionEventDTO{}, err
	}
	event.FitLevel = candidate.GroupKey
	event.FitReasons = []string{candidate.CoreReason}
	event.PersonalizedScore = nil
	event.RecommendationTier = ""
	fitReasons, _ := json.Marshal(event.FitReasons)
	matchDimensions, _ := json.Marshal(candidate.MatchDimensions)
	mode := candidate.Gates.AIMode
	if mode == "" {
		mode = candidateResult.Catalog.Mode
	}
	snapshot := models.CompetitionRecommendationSnapshot{
		UserID: userID, EventID: event.ID, EventVersion: event.Version, EventTitle: event.Title,
		CompetitionID: candidate.CompetitionID, DatasetVersion: candidate.DatasetVersion,
		RecordHash: candidate.RecordHash, Mode: mode, GroupKey: candidate.GroupKey,
		MatchDimensions:   datatypes.JSON(matchDimensions),
		PersonalizedScore: nil, RecommendationTier: "",
		FitReasons: datatypes.JSON(fitReasons), PreferenceUpdatedAt: preferenceUpdatedAt,
		CapabilityHash:    userContext.ProfileVersion,
		EventCriticalHash: competitionEventCriticalHash(event),
		CreatedAt:         now, ExpiresAt: now.Add(competitionRecommendationSnapshotTTL),
	}
	return snapshot, competitionEventDTO(event), nil
}

func loadCompetitionPreferenceTx(db *gorm.DB, userID uint) (models.UserCompetitionPreference, bool, error) {
	var preference models.UserCompetitionPreference
	if err := db.Where("user_id = ?", userID).First(&preference).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return preference, false, nil
		}
		return preference, false, err
	}
	return preference, true, nil
}

func competitionEventCriticalHash(event models.CompetitionEvent) string {
	return hashCompetitionSnapshotValue([]interface{}{
		event.Status, event.EligibleEntryYears, event.EligibleColleges, event.EligibleMajors,
		event.RegistrationEnd, event.EventStart, event.EventEnd, event.TimeStatus,
		event.CompetitionID, event.DatasetVersion, event.RecordHash,
		event.CandidatePoolAllowed, event.PersonalizedRankingAllowed,
		event.StrongRecommendationEligible, event.AIMode,
	})
}

func hashCompetitionSnapshotValue(value interface{}) string {
	encoded, _ := json.Marshal(value)
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:])
}
