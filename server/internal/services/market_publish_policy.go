package services

import (
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// MarketPublishPolicy 集中解释历史准入资格；教务账号配置不构成认证凭证。
// 版块禁言及账号限制继续由原有发布事务和认证中间件执行。
type MarketPublishPolicy struct{ DB *gorm.DB }

func (p MarketPublishPolicy) CanPublish(userID uint) (bool, error) {
	var user models.User
	if err := p.DB.Select("id", "account_status", "student_verified_at").First(&user, userID).Error; err != nil {
		return false, err
	}
	if user.AccountStatus != "" && user.AccountStatus != "active" {
		return false, nil
	}
	var count int64
	if err := p.DB.Model(&models.AcademicIdentityBinding{}).Where("user_id = ? AND verified_at IS NOT NULL", userID).Count(&count).Error; err != nil {
		return false, err
	}
	// 兼容迁移前的认证，启动消费旧字段后仍由历史身份表保持资格。
	return count > 0 || user.StudentVerifiedAt != nil, nil
}
