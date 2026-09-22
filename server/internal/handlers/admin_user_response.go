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
	ID              uint        `json:"id"`
	StudentID       string      `json:"student_id"`
	StudentVerified bool        `json:"student_verified"`
	Nickname        string      `json:"nickname"`
	Avatar          string      `json:"avatar"`
	Role            models.Role `json:"role"`
}

// AdminUserResponse 是超级管理员管理用户时使用的完整资料。
// 它必须显式构造，不能依赖 User.MarshalJSON 的公开资料规则。
type AdminUserResponse struct {
	ID              uint        `json:"id"`
	StudentID       string      `json:"student_id"`
	Nickname        string      `json:"nickname"`
	Avatar          string      `json:"avatar"`
	Role            models.Role `json:"role"`
	CreditScore     int         `json:"credit_score"`
	ReportCount     int         `json:"report_count"`
	EduBound        bool        `json:"edu_bound"`
	StudentVerified bool        `json:"student_verified"`
	CreatedAt       time.Time   `json:"created_at"`
}

type adminAcademicIdentity struct {
	StudentID string
	Verified  bool
}

// loadAdminAcademicStudentIDs 从新的教务身份表批量读取管理员页面需要展示的学号。
// users.student_id 只保留为旧数据兼容字段，不能再作为教务绑定事实来源。
func loadAdminAcademicStudentIDs(db *gorm.DB, users []models.User) (map[uint]adminAcademicIdentity, error) {
	studentIDs := make(map[uint]adminAcademicIdentity, len(users))
	if db == nil || len(users) == 0 || !db.Migrator().HasTable(&models.AcademicIdentityBinding{}) {
		return studentIDs, nil
	}

	userIDs := make([]uint, 0, len(users))
	for _, user := range users {
		userIDs = append(userIDs, user.ID)
	}

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
	return studentIDs, nil
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

// withAdminUserSearch 让管理端可按内部 ID、旧账号字段、昵称或已验证教务学号搜索。
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
	return query.Where(conditions, args...)
}

func adminUserBriefResponse(user models.User, studentID string, studentVerified bool) AdminUserBriefResponse {
	return AdminUserBriefResponse{
		ID:              user.ID,
		StudentID:       studentID,
		StudentVerified: studentVerified,
		Nickname:        user.Nickname,
		Avatar:          user.Avatar,
		Role:            user.Role,
	}
}

func adminUserResponse(user models.User, studentID string, studentVerified bool) AdminUserResponse {
	return AdminUserResponse{
		ID:              user.ID,
		StudentID:       studentID,
		Nickname:        user.Nickname,
		Avatar:          user.Avatar,
		Role:            user.Role,
		CreditScore:     user.CreditScore,
		ReportCount:     user.ReportCount,
		EduBound:        user.IsEduAuthorized(),
		StudentVerified: studentVerified,
		CreatedAt:       user.CreatedAt,
	}
}
