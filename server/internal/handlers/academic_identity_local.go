package handlers

import (
	"encoding/json"
	"io"
	"net/http"
	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
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
	if decoder.Decode(&input) != nil || decoder.Decode(&extra) != io.EOF || input.Method != models.AcademicVerificationMethodLocalDeclaration {
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
	var user models.User
	if err := h.db.Select("id", "account_status").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"code": "BINDING_UNAVAILABLE", "error": "学生身份暂未同步，请稍后重试"})
		return
	}
	if user.AccountStatus != "" && user.AccountStatus != "active" {
		c.JSON(http.StatusForbidden, gin.H{"code": "ACCOUNT_RESTRICTED"})
		return
	}
	// 本机声明只用于本次设备查询，不写入 AcademicIdentityBinding：它不是服务器可独立核验的事实，
	// 也不能占用跨账号唯一学号绑定。需要可信判权时必须走学校响应可独立核验的 verify 路径。
	c.JSON(http.StatusOK, gin.H{
		"provider_id": input.ProviderID, "student_id": input.StudentID,
		"verified": false, "assurance_level": models.AcademicAssuranceLocalDeclaration,
		"verification_method": models.AcademicVerificationMethodLocalDeclaration,
		"message":             "本机连接声明已接收，不构成服务器可信学生认证",
	})
}
