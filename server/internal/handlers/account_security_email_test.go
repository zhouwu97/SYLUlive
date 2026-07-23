package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type accountSecurityTestMailer struct {
	codes map[string]string
}

func (m *accountSecurityTestMailer) SendVerificationCode(email string, purpose string, code string) error {
	if m.codes == nil {
		m.codes = make(map[string]string)
	}
	m.codes[email+":"+purpose] = code
	return nil
}

func TestEmailResetChallengeCannotResetNewEmailOwner(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.EmailVerificationChallenge{}, &models.AccountSecurityAuditLog{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	now := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	mailer := &accountSecurityTestMailer{}
	verification := services.NewEmailVerificationService(db, mailer, "test-ip-secret", func() time.Time { return now })

	originalHash, err := bcrypt.GenerateFromPassword([]byte("original-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("生成密码哈希失败: %v", err)
	}
	ownerHash, err := bcrypt.GenerateFromPassword([]byte("owner-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("生成密码哈希失败: %v", err)
	}
	email := "transfer@example.com"
	oldOwner := models.User{StudentID: "old-owner", Email: email, EmailVerifiedAt: &now, PasswordHash: string(originalHash), Nickname: "旧所有者"}
	newOwner := models.User{StudentID: "new-owner", Email: "other@example.com", EmailVerifiedAt: &now, PasswordHash: string(ownerHash), Nickname: "新所有者"}
	if err := db.Create(&oldOwner).Error; err != nil {
		t.Fatalf("创建旧所有者失败: %v", err)
	}
	if err := db.Create(&newOwner).Error; err != nil {
		t.Fatalf("创建新所有者失败: %v", err)
	}
	if err := verification.Request(email, models.EmailVerificationPurposeResetPassword, &oldOwner.ID, "127.0.0.1"); err != nil {
		t.Fatalf("请求重置验证码失败: %v", err)
	}

	// 模拟邮箱被修改后释放、随后被另一账号绑定的状态。
	if err := db.Model(&models.User{}).Where("id = ?", oldOwner.ID).Updates(map[string]interface{}{"email": "", "email_verified_at": nil}).Error; err != nil {
		t.Fatalf("释放旧邮箱失败: %v", err)
	}
	if err := db.Model(&models.User{}).Where("id = ?", newOwner.ID).Updates(map[string]interface{}{"email": email, "email_verified_at": now}).Error; err != nil {
		t.Fatalf("转移邮箱失败: %v", err)
	}

	handler := NewAuthHandlerWithEmailVerification(db, "test-secret", verification)
	router := gin.New()
	router.POST("/reset", handler.ResetPasswordByEmail)
	payload, _ := json.Marshal(map[string]string{
		"email":        email,
		"code":         mailer.codes[email+":"+models.EmailVerificationPurposeResetPassword],
		"new_password": "replacement-password",
	})
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/reset", bytes.NewReader(payload)))
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("重置响应=%d，期望=%d，内容=%s", recorder.Code, http.StatusBadRequest, recorder.Body.String())
	}

	var storedNewOwner models.User
	if err := db.First(&storedNewOwner, newOwner.ID).Error; err != nil {
		t.Fatalf("读取新所有者失败: %v", err)
	}
	if bcrypt.CompareHashAndPassword([]byte(storedNewOwner.PasswordHash), []byte("owner-password")) != nil {
		t.Fatal("旧验证码不应重置邮箱新所有者的密码")
	}
	var challenge models.EmailVerificationChallenge
	if err := db.Where("user_id = ?", oldOwner.ID).First(&challenge).Error; err != nil {
		t.Fatalf("读取验证码失败: %v", err)
	}
	if challenge.ConsumedAt != nil {
		t.Fatal("业务校验失败时验证码不应被消费")
	}
}
