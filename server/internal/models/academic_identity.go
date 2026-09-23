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

const (
	// AcademicVerificationMethodSchoolProfile 表示学校响应可被服务器独立核验。
	AcademicVerificationMethodSchoolProfile = "school_profile"
	// AcademicVerificationMethodLocalDeclaration 只是客户端本机登录成功后的设备侧声明。
	AcademicVerificationMethodLocalDeclaration = "local_academic_login"
	// AcademicVerificationMethodLegacyMigration 回填自旧版本已持久化的学号认证标记。
	// 它按兼容策略继承历史准入状态，但不能表述为本次学校核验。
	AcademicVerificationMethodLegacyMigration = "legacy_migration"
)

// trustedAcademicVerificationMethods 是服务端当前承认学生准入资格的来源白名单。
//
// 这里是白名单而不是排除名单：空值、历史脏数据、以及未来新增但尚未登记的取值
// 一律不授予可信身份。legacy_migration 仅为兼容历史服务器认证而保留，依据强度仍单独标记为
// [AcademicAssuranceLegacyInherited]。新增可信方式必须显式登记到这里，并同时满足
// [ValidateAcademicVerificationMethod] 的写入规范。
var trustedAcademicVerificationMethods = []string{
	AcademicVerificationMethodSchoolProfile,
	AcademicVerificationMethodLegacyMigration,
}

// knownAcademicVerificationMethods 是写入规范允许出现的全部取值，
// 含不授予可信身份的 [AcademicVerificationMethodLocalDeclaration]。
var knownAcademicVerificationMethods = []string{
	AcademicVerificationMethodSchoolProfile,
	AcademicVerificationMethodLegacyMigration,
	AcademicVerificationMethodLocalDeclaration,
}

// IsTrustedAcademicVerificationMethod 检查身份是否仍在服务端准入白名单中。
// legacy_migration 由于兼容策略会返回 true，但不等于本次学校核验。
//
// Go 与 [TrustedAcademicBindingScope] 都用**精确匹配**，不做 TrimSpace。
// 这里曾经两边尺子不一样：Go 判权前 Trim，SQL 直接比原值，而 SQLite 的 TRIM()
// 只吃空格、不吃制表符和换行，于是带换行的 legacy_migration 在 Go 侧可信、
// 在 SQL 侧不可信。判权必须只有一把尺子；带空白的历史记录一律不授予可信身份，
// 由 [IsUnregisteredAcademicVerificationMethod] 暴露后人工迁移，而不是被静默当成可信。
func IsTrustedAcademicVerificationMethod(method string) bool {
	for _, trusted := range trustedAcademicVerificationMethods {
		if method == trusted {
			return true
		}
	}
	return false
}

// ValidateAcademicVerificationMethod 是写入规范：只允许登记过的取值，且不允许带首尾空白。
// 判权用精确匹配，写入侧就不该产生带空白的记录，否则历史数据清理永远做不完。
func ValidateAcademicVerificationMethod(method string) error {
	if method == "" || method != strings.TrimSpace(method) {
		return errors.New("身份绑定的核验方式不合法")
	}
	for _, known := range knownAcademicVerificationMethods {
		if method == known {
			return nil
		}
	}
	return fmt.Errorf("未登记的身份核验方式 %q", method)
}

// TrustedAcademicVerificationMethods 返回当前准入白名单，仅供盘点与测试。
func TrustedAcademicVerificationMethods() []string {
	return append([]string(nil), trustedAcademicVerificationMethods...)
}

// IsUnregisteredAcademicVerificationMethod 判断一条记录是不是既不在可信白名单、
// 也不在写入规范里的历史脏数据。本机声明属于登记过但不授予可信身份的正常状态。
func IsUnregisteredAcademicVerificationMethod(method string) bool {
	return ValidateAcademicVerificationMethod(method) != nil
}

// TrustedAcademicBindingScope 给身份表查询加上与 Go 侧判权完全一致的准入白名单约束，
// 避免各处手写 `verification_method <> 'local_academic_login'` 后各自漂移。
// 与 [IsTrustedAcademicVerificationMethod] 一样精确匹配（见那里的注释）。
func TrustedAcademicBindingScope(db *gorm.DB) *gorm.DB {
	return db.Where("verification_method IN ?", trustedAcademicVerificationMethods)
}

// AcademicAssuranceLevel 提供给 API/UI 的依据强度，区分历史回填、本机声明和学校核验。
func AcademicAssuranceLevel(method string) string {
	if method == AcademicVerificationMethodLegacyMigration {
		return AcademicAssuranceLegacyInherited
	}
	if IsTrustedAcademicVerificationMethod(method) {
		return AcademicAssuranceSchoolVerified
	}
	return AcademicAssuranceLocalDeclaration
}

const (
	AcademicAssuranceSchoolVerified   = "school_verified"
	AcademicAssuranceLocalDeclaration = "local_declaration"
	AcademicAssuranceLegacyInherited  = "legacy_inherited"
)

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
	if err := ValidateAcademicVerificationMethod(b.VerificationMethod); err != nil {
		return err
	}
	if strings.TrimSpace(b.VerificationVersion) == "" {
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

// HasVerifiedAcademicIdentity 只读取当前身份准入白名单；历史回填按兼容策略保留准入，
// 但不代表该用户在当前版本重新通过了学校核验。
func HasVerifiedAcademicIdentity(db *gorm.DB, userID uint) (bool, error) {
	var count int64
	err := TrustedAcademicBindingScope(db.Model(&AcademicIdentityBinding{}).
		Where("user_id = ? AND verified_at > ?", userID, time.Time{})).Count(&count).Error
	return count > 0, err
}
