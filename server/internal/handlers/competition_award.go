package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var competitionAwardRoles = map[string]struct{}{
	"developer": {}, "modeler": {}, "hardware": {}, "designer": {},
	"writer": {}, "presenter": {}, "organizer": {}, "leader": {},
	"member": {}, "other": {},
}

var competitionAwardStages = map[string]struct{}{
	"school": {}, "provincial": {}, "regional": {}, "national": {},
	"international": {}, "other": {},
}

var competitionAwardVisibilities = map[string]struct{}{
	"private": {}, "profile": {}, "team_matching": {},
}

type competitionAwardInput struct {
	CompetitionEventID  *uint    `json:"competition_event_id"`
	CompetitionTitle    string   `json:"competition_title"`
	TrackName           string   `json:"track_name"`
	CompetitionYear     int      `json:"competition_year"`
	AwardName           string   `json:"award_name"`
	AwardLevel          string   `json:"award_level"`
	CompetitionStage    string   `json:"competition_stage"`
	Role                string   `json:"role"`
	SkillTags           []string `json:"skill_tags"`
	ContributionSummary string   `json:"contribution_summary"`
	EvidenceFileIDs     []uint   `json:"evidence_file_ids"`
	Visibility          string   `json:"visibility"`
}

type competitionAwardResponse struct {
	ID                  uint       `json:"id"`
	CompetitionEventID  *uint      `json:"competition_event_id"`
	CompetitionTitle    string     `json:"competition_title"`
	TrackName           string     `json:"track_name"`
	CompetitionYear     int        `json:"competition_year"`
	AwardName           string     `json:"award_name"`
	AwardLevel          string     `json:"award_level"`
	CompetitionStage    string     `json:"competition_stage"`
	Role                string     `json:"role"`
	SkillTags           []string   `json:"skill_tags"`
	ContributionSummary string     `json:"contribution_summary"`
	EvidenceFileIDs     []uint     `json:"evidence_file_ids"`
	VerificationStatus  string     `json:"verification_status"`
	VerificationNote    string     `json:"verification_note"`
	VerifiedBy          *uint      `json:"verified_by,omitempty"`
	VerifiedAt          *time.Time `json:"verified_at,omitempty"`
	Visibility          string     `json:"visibility"`
	CreatedAt           time.Time  `json:"created_at"`
	UpdatedAt           time.Time  `json:"updated_at"`
}

func competitionAwardResponseFromModel(award models.UserCompetitionAward) competitionAwardResponse {
	return competitionAwardResponse{
		ID: award.ID, CompetitionEventID: award.CompetitionEventID,
		CompetitionTitle: award.CompetitionTitle, TrackName: award.TrackName,
		CompetitionYear: award.CompetitionYear, AwardName: award.AwardName,
		AwardLevel: award.AwardLevel, CompetitionStage: award.CompetitionStage,
		Role: award.Role, SkillTags: decodeStringArray(award.SkillTags),
		ContributionSummary: award.ContributionSummary,
		EvidenceFileIDs:     decodeUintArray(award.EvidenceFileIDs),
		VerificationStatus:  award.VerificationStatus, VerificationNote: award.VerificationNote,
		VerifiedBy: award.VerifiedBy, VerifiedAt: award.VerifiedAt,
		Visibility: award.Visibility, CreatedAt: award.CreatedAt, UpdatedAt: award.UpdatedAt,
	}
}

func decodeUintArray(value []byte) []uint {
	if len(value) == 0 {
		return []uint{}
	}
	var result []uint
	if err := json.Unmarshal(value, &result); err != nil || result == nil {
		return []uint{}
	}
	return result
}

func uintJSONArray(values []uint) []byte {
	if values == nil {
		values = []uint{}
	}
	encoded, _ := json.Marshal(values)
	return encoded
}

func (h *CompetitionHandler) ListCompetitionAwards(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var awards []models.UserCompetitionAward
	if err := h.db.Where("user_id = ?", userID).
		Order("competition_year DESC, id DESC").Find(&awards).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛经历失败"})
		return
	}
	items := make([]competitionAwardResponse, len(awards))
	for index, award := range awards {
		items[index] = competitionAwardResponseFromModel(award)
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "total": len(items)})
}

