package handlers

import (
	"fmt"
	"net/http"
	"net/smtp"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// FeedbackHandler 反馈处理器
type FeedbackHandler struct {
	db *gorm.DB
}

// NewFeedbackHandler 创建反馈处理器
func NewFeedbackHandler(db *gorm.DB) *FeedbackHandler {
	return &FeedbackHandler{db: db}
}

type feedbackInput struct {
	Content string `json:"content" binding:"required"`
}

// Submit 用户提交反馈，通过SMTP发送邮件给开发者
func (h *FeedbackHandler) Submit(c *gin.Context) {
	var input feedbackInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "反馈内容不能为空"})
		return
	}

	// 获取当前用户信息
	userID, _ := c.Get("user_id")
	var user models.User
	nickname := "未知用户"
	studentID := "未知"
	if err := h.db.First(&user, userID).Error; err == nil {
		nickname = user.Nickname
		studentID = user.StudentID
	}

	// 检查 SMTP 配置
	if VerifyCodeConfig.SMTPHost == "" || VerifyCodeConfig.SMTPUser == "" || VerifyCodeConfig.SMTPPass == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "邮件服务未配置，反馈提交失败"})
		return
	}

	// 发送邮件到开发者邮箱
	to := "13514252317@163.com"
	subject := fmt.Sprintf("【沈理校园反馈】来自 %s", nickname)
	body := fmt.Sprintf(`
<html>
  <body style="font-family: Arial, 'PingFang SC', 'Microsoft YaHei', sans-serif; line-height: 1.6; color: #222;">
    <h2 style="margin: 0 0 12px; color: #4F46E5;">📮 用户反馈</h2>
    <table style="border-collapse: collapse; margin: 12px 0;">
      <tr>
        <td style="padding: 6px 12px; color: #666;">用户昵称</td>
        <td style="padding: 6px 12px; font-weight: bold;">%s</td>
      </tr>
      <tr>
        <td style="padding: 6px 12px; color: #666;">学号/QQ</td>
        <td style="padding: 6px 12px; font-weight: bold;">%s</td>
      </tr>
      <tr>
        <td style="padding: 6px 12px; color: #666;">提交时间</td>
        <td style="padding: 6px 12px;">%s</td>
      </tr>
    </table>
    <div style="margin: 16px 0; padding: 16px; background: #F5F3FF; border-radius: 10px; border-left: 4px solid #4F46E5;">
      <p style="margin: 0; white-space: pre-wrap;">%s</p>
    </div>
  </body>
</html>`, nickname, studentID, time.Now().Format("2006-01-02 15:04:05"), input.Content)

	addr := VerifyCodeConfig.SMTPHost + ":" + VerifyCodeConfig.SMTPPort
	auth := smtp.PlainAuth("", VerifyCodeConfig.SMTPUser, VerifyCodeConfig.SMTPPass, VerifyCodeConfig.SMTPHost)
	message := []byte("To: " + to + "\r\n" +
		"From: " + VerifyCodeConfig.SMTPFrom + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/html; charset=UTF-8\r\n\r\n" +
		body)

	if err := smtp.SendMail(addr, auth, VerifyCodeConfig.SMTPFrom, []string{to}, message); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "邮件发送失败，请稍后重试"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "反馈已提交，感谢您的建议！"})
}
