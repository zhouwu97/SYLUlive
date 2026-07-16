package services

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// CheckInCompensationTarget 是活动发布时录入的一条用户资格快照。
type CheckInCompensationTarget struct {
	UserID      uint
	CheckInDate time.Time
	ExpReward   int
	Reason      string
}

// CheckInCompensationCampaignInput 是一次活动发布所需的固定内容。
type CheckInCompensationCampaignInput struct {
	Title          string
	Description    string
	ClaimStartDate time.Time
	ClaimEndDate   time.Time
	CreatedBy      uint
	Targets        []CheckInCompensationTarget
}

// CheckInCompensationClaimResult 表示一次领取的幂等结果。
type CheckInCompensationClaimResult struct {
	Already   bool
	ExpReward int
	TotalExp  int
}

// CheckInCompensationItem 是用户补偿中心的一条可领取或已领取记录。
type CheckInCompensationItem struct {
	CampaignID     uint
	CampaignTitle  string
	Description    string
	CampaignStatus string
	ClaimStartDate time.Time
	ClaimEndDate   time.Time
	CheckInDate    time.Time
	ExpReward      int
	Reason         string
	Claimed        bool
	ClaimedAt      *time.Time
}

// CheckInCompensationService 管理补偿资格快照与领取流水。
type CheckInCompensationService struct {
	db *gorm.DB
}

func NewCheckInCompensationService(db *gorm.DB) *CheckInCompensationService {
	return &CheckInCompensationService{db: db}
}

// PublishCampaign 一次性创建已发布活动和资格快照，发布后资格不再按实时用户状态重新计算。
func (s *CheckInCompensationService) PublishCampaign(input CheckInCompensationCampaignInput, now time.Time) (models.CheckInCompensationCampaign, error) {
	input.Title = strings.TrimSpace(input.Title)
	input.Description = strings.TrimSpace(input.Description)
	if input.Title == "" || len(input.Title) > 120 {
		return models.CheckInCompensationCampaign{}, errors.New("活动标题长度必须在 1 到 120 个字符之间")
	}
	if len(input.Description) > 1000 {
		return models.CheckInCompensationCampaign{}, errors.New("活动说明不能超过 1000 个字符")
	}
	if len(input.Targets) == 0 {
		return models.CheckInCompensationCampaign{}, errors.New("补偿活动至少需要一条资格快照")
	}
	start, end := checkInDateOnly(input.ClaimStartDate), checkInDateOnly(input.ClaimEndDate)
	if end.Before(start) {
		return models.CheckInCompensationCampaign{}, errors.New("领取结束日期不能早于开始日期")
	}
	seen := make(map[string]struct{}, len(input.Targets))
	for index := range input.Targets {
		target := &input.Targets[index]
		target.CheckInDate = checkInDateOnly(target.CheckInDate)
		target.Reason = strings.TrimSpace(target.Reason)
		if target.UserID == 0 || target.ExpReward <= 0 || target.ExpReward > 10000 {
			return models.CheckInCompensationCampaign{}, fmt.Errorf("第 %d 条补偿资格无效", index+1)
		}
		key := fmt.Sprintf("%d:%s", target.UserID, FormatCheckInDate(target.CheckInDate))
		if _, exists := seen[key]; exists {
			return models.CheckInCompensationCampaign{}, fmt.Errorf("重复的补偿资格: 用户 %d，日期 %s", target.UserID, FormatCheckInDate(target.CheckInDate))
		}
		seen[key] = struct{}{}
	}

	var campaign models.CheckInCompensationCampaign
	err := s.db.Transaction(func(tx *gorm.DB) error {
		userIDs := make([]uint, 0, len(input.Targets))
		for _, target := range input.Targets {
			userIDs = append(userIDs, target.UserID)
		}
		var existingUsers int64
		if err := tx.Model(&models.User{}).Where("id IN ?", userIDs).Distinct("id").Count(&existingUsers).Error; err != nil {
			return err
		}
		if existingUsers != int64(len(uniqueUserIDs(userIDs))) {
			return errors.New("补偿资格中包含不存在的用户")
		}
		campaign = models.CheckInCompensationCampaign{
			Title: input.Title, Description: input.Description, Status: models.CheckInCompensationCampaignPublished,
			ClaimStartDate: start, ClaimEndDate: end, PublishedAt: now, CreatedBy: input.CreatedBy,
		}
		if err := tx.Create(&campaign).Error; err != nil {
			return err
		}
		eligibilities := make([]models.CheckInCompensationEligibility, 0, len(input.Targets))
		for _, target := range input.Targets {
			eligibilities = append(eligibilities, models.CheckInCompensationEligibility{
				CampaignID: campaign.ID, UserID: target.UserID, CheckInDate: target.CheckInDate,
				ExpReward: target.ExpReward, Reason: target.Reason,
			})
		}
		return tx.Create(&eligibilities).Error
	})
	return campaign, err
}

