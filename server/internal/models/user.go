package models

import (
	"strings"
	"time"

	"gorm.io/gorm"
	"shenliyuan/internal/config"
	"shenliyuan/internal/utils"
)

// Role 用户角色
type Role string

const (
	RoleUser       Role = "user"        // 普通用户
	RoleAdmin      Role = "admin"       // 管理员
	RoleSuperAdmin Role = "super_admin" // 超级管理员
)

// User 用户模型
type User struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	StudentID      string    `gorm:"uniqueIndex;size:50;not null" json:"student_id"` // 学号/邮箱
	PasswordHash   string    `gorm:"size:255;not null" json:"-"`                     // 密码哈希
	Nickname       string    `gorm:"size:100" json:"nickname"`                       // 昵称
	Gender         string    `gorm:"size:10" json:"gender"`                          // "male"/"female"/"" (未知)
	Avatar         string    `gorm:"size:500" json:"avatar"`                         // 头像URL
	Background     string    `gorm:"size:500" json:"background"`                     // 背景图URL
	NightMode      bool      `gorm:"default:false" json:"night_mode"`                // 夜间模式
	TokenVersion   int       `gorm:"default:0" json:"-"`                             // 令牌版本号（用于改密码后强制下线）
	CreditScore    int       `gorm:"default:100;index" json:"credit_score"`          // 诚信度 0-100
	Role           Role      `gorm:"size:20;default:'user';index" json:"role"`       // 角色
	AdminExp       int       `gorm:"default:0" json:"admin_exp"`                     // 管理员经验
	Exp            int       `gorm:"default:0" json:"exp"`                           // 用户经验值（签到等获得）
	ReportCount    int       `gorm:"default:0;index" json:"report_count"`            // 90天内举报数
	QQ             string    `gorm:"size:20" json:"qq"`                              // QQ号
	DeviceToken    string    `gorm:"size:255" json:"-"`                              // 极光 RegistrationID
	Credits        int       `gorm:"default:0" json:"credits"`                       // 代答积分
	AiBalanceCents int       `gorm:"default:0" json:"ai_balance_cents"`              // 融智云考 AI 余额，单位：分
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`

	// 教务系统绑定信息（整合学长项目）
	EduStudentID string `gorm:"size:20" json:"edu_student_id"`  // 教务学号
	EduPassword  string `gorm:"size:255" json:"-"`              // 教务密码（加密存储）
	EduCookie    string `gorm:"size:1000" json:"-"`             // 登录Cookie
	EduBound     bool   `gorm:"default:false" json:"edu_bound"` // 是否已绑定教务
	EduGrade     string `gorm:"size:20" json:"edu_grade"`       // 年级
	EduCollege   string `gorm:"size:100" json:"edu_college"`    // 学院
	EduMajor     string `gorm:"size:100" json:"edu_major"`      // 专业

	// VIP 权限控制（题库导出桌面端高级功能）
	VipExpiry *time.Time `gorm:"index" json:"vip_expiry"` // VIP 过期时间，nil 表示非 VIP

	LastCheckInDate  string `gorm:"size:10" json:"last_check_in_date"` // 最后签到日期
	IsCheckedInToday bool   `gorm:"-" json:"is_checked_in_today"`      // 动态字段，不在数据库映射
	IsFollowing      bool   `gorm:"-" json:"is_following"`             // 当前登录者是否关注了此用户

	// 社交统计聚合字段
	FollowersCount     int `gorm:"default:0;index" json:"followers_count"`
	FollowingCount     int `gorm:"default:0;index" json:"following_count"`
	TotalLikesReceived int `gorm:"default:0;index" json:"total_likes_received"`
}

func (u *User) BeforeSave(tx *gorm.DB) (err error) {
	if u.EduPassword != "" && !strings.HasPrefix(u.EduPassword, "ENC:") {
		encrypted, err := utils.EncryptAES(u.EduPassword, config.Load().JWTSecret)
		if err == nil {
			u.EduPassword = "ENC:" + encrypted
		}
	}
	return nil
}

func (u *User) AfterFind(tx *gorm.DB) (err error) {
	if strings.HasPrefix(u.EduPassword, "ENC:") {
		decrypted, err := utils.DecryptAES(strings.TrimPrefix(u.EduPassword, "ENC:"), config.Load().JWTSecret)
		if err == nil {
			u.EduPassword = decrypted
		}
	}
	return nil
}
