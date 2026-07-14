package handlers

import (
	"time"

	"shenliyuan/internal/models"
)

// AdminUserBriefResponse 是管理员列表使用的最小用户资料，包含管理所需的账号标识。
type AdminUserBriefResponse struct {
	ID        uint        `json:"id"`
	StudentID string      `json:"student_id"`
	Nickname  string      `json:"nickname"`
	Avatar    string      `json:"avatar"`
	Role      models.Role `json:"role"`
}

// AdminUserResponse 是超级管理员管理用户时使用的完整资料。
// 它必须显式构造，不能依赖 User.MarshalJSON 的公开资料规则。
type AdminUserResponse struct {
	ID          uint        `json:"id"`
	StudentID   string      `json:"student_id"`
	Nickname    string      `json:"nickname"`
	Avatar      string      `json:"avatar"`
	Role        models.Role `json:"role"`
	CreditScore int         `json:"credit_score"`
	ReportCount int         `json:"report_count"`
	EduBound    bool        `json:"edu_bound"`
	CreatedAt   time.Time   `json:"created_at"`
}

func adminUserBriefResponse(user models.User) AdminUserBriefResponse {
	return AdminUserBriefResponse{
		ID:        user.ID,
		StudentID: user.StudentID,
		Nickname:  user.Nickname,
		Avatar:    user.Avatar,
		Role:      user.Role,
	}
}

func adminUserResponse(user models.User) AdminUserResponse {
	return AdminUserResponse{
		ID:          user.ID,
		StudentID:   user.StudentID,
		Nickname:    user.Nickname,
		Avatar:      user.Avatar,
		Role:        user.Role,
		CreditScore: user.CreditScore,
		ReportCount: user.ReportCount,
		EduBound:    user.EduBound,
		CreatedAt:   user.CreatedAt,
	}
}