func (h *CompetitionHandler) CreateCompetitionAward(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	input, ok := decodeCompetitionAwardInput(c)
	if !ok {
		return
	}
	normalized, err := h.normalizeCompetitionAwardInput(userID, input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	award := models.UserCompetitionAward{
		UserID: userID, CompetitionEventID: normalized.CompetitionEventID,
		CompetitionTitle: normalized.CompetitionTitle, TrackName: normalized.TrackName,
		CompetitionYear: normalized.CompetitionYear, AwardName: normalized.AwardName,
		AwardLevel: normalized.AwardLevel, CompetitionStage: normalized.CompetitionStage,
		Role: normalized.Role, SkillTags: jsonArray(normalized.SkillTags),
		ContributionSummary: normalized.ContributionSummary,
		EvidenceFileIDs:     uintJSONArray(normalized.EvidenceFileIDs),
		VerificationStatus:  "self_reported", Visibility: normalized.Visibility,
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&award).Error; err != nil {
			return err
		}
		return activateCompetitionAwardFiles(tx, normalized.EvidenceFileIDs)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存竞赛经历失败"})
		return
	}
	c.JSON(http.StatusCreated, competitionAwardResponseFromModel(award))
}

func (h *CompetitionHandler) UpdateCompetitionAward(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseCompetitionAwardID(c)
	if !ok {
		return
	}
	var award models.UserCompetitionAward
	if err := h.db.Where("id = ? AND user_id = ?", id, userID).First(&award).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "竞赛经历不存在"})
		return
	}
	input, ok := decodeCompetitionAwardInput(c)
	if !ok {
		return
	}
	normalized, err := h.normalizeCompetitionAwardInput(userID, input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	updates := map[string]interface{}{
		"competition_event_id": normalized.CompetitionEventID,
		"competition_title":    normalized.CompetitionTitle, "track_name": normalized.TrackName,
		"competition_year": normalized.CompetitionYear, "award_name": normalized.AwardName,
		"award_level": normalized.AwardLevel, "competition_stage": normalized.CompetitionStage,
		"role": normalized.Role, "skill_tags": jsonArray(normalized.SkillTags),
		"contribution_summary": normalized.ContributionSummary,
		"evidence_file_ids":    uintJSONArray(normalized.EvidenceFileIDs), "visibility": normalized.Visibility,
		"verification_status": "self_reported", "verification_note": "",
		"verified_by": nil, "verified_at": nil,
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&award).Updates(updates).Error; err != nil {
			return err
		}
		return activateCompetitionAwardFiles(tx, normalized.EvidenceFileIDs)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新竞赛经历失败"})
		return
	}
	if err := h.db.First(&award, award.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取竞赛经历失败"})
		return
	}
	c.JSON(http.StatusOK, competitionAwardResponseFromModel(award))
}

func (h *CompetitionHandler) DeleteCompetitionAward(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseCompetitionAwardID(c)
	if !ok {
		return
	}
	result := h.db.Where("id = ? AND user_id = ?", id, userID).Delete(&models.UserCompetitionAward{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除竞赛经历失败"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "竞赛经历不存在"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

func decodeCompetitionAwardInput(c *gin.Context) (competitionAwardInput, bool) {
	var input competitionAwardInput
	decoder := json.NewDecoder(io.LimitReader(c.Request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误或包含不支持的字段"})
		return input, false
	}
	if err := ensureJSONBodyEnded(decoder); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求只能包含一个 JSON 对象"})
		return input, false
	}
	return input, true
}

func parseCompetitionAwardID(c *gin.Context) (uint, bool) {
	parsed, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || parsed == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "竞赛经历 ID 无效"})
		return 0, false
	}
	return uint(parsed), true
}

