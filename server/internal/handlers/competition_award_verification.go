package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

type competitionAwardVerificationItem struct {
	competitionAwardResponse
	UserID        uint   `json:"user_id"`
	UserNickname  string `json:"user_nickname"`
	EvidenceCount int    `json:"evidence_count"`
}

type competitionAwardVerificationListItem struct {
	ID                 uint      `json:"id"`
	UserID             uint      `json:"user_id"`
	UserNickname       string    `json:"user_nickname"`
	CompetitionTitle   string    `json:"competition_title"`
	CompetitionYear    int       `json:"competition_year"`
	AwardName          string    `json:"award_name"`
	AwardLevel         string    `json:"award_level"`
	CompetitionStage   string    `json:"competition_stage"`
	VerificationStatus string    `json:"verification_status"`
	EvidenceCount      int       `json:"evidence_count"`
	UpdatedAt          time.Time `json:"updated_at"`
}

func (h *CompetitionHandler) SubmitCompetitionAwardVerification(c *gin.Context) {
	h.transitionUserCompetitionAward(c, []string{"self_reported", "rejected"}, "pending")
}

func (h *CompetitionHandler) CancelCompetitionAwardVerification(c *gin.Context) {
	h.transitionUserCompetitionAward(c, []string{"pending"}, "self_reported")
}

func (h *CompetitionHandler) transitionUserCompetitionAward(c *gin.Context, fromStatuses []string, toStatus string) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	awardID, ok := parseCompetitionAwardID(c)
	if !ok {
		return
	}
	var updated models.UserCompetitionAward
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var award models.UserCompetitionAward
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND user_id = ?", awardID, userID).First(&award).Error; err != nil {
			return err
		}
		allowed := false
		for _, status := range fromStatuses {
			if award.VerificationStatus == status {
				allowed = true
				break
			}
		}
		if !allowed {
			return errCompetitionAwardStateConflict
		}
		if toStatus == "pending" && len(decodeUintArray(award.EvidenceFileIDs)) == 0 {
			return errCompetitionAwardEvidenceRequired
		}
		fromStatus := award.VerificationStatus
		updates := map[string]interface{}{"verification_status": toStatus}
		if toStatus == "pending" || toStatus == "self_reported" {
			updates["verification_note"] = ""
			updates["verified_by"] = nil
			updates["verified_at"] = nil
		}
		result := tx.Model(&models.UserCompetitionAward{}).
			Where("id = ? AND user_id = ? AND verification_status = ?", award.ID, userID, fromStatus).
			Updates(updates)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errCompetitionAwardStateConflict
		}
		log := models.CompetitionAwardVerificationLog{
			AwardID: award.ID, UserID: userID, FromStatus: fromStatus, ToStatus: toStatus,
		}
		if err := tx.Create(&log).Error; err != nil {
			return err
		}
		return tx.First(&updated, award.ID).Error
	})
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "竞赛经历不存在"})
		return
	}
	if errors.Is(err, errCompetitionAwardStateConflict) {
		c.JSON(http.StatusConflict, gin.H{"error": "当前核验状态不允许此操作"})
		return
	}
	if errors.Is(err, errCompetitionAwardEvidenceRequired) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "至少上传一份证明材料后才能提交核验"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新核验状态失败"})
		return
	}
	c.JSON(http.StatusOK, competitionAwardResponseFromModel(updated))
}

var (
	errCompetitionAwardStateConflict    = errors.New("competition award state conflict")
	errCompetitionAwardEvidenceRequired = errors.New("competition award evidence required")
)

