package handlers

import (
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"net/http"
	"shenliyuan/internal/models"
	"time"
)

// Unbind 解除指定教务身份；兼容投影与旧授权一起撤销，避免重启后恢复旧绑定。
func (h *AcademicIdentityHandler) Unbind(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.Status(http.StatusUnauthorized)
		return
	}
	var input struct {
		ProviderID string `json:"provider_id"`
		StudentID  string `json:"student_id"`
	}
	if c.ShouldBindJSON(&input) != nil {
		c.Status(http.StatusBadRequest)
		return
	}
	if _, err := models.ParseAcademicProviderID(input.ProviderID); err != nil {
		c.Status(http.StatusBadRequest)
		return
	}
	if _, err := models.ValidateAcademicStudentID(input.StudentID); err != nil {
		c.Status(http.StatusBadRequest)
		return
	}
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var bindings []models.AcademicIdentityBinding
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("user_id = ? AND provider_id = ? AND student_id = ?", userID, input.ProviderID, input.StudentID).Find(&bindings).Error; err != nil {
			return err
		}
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		updates := map[string]interface{}{}
		provider := string(user.AcademicProviderID)
		if provider == "" {
			provider = models.AcademicProviderUndergraduate
		}
		if provider == input.ProviderID && user.StudentID == input.StudentID {
			updates["student_id"] = ""
			updates["student_verified_at"] = nil
			updates["academic_provider_id"] = ""
		}
		if input.ProviderID == models.AcademicProviderUndergraduate && user.EduStudentID == input.StudentID {
			updates["edu_authorized"] = false
			updates["edu_bound"] = false
			updates["edu_session_state"] = "revoked"
			updates["edu_auto_relogin"] = false
			updates["edu_password"] = ""
			updates["edu_cookie"] = ""
			updates["edu_cleanup_pending"] = true
			now := time.Now()
			job := models.EduCredentialCleanupJob{UserID: userID, ExpectedGeneration: user.EduAuthorizationGeneration, RevokedAt: &now, NextAttemptAt: now}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&job).Error; err != nil {
				return err
			}
		}
		if len(updates) > 0 {
			if err := tx.Model(&user).Updates(updates).Error; err != nil {
				return err
			}
		}
		// 使尚未提交的挑战失效，解绑前的验证码不能再次绑定回来。
		if err := tx.Model(&models.AcademicIdentityChallenge{}).Where("user_id = ?", userID).Update("consumed_at", time.Now()).Error; err != nil {
			return err
		}
		return tx.Where("user_id = ? AND provider_id = ? AND student_id = ?", userID, input.ProviderID, input.StudentID).Delete(&models.AcademicIdentityBinding{}).Error
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解除教务绑定失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"unbound": true})
}
