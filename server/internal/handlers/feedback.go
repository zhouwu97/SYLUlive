package handlers

import (
	"fmt"
	"html"
	"net/http"
	"net/smtp"
	"os"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
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
	Content string   `json:"content" binding:"required"`
	Type    string   `json:"type"`
	Images  []string `json:"images"`
	Contact string   `json:"contact"`
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
	to := os.Getenv("FEEDBACK_EMAIL_TO")
	if to == "" {
		to = "13514252317@163.com"
	}
	if to == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "未配置反馈接收邮箱，无法提交反馈"})
		return
	}
	subject := fmt.Sprintf("【沈理校园反馈】来自 %s", nickname)

	badge := "💡 功能建议"
	badgeColor := "#3B82F6" // 蓝色
	if input.Type == "bug" {
		badge = "🐛 Bug 反馈"
		badgeColor = "#EF4444" // 红色
	}

	contactRow := ""
	if input.Contact != "" {
		contactRow = fmt.Sprintf(`
      <tr>
        <td style="padding: 6px 12px; color: #666;">联系方式</td>
        <td style="padding: 6px 12px; font-weight: bold;">%s</td>
      </tr>`, html.EscapeString(input.Contact))
	}

	imagesHtml := ""
	if len(input.Images) > 0 {
		imagesHtml = `<div style="margin-top: 16px;"><strong>📎 附图：</strong><br>`
		scheme := "http"
		if c.Request.TLS != nil || c.GetHeader("X-Forwarded-Proto") == "https" {
			scheme = "https"
		}
		host := c.Request.Host
		for i, imgUrl := range input.Images {
			fullUrl := imgUrl
			if !strings.HasPrefix(fullUrl, "http") {
				if !strings.HasPrefix(fullUrl, "/") {
					fullUrl = "/" + fullUrl
				}
				fullUrl = scheme + "://" + host + fullUrl
			}
			imagesHtml += fmt.Sprintf(`<a href="%s" target="_blank" style="display: inline-block; margin-right: 10px; color: #4F46E5; text-decoration: none;">📷 截图 %d</a>`, html.EscapeString(fullUrl), i+1)
		}
		imagesHtml += `</div>`
	}

	body := fmt.Sprintf(`
<html>
  <body style="font-family: Arial, 'PingFang SC', 'Microsoft YaHei', sans-serif; line-height: 1.6; color: #222;">
    <h2 style="margin: 0 0 12px; color: %s;">%s</h2>
    <table style="border-collapse: collapse; margin: 12px 0;">
      <tr>
        <td style="padding: 6px 12px; color: #666;">用户昵称</td>
        <td style="padding: 6px 12px; font-weight: bold;">%s</td>
      </tr>
      <tr>
        <td style="padding: 6px 12px; color: #666;">学号/QQ</td>
        <td style="padding: 6px 12px; font-weight: bold;">%s</td>
      </tr>%s
      <tr>
        <td style="padding: 6px 12px; color: #666;">提交时间</td>
        <td style="padding: 6px 12px;">%s</td>
      </tr>
    </table>
    <div style="margin: 16px 0; padding: 16px; background: #F5F3FF; border-radius: 10px; border-left: 4px solid #4F46E5;">
      <p style="margin: 0; white-space: pre-wrap;">%s</p>
    </div>
    %s
  </body>
</html>`, badgeColor, badge, html.EscapeString(nickname), html.EscapeString(studentID), contactRow, time.Now().Format("2006-01-02 15:04:05"), html.EscapeString(input.Content), imagesHtml)

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