func (h *CompetitionHandler) ListCompetitionAwardVerifications(c *gin.Context) {
	if !requireCompetitionAwardVerifier(c) {
		return
	}
	status := strings.TrimSpace(c.Query("status"))
	if status != "" && status != "pending" && status != "verified" && status != "rejected" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "核验状态无效"})
		return
	}
	page := positiveQueryInt(c.Query("page"), 1, 100000)
	pageSize := positiveQueryInt(c.Query("page_size"), 20, 100)
	keyword := strings.TrimSpace(c.Query("keyword"))
	query := h.db.Model(&models.UserCompetitionAward{}).
		Joins("LEFT JOIN users ON users.id = user_competition_awards.user_id")
	if status != "" {
		query = query.Where("user_competition_awards.verification_status = ?", status)
	}
	if keyword != "" {
		like := "%" + keyword + "%"
		query = query.Where("user_competition_awards.competition_title LIKE ? OR user_competition_awards.award_name LIKE ? OR users.nickname LIKE ?", like, like, like)
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取核验列表失败"})
		return
	}
	type row struct {
		models.UserCompetitionAward
		UserNickname string `gorm:"column:user_nickname"`
	}
	var rows []row
	if err := query.Select("user_competition_awards.*, users.nickname AS user_nickname").
		Order("CASE WHEN user_competition_awards.verification_status = 'pending' THEN 0 ELSE 1 END, user_competition_awards.updated_at DESC").
		Offset((page - 1) * pageSize).Limit(pageSize).Scan(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取核验列表失败"})
		return
	}
	items := make([]competitionAwardVerificationListItem, len(rows))
	for index, item := range rows {
		award := item.UserCompetitionAward
		items[index] = competitionAwardVerificationListItem{
			ID: award.ID, UserID: award.UserID, UserNickname: item.UserNickname,
			CompetitionTitle: award.CompetitionTitle, CompetitionYear: award.CompetitionYear,
			AwardName: award.AwardName, AwardLevel: award.AwardLevel,
			CompetitionStage: award.CompetitionStage, VerificationStatus: award.VerificationStatus,
			EvidenceCount: len(decodeUintArray(award.EvidenceFileIDs)), UpdatedAt: award.UpdatedAt,
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "total": total, "page": page, "page_size": pageSize})
}

func (h *CompetitionHandler) GetCompetitionAwardVerification(c *gin.Context) {
	if !requireCompetitionAwardVerifier(c) {
		return
	}
	awardID, ok := parseCompetitionAwardID(c)
	if !ok {
		return
	}
	var award models.UserCompetitionAward
	if err := h.db.First(&award, awardID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "竞赛经历不存在"})
		return
	}
	var user models.User
	_ = h.db.Select("id", "nickname").First(&user, award.UserID).Error
	var logs []models.CompetitionAwardVerificationLog
	if err := h.db.Where("award_id = ?", award.ID).Order("id ASC").Find(&logs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取核验记录失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"award": verificationItem(award, user.Nickname), "logs": logs})
}

func verificationItem(award models.UserCompetitionAward, nickname string) competitionAwardVerificationItem {
	return competitionAwardVerificationItem{
		competitionAwardResponse: competitionAwardResponseFromModel(award),
		UserID:                   award.UserID, UserNickname: nickname,
		EvidenceCount: len(decodeUintArray(award.EvidenceFileIDs)),
	}
}

func (h *CompetitionHandler) ApproveCompetitionAwardVerification(c *gin.Context) {
	h.reviewCompetitionAward(c, true)
}

func (h *CompetitionHandler) RejectCompetitionAwardVerification(c *gin.Context) {
	h.reviewCompetitionAward(c, false)
}

