package handlers

import (
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

// AdminUserBriefResponse 是管理员列表使用的最小用户资料，包含管理所需的账号标识。
type AdminUserBriefResponse struct {
	ID                 uint        `json:"id"`
	StudentID          string      `json:"student_id"`
	StudentVerified    bool        `json:"student_verified"`
	AcademicConfigured bool        `json:"academic_configured"`
	Nickname           string      `json:"nickname"`
	Avatar             string      `json:"avatar"`
	Role               models.Role `json:"role"`
}

// AdminUserResponse 是超级管理员管理用户时使用的完整资料。
// 它必须显式构造，不能依赖 User.MarshalJSON 的公开资料规则。
type AdminUserResponse struct {
	ID                 uint        `json:"id"`
	StudentID          string      `json:"student_id"`
	Nickname           string      `json:"nickname"`
	Avatar             string      `json:"avatar"`
	Role               models.Role `json:"role"`
	CreditScore        int         `json:"credit_score"`
	ReportCount        int         `json:"report_count"`
	EduBound           bool        `json:"edu_bound"`
	StudentVerified    bool        `json:"student_verified"`
	AcademicConfigured bool        `json:"academic_configured"`
	CreatedAt          time.Time   `json:"created_at"`
}

type adminAcademicIdentity struct {
	StudentID string
	Verified  bool
}

// loadAdminAcademicStudentIDs 优先展示可信身份学号，再展示用户已登记的有效配置学号。
// 配置只补全管理员可见的账号标识，不授予身份；users.student_id 仅用于旧账号兼容。
func loadAdminAcademicStudentIDs(db *gorm.DB, users []models.User) (map[uint]adminAcademicIdentity, error) {
	studentIDs := make(map[uint]adminAcademicIdentity, len(users))
	if db == nil || len(users) == 0 {
		return studentIDs, nil
	}

	userIDs := make([]uint, 0, len(users))
	for _, user := range users {
		userIDs = append(userIDs, user.ID)
	}

	if db.Migrator().HasTable(&models.AcademicIdentityBinding{}) {
		var bindings []models.AcademicIdentityBinding
		if err := models.TrustedAcademicBindingScope(db.
			Select("user_id", "provider_id", "student_id", "verified_at", "verification_method").
			Where("user_id IN ? AND verified_at > ?", userIDs, time.Time{})).
			Order("user_id ASC, provider_id DESC, student_id ASC").
			Find(&bindings).Error; err != nil {
			return nil, err
		}
		for _, binding := range bindings {
			if _, exists := studentIDs[binding.UserID]; exists {
				continue
			}
			if studentID := strings.TrimSpace(binding.StudentID); studentID != "" {
				studentIDs[binding.UserID] = adminAcademicIdentity{StudentID: studentID, Verified: true}
			}
		}
	}
	if db.Migrator().HasTable(&models.AcademicAccountConfig{}) {
		var configs []models.AcademicAccountConfig
		if err := activeAdminAcademicConfigs(db).
			Select("user_id", "provider_id", "student_id").
			Where("user_id IN ?", userIDs).
			Order("user_id ASC, updated_at DESC, provider_id DESC").
			Find(&configs).Error; err != nil {
			return nil, err
		}
		for _, config := range configs {
			if _, exists := studentIDs[config.UserID]; !exists {
				studentIDs[config.UserID] = adminAcademicIdentity{StudentID: strings.TrimSpace(config.StudentID)}
			}
		}
	}
	return studentIDs, nil
}

func activeAdminAcademicConfigs(db *gorm.DB) *gorm.DB {
	return db.Model(&models.AcademicAccountConfig{}).
		Where("state = ? AND TRIM(student_id) <> ''", "active")
}

// loadAdminAcademicConfigured 只反映配置表中存在可用的 active 记录，
// 不把它与旧授权或可信学生身份混成一个状态。
func loadAdminAcademicConfigured(db *gorm.DB, users []models.User) (map[uint]bool, error) {
	configured := make(map[uint]bool, len(users))
	if db == nil || len(users) == 0 || !db.Migrator().HasTable(&models.AcademicAccountConfig{}) {
		return configured, nil
	}

	userIDs := make([]uint, 0, len(users))
	for _, user := range users {
		userIDs = append(userIDs, user.ID)
	}
	var rows []struct {
		UserID uint `gorm:"column:user_id"`
	}
	if err := activeAdminAcademicConfigs(db).
		Select("user_id").
		Where("user_id IN ?", userIDs).
		Group("user_id").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	for _, row := range rows {
		configured[row.UserID] = true
	}
	return configured, nil
}

func adminStudentID(user models.User, academicStudentIDs map[uint]adminAcademicIdentity) string {
	if identity, ok := academicStudentIDs[user.ID]; ok {
		if studentID := strings.TrimSpace(identity.StudentID); studentID != "" {
			return studentID
		}
	}
	return strings.TrimSpace(user.StudentID)
}

func adminStudentVerified(user models.User, academicStudentIDs map[uint]adminAcademicIdentity) bool {
	if identity, ok := academicStudentIDs[user.ID]; ok && identity.Verified {
		return true
	}
	return user.IsStudentVerified()
}

// withAdminUserSearch 让管理端可按内部 ID、旧账号字段、昵称及可信/已登记教务学号搜索。
func withAdminUserSearch(query, db *gorm.DB, keyword string) *gorm.DB {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		return query
	}

	like := "%" + strings.ToLower(keyword) + "%"
	conditions := "LOWER(student_id) LIKE ? OR LOWER(nickname) LIKE ?"
	args := []interface{}{like, like}
	if userID, err := strconv.ParseUint(keyword, 10, 64); err == nil {
		conditions = "id = ? OR " + conditions
		args = append([]interface{}{userID}, args...)
	}
	if db != nil && db.Migrator().HasTable(&models.AcademicIdentityBinding{}) {
		identityOwners := models.TrustedAcademicBindingScope(db.Model(&models.AcademicIdentityBinding{}).
			Select("user_id").
			Where("verified_at > ? AND LOWER(student_id) LIKE ?", time.Time{}, like))
		conditions += " OR id IN (?)"
		args = append(args, identityOwners)
	}
	if db != nil && db.Migrator().HasTable(&models.AcademicAccountConfig{}) {
		configOwners := activeAdminAcademicConfigs(db).
			Select("user_id").Where("LOWER(student_id) LIKE ?", like)
		conditions += " OR id IN (?)"
		args = append(args, configOwners)
	}
	return query.Where(conditions, args...)
}

