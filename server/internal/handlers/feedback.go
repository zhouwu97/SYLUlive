package handlers

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"html"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/http"
	"net/smtp"
	"net/textproto"
	"os"
	"path/filepath"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const maxFeedbackImages = 4

// maxEmailMessageSize 是整个 MIME 消息编码后的上限，对齐常见 SMTP 附件总大小限制（163 等约 25MB）。
var maxEmailMessageSize = 25 << 20

var errFeedbackEmailTooLarge = errors.New("feedback email exceeds size limit")

// FeedbackHandler 反馈处理器
type FeedbackHandler struct {
	db        *gorm.DB
	uploadDir string
}

// NewFeedbackHandler 创建反馈处理器
func NewFeedbackHandler(db *gorm.DB, uploadDir string) *FeedbackHandler {
	return &FeedbackHandler{db: db, uploadDir: uploadDir}
}

type feedbackInput struct {
	Content  string `json:"content" binding:"required"`
	Type     string `json:"type"`
	ImageIDs []uint `json:"image_ids"`
	Contact  string `json:"contact"`
}

// Submit 用户提交反馈，通过SMTP发送邮件给开发者。
// 截图以 MIME 附件内嵌进邮件，文件保持 access_scope=private，绝不走公开 /uploads。
func (h *FeedbackHandler) Submit(c *gin.Context) {
	var input feedbackInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "反馈内容不能为空"})
		return
	}

	// 获取当前用户信息；匿名反馈不携带 user_id。
	userID, _ := c.Get("user_id")
	nickname := "未知用户"
	studentID := "未知"
	if uid, ok := userID.(uint); ok && uid > 0 {
		var user models.User
		if err := h.db.First(&user, uid).Error; err == nil {
			nickname = user.Nickname
			studentID = user.StudentID
		}
	}

	// 反馈附件必须证明归属：上传本身已要求登录，因此带截图时必须是已认证用户。
	var attached []models.File
	if len(input.ImageIDs) > 0 {
		uid, ok := userID.(uint)
		if !ok || uid == 0 {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录后再上传截图"})
			return
		}
		files, err := services.ValidateImageFileIDs(h.db, input.ImageIDs, maxFeedbackImages, uid)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "截图无效，请重新上传"})
			return
		}
		attached = files
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
	if len(attached) > 0 {
		imagesHtml = `<div style="margin-top: 16px;"><strong>📎 附图：</strong><br>`
		for i := range attached {
			imagesHtml += fmt.Sprintf(`<img src="cid:feedback-image-%d" alt="截图 %d" style="display: block; max-width: 100%%; margin-top: 8px; border-radius: 8px;" />`, i+1, i+1)
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

	// 截图先置为 active（仍保持 private），再构建并发送邮件。
	// claim 幂等；若邮件发送失败用户可重试，不会残留"已发送却报错"的矛盾状态。
	if len(input.ImageIDs) > 0 {
		if err := services.ClaimPrivateFiles(h.db, input.ImageIDs); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "反馈提交失败，请稍后重试"})
			return
		}
	}

	message, err := buildFeedbackEmail(h.uploadDir, to, VerifyCodeConfig.SMTPFrom, subject, body, attached)
	if err != nil {
		if errors.Is(err, errFeedbackEmailTooLarge) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "截图过大，邮件服务无法发送，请精简后重试"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "邮件构建失败，请稍后重试"})
		return
	}

	addr := VerifyCodeConfig.SMTPHost + ":" + VerifyCodeConfig.SMTPPort
	auth := smtp.PlainAuth("", VerifyCodeConfig.SMTPUser, VerifyCodeConfig.SMTPPass, VerifyCodeConfig.SMTPHost)
	if err := smtp.SendMail(addr, auth, VerifyCodeConfig.SMTPFrom, []string{to}, message); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "邮件发送失败，请稍后重试"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "反馈已提交，感谢您的建议！"})
}

// buildFeedbackEmail 组装 multipart/related 邮件：HTML 为根部件，截图以 Content-ID 内嵌
// （供 <img src="cid:..."> 引用）。截图从磁盘读取，直接作为 MIME 附件发送，不生成任何公网链接。
// 任意一张预期截图构造失败都会让整封邮件构建失败，绝不静默缺图。
func buildFeedbackEmail(uploadDir, to, from, subject, body string, files []models.File) ([]byte, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	fmt.Fprintf(&buf, "To: %s\r\n", to)
	fmt.Fprintf(&buf, "From: %s\r\n", from)
	fmt.Fprintf(&buf, "Subject: %s\r\n", mime.QEncoding.Encode("utf-8", subject))
	fmt.Fprintf(&buf, "MIME-Version: 1.0\r\n")
	fmt.Fprintf(&buf, "Content-Type: multipart/related; boundary=%s; type=\"text/html\"\r\n", mw.Boundary())
	fmt.Fprintf(&buf, "\r\n")

	// HTML 正文含中文与 emoji，不能用 7bit；quoted-printable 对以 ASCII 为主的 HTML 膨胀最小。
	textHeader := textproto.MIMEHeader{}
	textHeader.Set("Content-Type", "text/html; charset=UTF-8")
	textHeader.Set("Content-Transfer-Encoding", "quoted-printable")
	textPart, err := mw.CreatePart(textHeader)
	if err != nil {
		return nil, err
	}
	qp := quotedprintable.NewWriter(textPart)
	if _, err := qp.Write([]byte(body)); err != nil {
		qp.Close()
		return nil, err
	}
	if err := qp.Close(); err != nil {
		return nil, err
	}

	for i, file := range files {
		path, err := services.ResolveUploadPath(uploadDir, file.Path)
		if err != nil {
			return nil, fmt.Errorf("resolve attachment %d: %w", i+1, err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read attachment %d: %w", i+1, err)
		}
		imgHeader := textproto.MIMEHeader{}
		imgHeader.Set("Content-Type", file.MimeType)
		imgHeader.Set("Content-Transfer-Encoding", "base64")
		imgHeader.Set("Content-ID", fmt.Sprintf("<feedback-image-%d>", i+1))
		imgHeader.Set("Content-Disposition", fmt.Sprintf(`inline; filename="screenshot_%d%s"`, i+1, filepath.Ext(file.Path)))
		imgPart, err := mw.CreatePart(imgHeader)
		if err != nil {
			return nil, fmt.Errorf("create attachment %d: %w", i+1, err)
		}
		enc := base64.NewEncoder(base64.StdEncoding, imgPart)
		if _, err := enc.Write(data); err != nil {
			enc.Close()
			return nil, fmt.Errorf("write attachment %d: %w", i+1, err)
		}
		if err := enc.Close(); err != nil {
			return nil, fmt.Errorf("finalize attachment %d: %w", i+1, err)
		}
	}

	if err := mw.Close(); err != nil {
		return nil, err
	}
	if buf.Len() > maxEmailMessageSize {
		return nil, errFeedbackEmailTooLarge
	}
	return buf.Bytes(), nil
}
