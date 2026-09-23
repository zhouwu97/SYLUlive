package models

import (
	"time"

	"gorm.io/gorm"
)

// AcademicIdentityVerificationInventory 是身份依据的只读盘点结果。
//
// 用途只有一个：在正式放行之前回答「legacy_migration 到底有多少、是不是都该继续可信」。
// 它只输出计数和已登记/未登记的取值清单，不返回学号、用户 ID 或任何可还原的标识——
// 盘点要看的是规模和异常形态，不是具体是谁。
type AcademicIdentityVerificationInventory struct {
	Total        int64            `json:"total"`
	ByMethod     map[string]int64 `json:"by_method"`
	TrustedTotal int64            `json:"trusted_total"`
	// SchoolVerified 是本次（或历史）可被服务端独立核验的学校身份。
	SchoolVerified int64 `json:"school_verified"`
	// LegacyInherited 是历史回填继承下来的准入，尚未在当前版本重新核验。
	LegacyInherited int64 `json:"legacy_inherited"`
	// LocalDeclaration 只是设备侧声明，不授予可信身份。
	LocalDeclaration int64 `json:"local_declaration"`
	// Unregistered 是既不在可信白名单、也不在写入规范里的历史脏值。
	Unregistered int64 `json:"unregistered"`
	// UnregisteredMethods 列出实际出现过的未登记取值，供人工迁移时定位来源。
	UnregisteredMethods []string `json:"unregistered_methods"`
	// MethodWhitespaceDirty 是 verification_method 带首尾空白的行数。
	//
	// 判权用精确匹配（见 [IsTrustedAcademicVerificationMethod]），这类值不会被静默
	// 当成可信，但它们说明历史写入曾经绕过 [ValidateAcademicVerificationMethod]。
	MethodWhitespaceDirty int64 `json:"method_whitespace_dirty"`
	// MissingVerifiedAt 是缺少验证时间的绑定：准入的最低事实都不完整。
	MissingVerifiedAt int64 `json:"missing_verified_at"`
	// SharedStudentIDs 是同一教务提供方内同一学号挂在多个账号上的数量（可信绑定内）。
	SharedStudentIDs int64 `json:"shared_student_ids"`
	// MultiStudentAccounts 是同一账号挂了多个学号的数量（可信绑定内），同样需人工核对。
	MultiStudentAccounts int64 `json:"multi_student_accounts"`
}

// ReadAcademicIdentityVerificationInventory 只读盘点身份依据分布。
//
// 与 [scripts/academic_identity_inventory.sql] 覆盖同一批事实，但可以直接从管理端读取：
// 盘点如果必须靠人上生产机器敲 psql，就一定会被拖到「以后再说」，而信任债务不会自己消失。
// 本函数只做 SELECT，不修改任何身份状态。
func ReadAcademicIdentityVerificationInventory(db *gorm.DB) (AcademicIdentityVerificationInventory, error) {
	result := AcademicIdentityVerificationInventory{ByMethod: map[string]int64{}}
	if db == nil {
		return result, gorm.ErrInvalidDB
	}

	type methodCount struct {
		Method string
		Total  int64
	}
	var methodCounts []methodCount
	if err := db.Model(&AcademicIdentityBinding{}).
		Select("verification_method AS method, COUNT(*) AS total").
		Group("verification_method").
		Scan(&methodCounts).Error; err != nil {
		return result, err
	}
	for _, row := range methodCounts {
		result.ByMethod[row.Method] = row.Total
		result.Total += row.Total
		switch {
		case IsUnregisteredAcademicVerificationMethod(row.Method):
			result.Unregistered += row.Total
			result.UnregisteredMethods = append(result.UnregisteredMethods, row.Method)
		case row.Method == AcademicVerificationMethodSchoolProfile:
			result.SchoolVerified += row.Total
			result.TrustedTotal += row.Total
		case row.Method == AcademicVerificationMethodLegacyMigration:
			result.LegacyInherited += row.Total
			result.TrustedTotal += row.Total
		case row.Method == AcademicVerificationMethodLocalDeclaration:
			result.LocalDeclaration += row.Total
		}
	}
	// ByMethod 的键是原样取值（可能带空白），分类按精确匹配，两者故意分开：
	// 「库里实际存了什么」和「判权认什么」是两个需要分别核对的事实。

	if err := db.Model(&AcademicIdentityBinding{}).
		Where("verification_method <> TRIM(verification_method)").
		Count(&result.MethodWhitespaceDirty).Error; err != nil {
		return result, err
	}
	// verified_at 是 not null，缺失会以零值落库；1970 之前一律视为缺失。
	if err := db.Model(&AcademicIdentityBinding{}).
		Where("verified_at < ?", time.Unix(0, 0).UTC()).
		Count(&result.MissingVerifiedAt).Error; err != nil {
		return result, err
	}

	// 关系异常用显式子查询数「有多少个学号/账号」，不用 GORM 的 Group+Count：
	// 后者在带 GROUP BY 时生成的 SQL 各驱动行为不一致，盘点数字必须唯一确定。
	if err := db.Raw(`SELECT COUNT(*) FROM (
			SELECT provider_id, student_id FROM academic_identity_bindings
			WHERE verification_method IN ?
			GROUP BY provider_id, student_id HAVING COUNT(DISTINCT user_id) > 1
		) AS shared_student_ids`, trustedAcademicVerificationMethods).
		Scan(&result.SharedStudentIDs).Error; err != nil {
		return result, err
	}
	if err := db.Raw(`SELECT COUNT(*) FROM (
			SELECT user_id FROM academic_identity_bindings
			WHERE verification_method IN ?
			GROUP BY user_id HAVING COUNT(DISTINCT student_id) > 1
		) AS multi_student_accounts`, trustedAcademicVerificationMethods).
		Scan(&result.MultiStudentAccounts).Error; err != nil {
		return result, err
	}
	return result, nil
}
