package models

import (
	"encoding/json"
	"time"
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
	ID uint `gorm:"primaryKey" json:"id"`
	// 学号是经教务验证后的稳定学生身份。唯一性由显式 SQL 部分索引保证。
	StudentID         string     `gorm:"size:20;default:''" json:"student_id"`
	StudentVerifiedAt *time.Time `json:"-"`
	// AccountStatus 明确表示账号生命周期，注销后不再依赖伪造身份字段判断状态。
	AccountStatus string     `gorm:"size:20;default:'active';index" json:"-"`
	CancelledAt   *time.Time `json:"-"`
	// 邮箱用于辅助登录和找回密码，统一以小写保存。
	Email             string     `gorm:"size:320;default:''" json:"-"`
	EmailVerifiedAt   *time.Time `json:"-"`
	PasswordHash      string     `gorm:"size:255;not null" json:"-"`               // 密码哈希
	Nickname          string     `gorm:"size:100" json:"nickname"`                 // 昵称
	Gender            string     `gorm:"size:10" json:"gender"`                    // "male"/"female"/"" (未知)
	Avatar            string     `gorm:"size:500" json:"avatar"`                   // 头像URL
	Background        string     `gorm:"size:500" json:"background"`               // 背景图URL
	NightMode         bool       `gorm:"default:false" json:"night_mode"`          // 夜间模式
	TokenVersion      int        `gorm:"default:0" json:"-"`                       // 令牌版本号（用于改密码后强制下线）
	CreditScore       int        `gorm:"default:100;index" json:"credit_score"`    // 诚信度 0-100
	Role              Role       `gorm:"size:20;default:'user';index" json:"role"` // 角色
	AdminExp          int        `gorm:"default:0" json:"admin_exp"`               // 管理员经验
	Exp               int        `gorm:"default:0" json:"exp"`                     // 用户经验值（签到等获得）
	ReportCount       int        `gorm:"default:0;index" json:"report_count"`      // 90天内举报数
	CanteenMutedUntil *time.Time `gorm:"index" json:"-"`                           // 食堂内容治理确认后的临时禁投期限
	// QQ 仅用于兼容历史账号，不能作为新账号身份。
	QQ                            string     `gorm:"size:20" json:"-"`
	DeviceToken                   string     `gorm:"size:255" json:"-"`            // 极光 RegistrationID
	PushDataProcessingEnabled     bool       `gorm:"default:false;index" json:"-"` // 是否主动开启远程推送数据处理
	PushInstallationID            string     `gorm:"size:128" json:"-"`            // 当前活跃安装实例
	PushNoticeVersion             string     `gorm:"size:64" json:"-"`             // 用户确认的推送告知版本
	PushEnabledAt                 *time.Time `json:"-"`                            // 最近一次开启时间
	CompetitionProfileAIEnabled   bool       `gorm:"default:false" json:"-"`       // 是否单独授权 AI 读取竞赛目标和能力画像
	CompetitionProfileAIEnabledAt *time.Time `json:"-"`                            // 当前授权的开启时间
	// LegalConsentRevokedAt 非空时，账号仅可使用隐私权利与退出相关功能。
	LegalConsentRevokedAt *time.Time `gorm:"index" json:"-"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	// 教务连接状态。凭据和 Cookie 只由 Python 教务服务保存。
	EduStudentID        string     `gorm:"size:20" json:"edu_student_id"`
	EduAuthorized       bool       `gorm:"default:false" json:"edu_authorized"`
	EduSessionState     string     `gorm:"size:20;default:'unbound'" json:"edu_session_state"`
	EduAutoRelogin      bool       `gorm:"default:true" json:"-"`
	EduAuthorizedAt     *time.Time `json:"-"`
	EduSessionUpdatedAt *time.Time `json:"-"`
	// EduAuthorizationGeneration 每次显式绑定递增，用于隔离旧撤销任务与新凭据。
	EduAuthorizationGeneration uint `gorm:"not null;default:0" json:"-"`
	EduCleanupPending          bool `gorm:"not null;default:false" json:"-"`
	// EduBindingState 记录跨服务绑定的提交阶段，避免 Go 在 Python 成功后崩溃时丢失待提交代次。
	EduBindingState             string `gorm:"size:32;not null;default:'idle';index" json:"-"`
	EduBindingPendingGeneration uint   `gorm:"not null;default:0" json:"-"`
	// EduBindingPendingStudentID 是待提交绑定的目标学号，恢复任务用它校验远端身份。
	EduBindingPendingStudentID string     `gorm:"size:20;not null;default:''" json:"-"`
	EduBindingStartedAt        *time.Time `gorm:"index" json:"-"`
	// EduBound 为旧客户端兼容字段，恒等于 EduAuthorized。
	EduBound   bool   `gorm:"default:false" json:"edu_bound"`
	EduGrade   string `gorm:"size:20" json:"edu_grade"`
	EduCollege string `gorm:"size:100" json:"edu_college"`
	EduMajor   string `gorm:"size:100" json:"edu_major"`
	// 历史字段只在撤销授权和注销时用于擦除，禁止新增写入。
	EduPassword string `gorm:"size:255" json:"-"`
	EduCookie   string `gorm:"size:1000" json:"-"`

	LastCheckInDate  string `gorm:"size:10" json:"last_check_in_date"` // 最后签到日期
	IsCheckedInToday bool   `gorm:"-" json:"is_checked_in_today"`      // 动态字段，不在数据库映射
	IsFollowing      bool   `gorm:"-" json:"is_following"`             // 当前登录者是否关注了此用户

	// 社交统计聚合字段
	FollowersCount     int `gorm:"default:0;index" json:"followers_count"`
	FollowingCount     int `gorm:"default:0;index" json:"following_count"`
	TotalLikesReceived int `gorm:"default:0;index" json:"total_likes_received"`
}

// PublicUserResponse 是所有面向其他用户的用户资料响应。
// 数据库 User 同时承载认证、信誉和教务字段，绝不能直接作为公开 API 的嵌套对象返回。
type PublicUserResponse struct {
	ID                 uint   `json:"id"`
	Nickname           string `json:"nickname"`
	Avatar             string `json:"avatar"`
	Background         string `json:"background"`
	Exp                int    `json:"exp"`
	CreditScore        int    `json:"credit_score"`
	FollowersCount     int    `json:"followers_count"`
	FollowingCount     int    `json:"following_count"`
	TotalLikesReceived int    `json:"total_likes_received"`
	IsFollowing        bool   `json:"is_following"`
}

// PublicUser 将数据库用户转换为安全的公开资料。
func PublicUser(user User) PublicUserResponse {
	return PublicUserResponse{
		ID:                 user.ID,
		Nickname:           user.Nickname,
		Avatar:             user.Avatar,
		Background:         user.Background,
		Exp:                user.Exp,
		CreditScore:        user.CreditScore,
		FollowersCount:     user.FollowersCount,
		FollowingCount:     user.FollowingCount,
		TotalLikesReceived: user.TotalLikesReceived,
		IsFollowing:        user.IsFollowing,
	}
}

// MarshalJSON 为仍使用 User 关联模型的旧接口提供最后一道公开字段保护。
// 本人资料必须由 handlers 的 SelfUserResponse 显式返回，不能依赖此方法。
func (u User) MarshalJSON() ([]byte, error) {
	return json.Marshal(PublicUser(u))
}

// IsStudentVerified 统一判断学生身份。短暂兼容尚未执行数据迁移的旧绑定记录，
// 生产迁移完成后该回退分支不应再命中。
func (u User) IsStudentVerified() bool {
	return u.StudentVerifiedAt != nil
}

// IsEduAuthorized 统一判断是否允许教务服务持有并使用凭据。
func (u User) IsEduAuthorized() bool {
	return u.EduAuthorized
}
