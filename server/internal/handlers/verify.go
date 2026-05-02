package handlers

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"net/http"
	"net/smtp"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// VerifyHandler 验证码处理器
type VerifyHandler struct {
	db          *gorm.DB
	smtpHost    string
	smtpPort    string
	smtpUser    string
	smtpPass    string
}

func NewVerifyHandler(db *gorm.DB, host, port, user, pass string) *VerifyHandler {
	return &VerifyHandler{db: db, smtpHost: host, smtpPort: port, smtpUser: user, smtpPass: pass}
}

// SendCode 发送验证码到 QQ 邮箱
func (h *VerifyHandler) SendCode(c *gin.Context) {
	qq := c.PostForm("qq")
	if qq == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请输入QQ号"})
		return
	}
	if len(qq) < 5 || len(qq) > 15 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "QQ号格式不正确"})
		return
	}

	// 生成6位验证码
	code, _ := generateCode(6)
	expiresAt := time.Now().Add(5 * time.Minute)

	// 保存或更新
	var vc models.VerifyCode
	h.db.Where("qq = ?", qq).First(&vc)
	if vc.ID == 0 {
		vc = models.VerifyCode{QQ: qq, Code: code, ExpiresAt: expiresAt}
		h.db.Create(&vc)
	} else {
		h.db.Model(&vc).Updates(map[string]interface{}{"code": code, "expires_at": expiresAt})
	}

	// 发送邮件
	to := fmt.Sprintf("%s@qq.com", qq)
	auth := smtp.PlainAuth("", h.smtpUser, h.smtpPass, h.smtpHost)
	msg := []byte(fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: 沈理校园 - 注册验证码\r\n\r\n您的验证码是：%s\r\n5分钟内有效。", h.smtpUser, to, code))

	go func() {
		addr := fmt.Sprintf("%s:%s", h.smtpHost, h.smtpPort)
		smtp.SendMail(addr, auth, h.smtpUser, []string{to}, msg)
	}()

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "验证码已发送"})
}

// VerifyCode 校验验证码
func (h *VerifyHandler) VerifyCode(c *gin.Context) {
	qq := c.PostForm("qq")
	inputCode := c.PostForm("code")
	if qq == "" || inputCode == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数不完整"})
		return
	}

	var vc models.VerifyCode
	if err := h.db.Where("qq = ?", qq).First(&vc).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请先发送验证码"})
		return
	}

	if time.Now().After(vc.ExpiresAt) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码已过期"})
		return
	}

	if vc.Code != inputCode {
		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码错误"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "验证通过"})
}

func generateCode(length int) (string, error) {
	code := ""
	for i := 0; i < length; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(10))
		if err != nil {
			return "", err
		}
		code += fmt.Sprintf("%d", n)
	}
	return code, nil
}
