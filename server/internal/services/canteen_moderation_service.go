package services

import (
	"errors"
	"fmt"
	"strings"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

const (
	CanteenPenaltyNormal = 5
	CanteenPenaltyMalice = 10
)

// CanteenPenaltyForReason 将内容治理原因统一映射为扣分规则。
// 普通图库质量驳回（blurry/duplicate/privacy 等）返回 0，不影响诚信。
func CanteenPenaltyForReason(reasonCode string) int {
	switch strings.ToLower(strings.TrimSpace(reasonCode)) {
	case "fabricated", "false", "unrelated", "unrelated_photo", "unrelated_content":
		return CanteenPenaltyNormal
	case "malicious", "malicious_repeat", "fake_dish", "stolen_photo":
		return CanteenPenaltyMalice
	default:
		return 0
	}
}

// ApplyCanteenSanction 执行一次幂等诚信处罚。
// 该函数只在管理员确认举报后调用；普通审核驳回不应调用。
func ApplyCanteenSanction(tx *gorm.DB, reportID uint, targetType string, targetID, userID, adminID uint, reasonCode string) (bool, error) {
	points := CanteenPenaltyForReason(reasonCode)
	if points == 0 {
		return false, nil
	}
	if reportID == 0 || userID == 0 || adminID == 0 {
		return false, errors.New("invalid canteen sanction identity")
	}

	var existing models.CanteenSanction
	err := tx.Where("report_id = ?", reportID).First(&existing).Error
	if err == nil {
		return false, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return false, err
	}

	sanction := models.CanteenSanction{
		ReportID: reportID, TargetType: targetType, TargetID: targetID,
		UserID: userID, Points: points, ReasonCode: reasonCode, AdminID: adminID,
	}
	if err := tx.Create(&sanction).Error; err != nil {
		// 并发重试命中唯一约束时视为已处理，不再次扣分。
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return false, nil
		}
		return false, err
	}
	result := tx.Model(&models.User{}).Where("id = ?", userID).
		UpdateColumn("credit_score", gorm.Expr("CASE WHEN credit_score - ? < 0 THEN 0 ELSE credit_score - ? END", points, points))
	if result.Error != nil {
		return false, result.Error
	}
	if result.RowsAffected == 0 {
		return false, fmt.Errorf("sanction user %d not found", userID)
	}
	return true, nil
}