func (h *CompetitionHandler) reviewCompetitionAward(c *gin.Context, approve bool) {
	if !requireCompetitionAwardVerifier(c) {
		return
	}
	operatorID, ok := currentUserID(c)
	if !ok {
		return
	}
	awardID, ok := parseCompetitionAwardID(c)
	if !ok {
		return
	}
	var body struct {
		Note   string `json:"note"`
		Reason string `json:"reason"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 8*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	note := strings.TrimSpace(body.Note)
	toStatus := "verified"
	if !approve {
		note = strings.TrimSpace(body.Reason)
		toStatus = "rejected"
		if note == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "请填写驳回原因"})
			return
		}
	}
	if utf8.RuneCountInString(note) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "核验说明最多 500 个字"})
		return
	}
	now := time.Now()
	var updated models.UserCompetitionAward
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var award models.UserCompetitionAward
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&award, awardID).Error; err != nil {
			return err
		}
		if award.VerificationStatus != "pending" {
			return errCompetitionAwardStateConflict
		}
		updates := map[string]interface{}{
			"verification_status": toStatus, "verification_note": note,
			"verified_by": nil, "verified_at": nil,
		}
		if approve {
			updates["verified_by"] = operatorID
			updates["verified_at"] = &now
		}
		result := tx.Model(&models.UserCompetitionAward{}).
			Where("id = ? AND verification_status = 'pending'", award.ID).Updates(updates)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errCompetitionAwardStateConflict
		}
		log := models.CompetitionAwardVerificationLog{
			AwardID: award.ID, UserID: award.UserID, OperatorID: &operatorID,
			FromStatus: "pending", ToStatus: toStatus, Note: note,
		}
		if err := tx.Create(&log).Error; err != nil {
			return err
		}
		return tx.First(&updated, award.ID).Error
	})
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "竞赛经历不存在"})
		return
	}
	if errors.Is(err, errCompetitionAwardStateConflict) {
		c.JSON(http.StatusConflict, gin.H{"error": "该记录已被处理或当前状态不可审核"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存核验结果失败"})
		return
	}
	c.JSON(http.StatusOK, competitionAwardResponseFromModel(updated))
}

func requireCompetitionAwardVerifier(c *gin.Context) bool {
	// 独立 competition_award_verify 权限落地前，仅超级管理员可接触学生证明材料。
	role, _ := c.Get("role")
	if role != "super_admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "需要竞赛经历核验权限"})
		return false
	}
	return true
}

func positiveQueryInt(value string, fallback, maximum int) int {
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 1 {
		return fallback
	}
	if parsed > maximum {
		return maximum
	}
	return parsed
}

func (h *CompetitionHandler) DownloadOwnCompetitionAwardEvidence(c *gin.Context) {
	h.downloadCompetitionAwardEvidence(c, false)
}

func (h *CompetitionHandler) DownloadAdminCompetitionAwardEvidence(c *gin.Context) {
	if !requireCompetitionAwardVerifier(c) {
		return
	}
	h.downloadCompetitionAwardEvidence(c, true)
}

func (h *CompetitionHandler) downloadCompetitionAwardEvidence(c *gin.Context, admin bool) {
	viewerID, ok := currentUserID(c)
	if !ok {
		return
	}
	awardID, ok := parseCompetitionAwardID(c)
	if !ok {
		return
	}
	fileID64, err := strconv.ParseUint(c.Param("file_id"), 10, 64)
	if err != nil || fileID64 == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "材料文件 ID 无效"})
		return
	}
	var award models.UserCompetitionAward
	query := h.db.Where("id = ?", awardID)
	if !admin {
		query = query.Where("user_id = ?", viewerID)
	}
	if err := query.First(&award).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "竞赛经历不存在"})
		return
	}
	fileID := uint(fileID64)
	if !containsUint(decodeUintArray(award.EvidenceFileIDs), fileID) {
		c.JSON(http.StatusNotFound, gin.H{"error": "证明材料不存在"})
		return
	}
	var mappingCount int64
	if err := h.db.Model(&models.CompetitionAwardEvidence{}).
		Where("award_id = ? AND file_id = ?", award.ID, fileID).Count(&mappingCount).Error; err != nil || mappingCount != 1 {
		c.JSON(http.StatusNotFound, gin.H{"error": "证明材料不存在"})
		return
	}
	var file models.CompetitionAwardEvidenceFile
	if err := h.db.Where("id = ? AND uploader_id = ?", fileID, award.UserID).First(&file).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "证明材料不存在"})
		return
	}
	if admin {
		access := models.CompetitionAwardEvidenceAccessLog{AwardID: award.ID, FileID: file.ID, ViewerID: viewerID}
		if err := h.db.Create(&access).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "记录材料访问失败"})
			return
		}
	}
	serveCompetitionAwardEvidenceFile(c, h.evidenceDir, file)
}

func containsUint(values []uint, target uint) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