// ListForUser 查询资格快照及对应领取流水，不根据用户当前连续签到天数动态推导资格。
func (s *CheckInCompensationService) ListForUser(userID uint) ([]CheckInCompensationItem, error) {
	type row struct {
		CampaignID     uint
		Title          string
		Description    string
		Status         string
		ClaimStartDate time.Time
		ClaimEndDate   time.Time
		CheckInDate    time.Time
		ExpReward      int
		Reason         string
		ClaimedAt      *time.Time
	}
	var rows []row
	err := s.db.Table("check_in_compensation_eligibilities AS eligibility").
		Select(`campaign.id AS campaign_id, campaign.title, campaign.description, campaign.status,
			campaign.claim_start_date, campaign.claim_end_date, eligibility.check_in_date,
			eligibility.exp_reward, eligibility.reason, claim.claimed_at`).
		Joins("JOIN check_in_compensation_campaigns AS campaign ON campaign.id = eligibility.campaign_id").
		Joins("LEFT JOIN check_in_compensation_claims AS claim ON claim.campaign_id = eligibility.campaign_id AND claim.user_id = eligibility.user_id AND claim.check_in_date = eligibility.check_in_date").
		Where("eligibility.user_id = ?", userID).
		Order("campaign.created_at DESC, eligibility.check_in_date ASC").
		Scan(&rows).Error
	if err != nil {
		return nil, err
	}
	items := make([]CheckInCompensationItem, 0, len(rows))
	for _, row := range rows {
		items = append(items, CheckInCompensationItem{
			CampaignID: row.CampaignID, CampaignTitle: row.Title, Description: row.Description, CampaignStatus: row.Status,
			ClaimStartDate: row.ClaimStartDate, ClaimEndDate: row.ClaimEndDate, CheckInDate: row.CheckInDate,
			ExpReward: row.ExpReward, Reason: row.Reason, Claimed: row.ClaimedAt != nil, ClaimedAt: row.ClaimedAt,
		})
	}
	return items, nil
}

// Claim 按活动和补偿日期领取经验。用户行锁和唯一索引共同保证重复请求不重复发放。
func (s *CheckInCompensationService) Claim(userID, campaignID uint, checkInDate, now time.Time) (CheckInCompensationClaimResult, error) {
	result := CheckInCompensationClaimResult{}
	checkInDate = checkInDateOnly(checkInDate)
	today := checkInDateOnly(now)
	err := s.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		var campaign models.CheckInCompensationCampaign
		if err := tx.Where("id = ?", campaignID).First(&campaign).Error; err != nil {
			return err
		}
		if campaign.Status != models.CheckInCompensationCampaignPublished || today.Before(checkInDateOnly(campaign.ClaimStartDate)) || today.After(checkInDateOnly(campaign.ClaimEndDate)) {
			return errors.New("该补偿活动当前不可领取")
		}
		var eligibility models.CheckInCompensationEligibility
		if err := tx.Where("campaign_id = ? AND user_id = ? AND check_in_date = ?", campaignID, userID, checkInDate).First(&eligibility).Error; err != nil {
			return err
		}
		var existing models.CheckInCompensationClaim
		if err := tx.Where("campaign_id = ? AND user_id = ? AND check_in_date = ?", campaignID, userID, checkInDate).First(&existing).Error; err == nil {
			result.Already = true
			result.ExpReward = existing.ExpReward
			result.TotalExp = user.Exp
			return nil
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		claim := models.CheckInCompensationClaim{
			CampaignID: campaignID, UserID: userID, CheckInDate: checkInDate, ExpReward: eligibility.ExpReward, ClaimedAt: now,
		}
		if err := tx.Create(&claim).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.UserExperienceLedger{
			UserID: userID, SourceType: "checkin_compensation", SourceID: claim.ID, Delta: eligibility.ExpReward,
			Reason: fmt.Sprintf("签到补偿：%s（%s）", campaign.Title, FormatCheckInDate(checkInDate)),
		}).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Update("exp", gorm.Expr("exp + ?", eligibility.ExpReward)).Error; err != nil {
			return err
		}
		result.ExpReward = eligibility.ExpReward
		result.TotalExp = user.Exp + eligibility.ExpReward
		return nil
	})
	return result, err
}

// CloseCampaign 立即关闭活动，已经产生的资格快照和领取流水仍会保留。
func (s *CheckInCompensationService) CloseCampaign(campaignID uint) error {
	result := s.db.Model(&models.CheckInCompensationCampaign{}).
		Where("id = ? AND status = ?", campaignID, models.CheckInCompensationCampaignPublished).
		Update("status", models.CheckInCompensationCampaignClosed)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

func uniqueUserIDs(userIDs []uint) []uint {
	seen := make(map[uint]struct{}, len(userIDs))
	unique := make([]uint, 0, len(userIDs))
	for _, userID := range userIDs {
		if _, exists := seen[userID]; !exists {
			seen[userID] = struct{}{}
			unique = append(unique, userID)
		}
	}
	sort.Slice(unique, func(i, j int) bool { return unique[i] < unique[j] })
	return unique
}
