package services

import (
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// MarketPublishDenial 是集市发布被拒的稳定原因码。
//
// 「没有服务端准入身份」和「毕业」不是一回事，历史实现把两者混成
// market_graduated，用户因此会拿着"毕业用户"的提示去反复重绑教务。
// 这里只回答准入事实，不替产品猜测用户学历。
type MarketPublishDenial string

const (
	// MarketPublishAllowed 表示通过准入。
	MarketPublishAllowed MarketPublishDenial = ""
	// MarketPublishAccountRestricted 账号本身受限（封禁、注销等）。
	MarketPublishAccountRestricted MarketPublishDenial = "account_restricted"
	// MarketPublishStudentUnverified 缺少当前服务端准入所需的教务认证。
	// 错误码保留旧名称，兼容既有客户端与审计记录。
	MarketPublishStudentUnverified MarketPublishDenial = "student_unverified"
)

// MarketPublishPolicy 集中解释教务认证准入资格。
// 版块禁言及账号限制继续由原有发布事务和认证中间件执行。
type MarketPublishPolicy struct{ DB *gorm.DB }

// Evaluate 返回准入结论与被拒原因，供接口区分账号受限和未完成教务认证。
func (p MarketPublishPolicy) Evaluate(userID uint) (MarketPublishDenial, error) {
	var user models.User
	if err := p.DB.Select("id", "account_status", "edu_authorized", "edu_bound").First(&user, userID).Error; err != nil {
		return MarketPublishStudentUnverified, err
	}
	if user.AccountStatus != "" && user.AccountStatus != "active" {
		return MarketPublishAccountRestricted, nil
	}
	if !user.HasEduAccess() {
		return MarketPublishStudentUnverified, nil
	}
	return MarketPublishAllowed, nil
}

// CanPublish 只回答"能不能发"，历史调用点继续用它。
func (p MarketPublishPolicy) CanPublish(userID uint) (bool, error) {
	denial, err := p.Evaluate(userID)
	if err != nil {
		return false, err
	}
	return denial == MarketPublishAllowed, nil
}