// withAdminAcademicAccounts 只统计仍存在的 App 用户，多 Provider/多来源不重复计数。
// 教务配置登记、可信学生身份和旧教务授权是独立事实，任一存在即有教务账号记录。
func withAdminAcademicAccounts(db *gorm.DB) *gorm.DB {
	conditions := "edu_authorized = ?"
	args := []interface{}{true}
	if db.Migrator().HasTable(&models.AcademicIdentityBinding{}) {
		identityOwners := models.TrustedAcademicBindingScope(db.Model(&models.AcademicIdentityBinding{})).
			Select("user_id").Where("verified_at > ? AND TRIM(student_id) <> ''", time.Time{})
		conditions += " OR id IN (?)"
		args = append(args, identityOwners)
	}
	if db.Migrator().HasTable(&models.AcademicAccountConfig{}) {
		conditions += " OR id IN (?)"
		args = append(args, activeAdminAcademicConfigs(db).Select("user_id"))
	}
	return db.Model(&models.User{}).Where(conditions, args...)
}

func adminUserBriefResponse(user models.User, studentID string, studentVerified bool, academicConfigured bool) AdminUserBriefResponse {
	return AdminUserBriefResponse{
		ID:                 user.ID,
		StudentID:          studentID,
		StudentVerified:    studentVerified,
		AcademicConfigured: academicConfigured,
		Nickname:           user.Nickname,
		Avatar:             user.Avatar,
		Role:               user.Role,
	}
}

func adminUserResponse(user models.User, studentID string, studentVerified bool, academicConfigured bool) AdminUserResponse {
	return AdminUserResponse{
		ID:                 user.ID,
		StudentID:          studentID,
		Nickname:           user.Nickname,
		Avatar:             user.Avatar,
		Role:               user.Role,
		CreditScore:        user.CreditScore,
		ReportCount:        user.ReportCount,
		EduBound:           user.IsEduAuthorized(),
		StudentVerified:    studentVerified,
		AcademicConfigured: academicConfigured,
		CreatedAt:          user.CreatedAt,
	}
}
