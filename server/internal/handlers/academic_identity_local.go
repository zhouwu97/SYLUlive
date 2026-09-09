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