func (h *CompetitionHandler) normalizeCompetitionAwardInput(userID uint, input competitionAwardInput) (competitionAwardInput, error) {
	input.CompetitionTitle = strings.TrimSpace(input.CompetitionTitle)
	input.TrackName = strings.TrimSpace(input.TrackName)
	input.AwardName = strings.TrimSpace(input.AwardName)
	input.AwardLevel = strings.TrimSpace(input.AwardLevel)
	input.CompetitionStage = strings.TrimSpace(input.CompetitionStage)
	input.Role = strings.TrimSpace(input.Role)
	input.ContributionSummary = strings.TrimSpace(input.ContributionSummary)
	input.Visibility = strings.TrimSpace(input.Visibility)
	input.SkillTags = cleanPreferenceValues(input.SkillTags)
	input.EvidenceFileIDs = cleanCompetitionAwardFileIDs(input.EvidenceFileIDs)
	if input.Visibility == "" {
		input.Visibility = "private"
	}
	if input.CompetitionEventID != nil {
		if *input.CompetitionEventID == 0 {
			return input, errors.New("关联赛事 ID 无效")
		}
		var event models.CompetitionEvent
		if err := h.db.First(&event, *input.CompetitionEventID).Error; err != nil {
			return input, errors.New("关联赛事不存在")
		}
		input.CompetitionTitle = strings.TrimSpace(event.Title)
	}
	if length := utf8.RuneCountInString(input.CompetitionTitle); length < 1 || length > 200 {
		return input, errors.New("比赛名称必须为 1 到 200 个字")
	}
	currentYear := time.Now().Year()
	if input.CompetitionYear < 2000 || input.CompetitionYear > currentYear+1 {
		return input, fmt.Errorf("比赛年份必须在 2000 到 %d 之间", currentYear+1)
	}
	if length := utf8.RuneCountInString(input.AwardName); length < 1 || length > 100 {
		return input, errors.New("奖项名称必须为 1 到 100 个字")
	}
	if utf8.RuneCountInString(input.TrackName) > 100 || utf8.RuneCountInString(input.AwardLevel) > 50 {
		return input, errors.New("赛道或奖项级别过长")
	}
	if utf8.RuneCountInString(input.ContributionSummary) > 1000 {
		return input, errors.New("贡献描述最多 1000 个字")
	}
	if _, exists := competitionAwardRoles[input.Role]; !exists {
		return input, errors.New("未知的竞赛角色")
	}
	if _, exists := competitionAwardStages[input.CompetitionStage]; !exists {
		return input, errors.New("未知的竞赛阶段")
	}
	if _, exists := competitionAwardVisibilities[input.Visibility]; !exists {
		return input, errors.New("未知的可见范围")
	}
	if len(input.SkillTags) > 12 {
		return input, errors.New("技能标签最多 12 个")
	}
	for _, skill := range input.SkillTags {
		if utf8.RuneCountInString(skill) > 30 {
			return input, errors.New("单个技能标签最多 30 个字")
		}
	}
	if len(input.EvidenceFileIDs) > 6 {
		return input, errors.New("证明材料最多 6 个")
	}
	if err := h.validateCompetitionAwardFiles(userID, input.EvidenceFileIDs); err != nil {
		return input, err
	}
	return input, nil
}

func cleanCompetitionAwardFileIDs(values []uint) []uint {
	result := make([]uint, 0, len(values))
	seen := make(map[uint]struct{}, len(values))
	for _, value := range values {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func (h *CompetitionHandler) validateCompetitionAwardFiles(userID uint, fileIDs []uint) error {
	for _, fileID := range fileIDs {
		if fileID == 0 {
			return errors.New("证明材料 ID 无效")
		}
		var count int64
		if err := h.db.Model(&models.File{}).
			Where("id = ? AND uploader_id = ?", fileID, userID).Count(&count).Error; err != nil {
			return err
		}
		if count == 0 {
			if err := h.db.Model(&models.FileUploadGrant{}).
				Where("file_id = ? AND user_id = ?", fileID, userID).Count(&count).Error; err != nil {
				return err
			}
		}
		if count == 0 {
			return errors.New("证明材料不存在或无权使用")
		}
	}
	return nil
}

func activateCompetitionAwardFiles(tx *gorm.DB, fileIDs []uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	now := time.Now()
	return tx.Model(&models.File{}).Where("id IN ?", fileIDs).Updates(map[string]interface{}{
		"status": "active", "claimed_at": &now,
	}).Error
}
