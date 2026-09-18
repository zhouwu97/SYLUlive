package handlers

import (
	"encoding/json"
	"errors"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"io"
	"net/http"
	"shenliyuan/internal/models"
	"time"
)

// BindLocal 接受官方客户端本机登录成功声明；HK 不连接学校、不接收学校凭据。
func (h *AcademicIdentityHandler) BindLocal(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "authentication_required"})
		return
	}
	var input struct {
		ProviderID string `json:"provider_id"`
		StudentID  string `json:"student_id"`
		Method     string `json:"verification_method"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 2048))
	decoder.DisallowUnknownFields()
	var extra any
	if decoder.Decode(&input) != nil || decoder.Decode(&extra) != io.EOF || input.Method != "local_academic_login" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "INVALID_LOCAL_BINDING"})
		return
	}
	if _, err := models.ParseAcademicProviderID(input.ProviderID); err != nil {
		c.JSON(400, gin.H{"code": "INVALID_PROVIDER"})
		return
	}
	if _, err := models.ValidateAcademicStudentID(input.StudentID); err != nil {
		c.JSON(400, gin.H{"code": "INVALID_STUDENT_ID"})
		return
	}
	// 本地登录成功后的重复回调是正常现象；相同绑定直接读回事实，避免每次都锁用户并开启写事务。
	var existing models.AcademicIdentityBinding
	if err := h.db.Where("user_id = ? AND provider_id = ? AND student_id = ?", userID, input.ProviderID, input.StudentID).First(&existing).Error; err == nil {
		var user models.User
		if userErr := h.db.Select("id", "account_status").First(&user, userID).Error; userErr != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"code": "BINDING_UNAVAILABLE", "error": "学生身份暂未同步，请稍后重试"})
			return
		}
		if user.AccountStatus != "" && user.AccountStatus != "active" {
			c.JSON(http.StatusForbidden, gin.H{"code": "ACCOUNT_RESTRICTED"})
			return
		}
		h.writeVerifiedBinding(c, userID, input.ProviderID, input.StudentID)
		return
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusServiceUnavailable, gin.H{"code": "BINDING_UNAVAILABLE", "error": "学生身份暂未同步，请稍后重试"})
		return
	}
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.AccountStatus != "" && user.AccountStatus != "active" {
			return errAcademicIdentityRejectedLocal
		}
		var binding models.AcademicIdentityBinding
		err := tx.Where("user_id = ? AND provider_id = ?", userID, input.ProviderID).First(&binding).Error
		if err == nil {
			if binding.StudentID != input.StudentID {
				return errAcademicIdentityImmutable
			}
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		return persistAcademicIdentityBinding(tx, userID, input.ProviderID, input.StudentID, time.Now().UTC(), "local_academic_login", "v1")
	})
	switch {
	case errors.Is(err, errAcademicIdentityImmutable):
		c.JSON(409, gin.H{"code": "ACADEMIC_BINDING_CHANGED", "error": "此教务类型已绑定其他学号，请先解除原绑定"})
	case errors.Is(err, errAcademicIdentityAlreadyBound):
		c.JSON(409, gin.H{"code": "ACADEMIC_IDENTITY_ALREADY_BOUND", "error": "该学号已绑定其他 App 账号"})
	case errors.Is(err, errAcademicIdentityRejectedLocal):
		c.JSON(403, gin.H{"code": "ACCOUNT_RESTRICTED"})
	case err != nil:
		c.JSON(503, gin.H{"code": "BINDING_UNAVAILABLE", "error": "学生身份暂未同步，请稍后重试"})
	default:
		h.writeVerifiedBinding(c, userID, input.ProviderID, input.StudentID)
	}
}

var errAcademicIdentityRejectedLocal = errors.New("local identity account restricted")
