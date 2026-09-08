package handlers

import (
	"encoding/json"
	"errors"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	"strings"
	"time"
)

var errAcademicBindingChanged = errors.New("原学生身份版本已变化")

// 换绑沿用短期学校挑战协议，但 operation 和旧绑定版本必须由服务端签名。
func (h *AcademicIdentityHandler) CreateChangeChallenge(c *gin.Context) {
	c.Set("academic_change", true)
	h.CreateChallenge(c)
}

func (h *AcademicIdentityHandler) Change(c *gin.Context) {
	c.Set("academic_change", true)
	h.Verify(c)
}

func (h *AcademicIdentityHandler) changeBinding(claims academicChallengeClaims, now time.Time) error {
	return h.db.Transaction(func(tx *gorm.DB) error {
		var current models.AcademicIdentityBinding
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", claims.CurrentBindingID, claims.UserID).First(&current).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return errAcademicBindingChanged
		}
		if err != nil {
			return err
		}
		if current.BindingVersion != claims.CurrentBindingVersion || current.ProviderID != claims.CurrentProviderID || current.StudentID != claims.CurrentStudentID {
			return errAcademicBindingChanged
		}
		result := tx.Model(&models.AcademicIdentityBinding{}).Where("id = ? AND binding_version = ?", current.ID, claims.CurrentBindingVersion).Updates(map[string]interface{}{
			"provider_id": claims.ProviderID, "student_id": claims.StudentID,
			"verified_at": now, "changed_at": now, "binding_version": claims.CurrentBindingVersion + 1,
			"verification_method": academicChallengeMethod, "verification_version": academicChallengeVersion,
		})
		if result.Error != nil {
			if strings.Contains(strings.ToLower(result.Error.Error()), "unique") {
				return errAcademicIdentityAlreadyBound
			}
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errAcademicBindingChanged
		}

		// 撤销被替换的旧本科投影与授权，避免身份列表或后台任务重新挂回旧学号。
		if current.ProviderID == models.AcademicProviderUndergraduate {
			var user models.User
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, claims.UserID).Error; err != nil {
				return err
			}
			updates := map[string]interface{}{}
			if user.StudentID == current.StudentID {
				updates["student_verified_at"] = nil
			}
			if user.EduStudentID == current.StudentID {
				updates["edu_authorized"] = false
				updates["edu_bound"] = false
				updates["edu_session_state"] = "revoked"
				updates["edu_auto_relogin"] = false
				updates["edu_password"] = ""
				updates["edu_cookie"] = ""
				updates["edu_cleanup_pending"] = true
				updates["edu_binding_state"] = "cleanup_pending"
				job := models.EduCredentialCleanupJob{UserID: user.ID, ExpectedGeneration: user.EduAuthorizationGeneration, RevokedAt: &now, NextAttemptAt: now}
				if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&job).Error; err != nil {
					return err
				}
			}
			if len(updates) > 0 {
				if err := tx.Model(&user).Updates(updates).Error; err != nil {
					return err
				}
			}
		}
		// 审计与身份更新同一事务，不记录密码、验证码、公钥挑战或学校会话。
		metadata, err := json.Marshal(map[string]interface{}{"binding_id": current.ID, "binding_version": claims.CurrentBindingVersion + 1, "old_provider": current.ProviderID, "new_provider": claims.ProviderID})
		if err != nil {
			return err
		}
		return tx.Create(&models.AccountSecurityAuditLog{UserID: claims.UserID, Action: "academic_identity_change", Metadata: string(metadata), CreatedAt: now}).Error
	})
}
