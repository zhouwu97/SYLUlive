package models

import (
	"errors"
	"fmt"
	"gorm.io/gorm"
	"strconv"
	"strings"
	"time"
)

// AcademicProviderID 是教务协议的稳定技术标识，显示名称不能用于服务端路由。
type AcademicProviderID string

const (
	// AcademicProviderUndergraduate 是现有本科教务服务的稳定技术 ID。
	AcademicProviderUndergraduate = "sylu_undergraduate"
	// AcademicProviderGraduate 是研究生教务服务的稳定技术 ID。
	AcademicProviderGraduate = "sylu_graduate"
)

const (
	AcademicProviderSyluUndergraduate AcademicProviderID = AcademicProviderUndergraduate
	AcademicProviderSyluGraduate      AcademicProviderID = AcademicProviderGraduate
	ProviderSyluUndergraduate                            = AcademicProviderSyluUndergraduate
	ProviderSyluGraduate                                 = AcademicProviderSyluGraduate
)

var ErrInvalidAcademicProvider = errors.New("无效的教务 provider")
var ErrInvalidAcademicStudentID = errors.New("无效的教务学号")

// ParseAcademicProviderID 只接受已注册的 Provider，拒绝客户端自定义上游目标。
func ParseAcademicProviderID(raw string) (AcademicProviderID, error) {
	provider := AcademicProviderID(strings.TrimSpace(raw))
	switch provider {
	case AcademicProviderSyluUndergraduate, AcademicProviderSyluGraduate:
		return provider, nil
	default:
		return "", ErrInvalidAcademicProvider
	}
}

// ValidateAcademicStudentID 将学号视为 Provider 内的 opaque 标识，不根据长度或前缀猜学生类型。
func ValidateAcademicStudentID(raw string) (string, error) {
	studentID := strings.TrimSpace(raw)
	if studentID == "" || len(studentID) > 128 || studentID != raw {
		return "", ErrInvalidAcademicStudentID
	}
	for _, r := range studentID {
		if r < 0x20 || r == 0x7f {
			return "", ErrInvalidAcademicStudentID
		}
	}
	return studentID, nil
}

// AcademicIdentityKey 是运行时 Provider、会话和本地保险箱必须共同携带的身份边界。
type AcademicIdentityKey struct {
	AppUserID  uint               `json:"app_user_id"`
	ProviderID AcademicProviderID `json:"provider_id"`
	StudentID  string             `json:"student_id"`
}

func (k AcademicIdentityKey) Validate() error {
	if k.AppUserID == 0 {
		return errors.New("无效的应用用户")
	}
	if _, err := ParseAcademicProviderID(string(k.ProviderID)); err != nil {
		return err
	}
	_, err := ValidateAcademicStudentID(k.StudentID)
	return err
}

func (k AcademicIdentityKey) Canonical() string {
	return strconv.FormatUint(uint64(k.AppUserID), 10) + "|" + string(k.ProviderID) + "|" + k.StudentID
}

func (k AcademicIdentityKey) Matches(other AcademicIdentityKey) bool {
	return k.AppUserID == other.AppUserID && k.ProviderID == other.ProviderID && k.StudentID == other.StudentID
}

// AcademicIdentityBinding 是服务端登记的学生身份；local_academic_login 表示客户端本机登录成功声明。
// 该表只保存最小身份事实，不保存学校密码、Cookie 或学校会话。
type AcademicIdentityBinding struct {
	BindingVersion      uint       `gorm:"not null;default:1" json:"binding_version"`
	ID                  uint       `gorm:"primaryKey" json:"id"`
	UserID              uint       `gorm:"not null;index:idx_academic_identity_user,priority:1;uniqueIndex:ux_academic_identity_user_provider,priority:1" json:"-"`
	ProviderID          string     `gorm:"size:64;not null;index:idx_academic_identity_user,priority:2;uniqueIndex:ux_academic_identity_user_provider,priority:2;uniqueIndex:ux_academic_identity_provider_student,priority:1" json:"provider_id"`
	StudentID           string     `gorm:"size:128;not null;index:idx_academic_identity_student;index:idx_academic_identity_user,priority:3;uniqueIndex:ux_academic_identity_provider_student,priority:2" json:"student_id"`
	VerifiedAt          time.Time  `gorm:"not null" json:"verified_at"`
	VerificationMethod  string     `gorm:"size:64;not null" json:"verification_method"`
	VerificationVersion string     `gorm:"size:32;not null" json:"verification_version"`
	ChangedAt           *time.Time `json:"changed_at,omitempty"`
	CreatedAt           time.Time  `json:"created_at"`
	UpdatedAt           time.Time  `json:"updated_at"`
}

func (b AcademicIdentityBinding) IdentityKey() AcademicIdentityKey {
	return AcademicIdentityKey{AppUserID: b.UserID, ProviderID: AcademicProviderID(b.ProviderID), StudentID: b.StudentID}
}

// Validate 检查模型边界，避免绕过 handler 直接写入不受支持的身份。
func (b AcademicIdentityBinding) Validate() error {
	if b.UserID == 0 {
		return errors.New("身份绑定缺少用户")
	}
	if _, err := ParseAcademicProviderID(b.ProviderID); err != nil {
		return err
	}
	if _, err := ValidateAcademicStudentID(b.StudentID); err != nil {
		return err
	}
	if b.VerifiedAt.IsZero() {
		return fmt.Errorf("身份绑定缺少验证时间")
	}
	if strings.TrimSpace(b.VerificationMethod) == "" || strings.TrimSpace(b.VerificationVersion) == "" {
		return errors.New("身份绑定缺少验证版本")
	}
	return nil
}

// AcademicIdentityChallenge 仅保存 challenge nonce 的摘要和消费状态。
// challenge token 本体由服务端 AEAD 封装后交给客户端，数据库不落学校临时会话。
type AcademicIdentityChallenge struct {
	ID            uint       `gorm:"primaryKey" json:"-"`
	UserID        uint       `gorm:"not null;index:idx_academic_challenge_user_created,priority:1" json:"-"`
	ProviderID    string     `gorm:"size:64;not null;index:idx_academic_challenge_provider_created,priority:1" json:"-"`
	StudentID     string     `gorm:"size:128;not null" json:"-"`
	NonceHash     string     `gorm:"size:64;not null;uniqueIndex" json:"-"`
	Fingerprint   string     `gorm:"size:128;not null" json:"-"`
	RequestIPHash string     `gorm:"size:64;not null;index:idx_academic_challenge_ip_created,priority:1" json:"-"`
	ExpiresAt     time.Time  `gorm:"not null;index" json:"-"`
	ConsumedAt    *time.Time `json:"-"`
	CreatedAt     time.Time  `gorm:"index:idx_academic_challenge_user_created,priority:2;index:idx_academic_challenge_provider_created,priority:2;index:idx_academic_challenge_ip_created,priority:2" json:"-"`
}

// HasVerifiedAcademicIdentity 只读取服务器认证事实，账号配置和旧授权不能授予学生权限。
func HasVerifiedAcademicIdentity(db *gorm.DB, userID uint) (bool, error) {
	var count int64
	err := db.Model(&AcademicIdentityBinding{}).Where("user_id = ? AND verified_at > ?", userID, time.Time{}).Count(&count).Error
	return count > 0, err
}
