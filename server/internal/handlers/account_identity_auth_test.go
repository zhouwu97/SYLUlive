package handlers

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const accountIdentityTestPassword = "app-password"

func openAccountIdentityAuthDB(t *testing.T) (*gorm.DB, *services.EmailVerificationService, time.Time) {
	t.Helper()
	name := strings.NewReplacer("/", "-", " ", "-").Replace(t.Name())
	db, err := gorm.Open(sqlite.Open("file:"+name+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开身份认证测试数据库失败: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("读取底层数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(
		&models.User{},
		&models.UserLegalConsent{},
		&models.EmailVerificationChallenge{},
		&models.EmailVerificationRequest{},
		&models.AccountSecurityAuditLog{},
	); err != nil {
		t.Fatalf("迁移身份认证测试表失败: %v", err)
	}
	if err := models.EnsureAccountIdentitySchema(db); err != nil {
		t.Fatalf("迁移身份基础表失败: %v", err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	verification := services.NewEmailVerificationService(
		db,
		&accountSecurityTestMailer{},
		"identity-auth-test-ip-secret",
		func() time.Time { return now },
	)
	return db, verification, now
}

func createAccountIdentityAuthUser(t *testing.T, db *gorm.DB, user models.User) models.User {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte(accountIdentityTestPassword), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("生成 APP 密码哈希失败: %v", err)
	}
	user.PasswordHash = string(hash)
	if user.AccountStatus == "" {
		user.AccountStatus = "active"
	}
	if user.Role == "" {
		user.Role = models.RoleUser
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建身份认证测试用户失败: %v", err)
	}
	return user
}

func createAccountIdentityChallenge(
	t *testing.T,
	db *gorm.DB,
	email string,
	purpose string,
	userID *uint,
	code string,
	now time.Time,
) models.EmailVerificationChallenge {
	t.Helper()
	normalized, err := services.NormalizeEmail(email)
	if err != nil {
		t.Fatalf("规范化测试邮箱失败: %v", err)
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(code), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("生成验证码哈希失败: %v", err)
	}
	challenge := models.EmailVerificationChallenge{
		UserID: userID, Email: normalized, Purpose: purpose, CodeHash: string(hash),
		ExpiresAt: now.Add(10 * time.Minute), RequestIPHash: "test-ip", CreatedAt: now,
	}
	if err := db.Create(&challenge).Error; err != nil {
		t.Fatalf("创建邮箱验证码失败: %v", err)
	}
	return challenge
}

func performIdentityJSONRequest(router http.Handler, method string, path string, payload interface{}) *httptest.ResponseRecorder {
	body, _ := json.Marshal(payload)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(method, path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, request)
	return recorder
}

func TestLoginRequiresVerifiedIdentityAndReturnsSingleOpaqueMiss(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, _, now := openAccountIdentityAuthDB(t)
	user := createAccountIdentityAuthUser(t, db, models.User{
		Email: "login@example.com", EmailVerifiedAt: &now, Nickname: "邮箱登录用户",
	})
	handler := NewAuthHandler(db, "identity-login-secret")
	if err := handler.SetAccountIdentityReadMode(AccountIdentityReadModeIdentity); err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.POST("/login", handler.Login)

	missing := performIdentityJSONRequest(router, http.MethodPost, "/login", map[string]string{
		"account": user.Email, "password": accountIdentityTestPassword,
	})
	if missing.Code != http.StatusNotFound {
		t.Fatalf("仅有邮箱镜像时登录状态=%d body=%s", missing.Code, missing.Body.String())
	}
	decoder := json.NewDecoder(bytes.NewReader(missing.Body.Bytes()))
	var errorBody map[string]interface{}
	if err := decoder.Decode(&errorBody); err != nil {
		t.Fatalf("解析统一登录错误失败: %v", err)
	}
	if errorBody["error"] != "账号或密码错误" {
		t.Fatalf("登录未命中响应泄露账号状态: %s", missing.Body.String())
	}
	if err := decoder.Decode(&map[string]interface{}{}); err != io.EOF {
		t.Fatalf("登录未命中写入了多个 JSON 响应: err=%v body=%q", err, missing.Body.String())
	}

	if _, err := services.CreateEmailIdentity(db, user.ID, user.Email, now); err != nil {
		t.Fatalf("创建登录 Identity 失败: %v", err)
	}
	success := performIdentityJSONRequest(router, http.MethodPost, "/login", map[string]string{
		"account": " LOGIN@EXAMPLE.COM ", "password": accountIdentityTestPassword,
	})
	if success.Code != http.StatusOK {
		t.Fatalf("有效邮箱 Identity 登录失败: status=%d body=%s", success.Code, success.Body.String())
	}
	var response struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(success.Body.Bytes(), &response); err != nil || response.Token == "" {
		t.Fatalf("邮箱登录未返回会话: err=%v body=%s", err, success.Body.String())
	}
}

func TestLoginRejectsLegacyAccountsEvenFromStudentIDCompatibilityField(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, _, now := openAccountIdentityAuthDB(t)
	student := createAccountIdentityAuthUser(t, db, models.User{
		StudentID: "2026000201", StudentVerifiedAt: &now, Nickname: "学号用户",
	})
	qq := createAccountIdentityAuthUser(t, db, models.User{QQ: "87654321", Nickname: "QQ 用户"})
	handler := NewAuthHandler(db, "legacy-login-secret")
	if err := handler.SetAccountIdentityReadMode(AccountIdentityReadModeIdentity); err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.POST("/login", handler.Login)
	router.POST("/login_edu", handler.LoginEdu)

	testCases := []struct {
		name      string
		fieldName string
		account   string
		userID    uint
	}{
		{name: "student_id_compatibility_field", fieldName: "student_id", account: student.StudentID, userID: student.ID},
		{name: "qq_account_field", fieldName: "account", account: qq.QQ, userID: qq.ID},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			payload := map[string]string{testCase.fieldName: testCase.account, "password": accountIdentityTestPassword}
			ordinary := performIdentityJSONRequest(router, http.MethodPost, "/login", payload)
			if ordinary.Code != http.StatusBadRequest || !containsJSONCode(ordinary.Body.Bytes(), "EMAIL_LOGIN_REQUIRED") {
				t.Fatalf("普通登录接受了旧账号: status=%d body=%s", ordinary.Code, ordinary.Body.String())
			}
			legacy := performIdentityJSONRequest(router, http.MethodPost, "/login_edu", payload)
			if legacy.Code != http.StatusOK {
				t.Fatalf("独立旧账号登录失败: status=%d body=%s", legacy.Code, legacy.Body.String())
			}
			var response struct {
				User struct {
					ID uint `json:"id"`
				} `json:"user"`
			}
			if err := json.Unmarshal(legacy.Body.Bytes(), &response); err != nil || response.User.ID != testCase.userID {
				t.Fatalf("旧账号路由解析用户错误: err=%v body=%s", err, legacy.Body.String())
			}
		})
	}
}

func TestLoginDefaultsToLegacyEmailStudentIDAndQQCompatibilityReads(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, _, now := openAccountIdentityAuthDB(t)
	emailUser := createAccountIdentityAuthUser(t, db, models.User{
		Email: "legacy-mode@example.com", EmailVerifiedAt: &now, Nickname: "旧邮箱用户",
	})
	student := createAccountIdentityAuthUser(t, db, models.User{
		StudentID: "2026999911", StudentVerifiedAt: &now, Nickname: "旧学号用户",
	})
	qq := createAccountIdentityAuthUser(t, db, models.User{QQ: "76543210", Nickname: "旧 QQ 用户"})

	handler := NewAuthHandler(db, "default-legacy-secret")
	router := gin.New()
	router.POST("/login", handler.Login)
	testCases := []struct {
		name    string
		payload map[string]string
		userID  uint
	}{
		{name: "email_mirror", payload: map[string]string{"account": " LEGACY-MODE@EXAMPLE.COM ", "password": accountIdentityTestPassword}, userID: emailUser.ID},
		{name: "student_id_compatibility_field", payload: map[string]string{"student_id": student.StudentID, "password": accountIdentityTestPassword}, userID: student.ID},
		{name: "qq", payload: map[string]string{"account": qq.QQ, "password": accountIdentityTestPassword}, userID: qq.ID},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			recorder := performIdentityJSONRequest(router, http.MethodPost, "/login", testCase.payload)
			if recorder.Code != http.StatusOK {
				t.Fatalf("legacy 默认模式登录失败: status=%d body=%s", recorder.Code, recorder.Body.String())
			}
			var response struct {
				User struct {
					ID uint `json:"id"`
				} `json:"user"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response.User.ID != testCase.userID {
				t.Fatalf("legacy 默认模式解析用户错误: err=%v body=%s", err, recorder.Body.String())
			}
		})
	}
}

func TestSetAccountIdentityReadModeRejectsUnknownValue(t *testing.T) {
	handler := NewAuthHandler(nil, "mode-secret")
	if err := handler.SetAccountIdentityReadMode("fallback"); err == nil {
		t.Fatal("未知账号读模式必须被拒绝")
	}
}

func TestLegacyQQRegisterWithEmailServiceCreatesIdentityAndConsumesChallenge(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, verification, now := openAccountIdentityAuthDB(t)
	const qq = "13579246"
	const email = qq + "@qq.com"
	const code = "654321"
	challenge := createAccountIdentityChallenge(t, db, email, models.EmailVerificationPurposeRegister, nil, code, now)
	handler := NewAuthHandlerWithEmailVerification(db, "legacy-register-identity-secret", verification)
	router := gin.New()
	router.POST("/register", handler.Register)
	recorder := performIdentityJSONRequest(router, http.MethodPost, "/register", map[string]interface{}{
		"qq": qq, "code": code, "password": accountIdentityTestPassword,
		"user_agreement_accepted": true, "privacy_policy_accepted": true,
		"community_rules_accepted": true, "minor_protection_accepted": true,
		"content_complaint_accepted": true, "sdk_disclosure_accepted": true,
	})
	if recorder.Code != http.StatusCreated {
		t.Fatalf("旧 QQ 注册失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var user models.User
	if err := db.Where("qq = ?", qq).First(&user).Error; err != nil {
		t.Fatal(err)
	}
	identity, err := services.FindActiveEmailIdentity(db, email)
	if err != nil || identity.UserID != user.ID {
		t.Fatalf("旧 QQ 注册未事务写入 Email Identity: identity=%+v err=%v", identity, err)
	}
	var storedChallenge models.EmailVerificationChallenge
	if err := db.First(&storedChallenge, challenge.ID).Error; err != nil {
		t.Fatal(err)
	}
	if storedChallenge.ConsumedAt == nil {
		t.Fatal("旧 QQ 注册成功后验证码未消费")
	}
}

func TestRegisterWithEmailCreatesIdentityInChallengeTransaction(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, verification, now := openAccountIdentityAuthDB(t)
	const email = "new-account@example.com"
	const code = "123456"
	challenge := createAccountIdentityChallenge(t, db, email, models.EmailVerificationPurposeRegister, nil, code, now)
	handler := NewAuthHandlerWithEmailVerification(db, "register-identity-secret", verification)
	router := gin.New()
	router.POST("/register", handler.RegisterWithEmail)
	recorder := performIdentityJSONRequest(router, http.MethodPost, "/register", map[string]interface{}{
		"email": email, "code": code, "password": accountIdentityTestPassword,
		"user_agreement_accepted": true, "privacy_policy_accepted": true,
	})
	if recorder.Code != http.StatusCreated {
		t.Fatalf("邮箱注册失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var user models.User
	if err := db.Where("email = ?", email).First(&user).Error; err != nil {
		t.Fatalf("读取注册用户失败: %v", err)
	}
	identity, err := services.FindActiveEmailIdentity(db, email)
	if err != nil || identity.UserID != user.ID {
		t.Fatalf("注册未创建同用户 Email Identity: identity=%+v err=%v", identity, err)
	}
	var storedChallenge models.EmailVerificationChallenge
	if err := db.First(&storedChallenge, challenge.ID).Error; err != nil || storedChallenge.ConsumedAt == nil {
		t.Fatalf("注册验证码未随事务消费: challenge=%+v err=%v", storedChallenge, err)
	}
}

func TestUpdateUserEmailDualWritesIdentityAndMirror(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, verification, now := openAccountIdentityAuthDB(t)
	user := createAccountIdentityAuthUser(t, db, models.User{
		StudentID: "2026000301", StudentVerifiedAt: &now,
		Email: "old@example.com", EmailVerifiedAt: &now, Nickname: "修改邮箱用户",
	})
	if _, err := services.CreateEmailIdentity(db, user.ID, user.Email, now); err != nil {
		t.Fatal(err)
	}
	const newEmail = "new@example.com"
	const code = "234567"
	challenge := createAccountIdentityChallenge(t, db, newEmail, models.EmailVerificationPurposeChange, &user.ID, code, now)
	handler := NewAuthHandlerWithEmailVerification(db, "change-identity-secret", verification)
	router := gin.New()
	router.PUT("/email", func(context *gin.Context) { context.Set("user_id", user.ID) }, handler.UpdateUserEmail)
	recorder := performIdentityJSONRequest(router, http.MethodPut, "/email", map[string]string{
		"email": newEmail, "code": code, "password": accountIdentityTestPassword,
	})
	if recorder.Code != http.StatusOK {
		t.Fatalf("修改邮箱失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Email != newEmail || stored.EmailVerifiedAt == nil || stored.TokenVersion != user.TokenVersion+1 {
		t.Fatalf("邮箱镜像未更新: %+v", stored)
	}
	newIdentity, err := services.FindActiveEmailIdentity(db, newEmail)
	if err != nil || newIdentity.UserID != user.ID {
		t.Fatalf("新 Email Identity 错误: identity=%+v err=%v", newIdentity, err)
	}
	var oldIdentity models.UserLoginIdentity
	if err := db.Where("type = ? AND identifier_normalized = ?", models.LoginIdentityTypeEmail, user.Email).First(&oldIdentity).Error; err != nil {
		t.Fatal(err)
	}
	if oldIdentity.DisabledAt == nil {
		t.Fatal("旧 Email Identity 未禁用")
	}
	var storedChallenge models.EmailVerificationChallenge
	if err := db.First(&storedChallenge, challenge.ID).Error; err != nil || storedChallenge.ConsumedAt == nil {
		t.Fatalf("修改邮箱验证码未消费: challenge=%+v err=%v", storedChallenge, err)
	}
}

func TestUpdateUserEmailConflictRollsBackMirrorIdentityAndChallenge(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, verification, now := openAccountIdentityAuthDB(t)
	user := createAccountIdentityAuthUser(t, db, models.User{
		StudentID: "2026000302", StudentVerifiedAt: &now,
		Email: "rollback-old@example.com", EmailVerifiedAt: &now, Nickname: "冲突用户",
	})
	owner := createAccountIdentityAuthUser(t, db, models.User{
		Email: "occupied@example.com", EmailVerifiedAt: &now, Nickname: "邮箱拥有者",
	})
	if _, err := services.CreateEmailIdentity(db, user.ID, user.Email, now); err != nil {
		t.Fatal(err)
	}
	if _, err := services.CreateEmailIdentity(db, owner.ID, owner.Email, now); err != nil {
		t.Fatal(err)
	}
	const code = "345678"
	challenge := createAccountIdentityChallenge(t, db, owner.Email, models.EmailVerificationPurposeChange, &user.ID, code, now)
	handler := NewAuthHandlerWithEmailVerification(db, "conflict-identity-secret", verification)
	router := gin.New()
	router.PUT("/email", func(context *gin.Context) { context.Set("user_id", user.ID) }, handler.UpdateUserEmail)
	recorder := performIdentityJSONRequest(router, http.MethodPut, "/email", map[string]string{
		"email": owner.Email, "code": code, "password": accountIdentityTestPassword,
	})
	if recorder.Code != http.StatusConflict || !containsJSONCode(recorder.Body.Bytes(), "EMAIL_ALREADY_BOUND") {
		t.Fatalf("邮箱冲突响应错误: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Email != user.Email || stored.TokenVersion != user.TokenVersion {
		t.Fatalf("冲突后邮箱镜像或 token_version 被修改: %+v", stored)
	}
	oldIdentity, err := services.FindActiveEmailIdentity(db, user.Email)
	if err != nil || oldIdentity.UserID != user.ID {
		t.Fatalf("冲突后旧 Identity 未保留: identity=%+v err=%v", oldIdentity, err)
	}
	occupiedIdentity, err := services.FindActiveEmailIdentity(db, owner.Email)
	if err != nil || occupiedIdentity.UserID != owner.ID {
		t.Fatalf("冲突后目标 Identity 被篡改: identity=%+v err=%v", occupiedIdentity, err)
	}
	var storedChallenge models.EmailVerificationChallenge
	if err := db.First(&storedChallenge, challenge.ID).Error; err != nil || storedChallenge.ConsumedAt != nil {
		t.Fatalf("冲突时验证码应回滚为未消费: challenge=%+v err=%v", storedChallenge, err)
	}
}

func TestDeleteUserEmailDisablesIdentityAndClearsMirror(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, verification, now := openAccountIdentityAuthDB(t)
	user := createAccountIdentityAuthUser(t, db, models.User{
		StudentID: "2026000303", StudentVerifiedAt: &now,
		Email: "remove@example.com", EmailVerifiedAt: &now, Nickname: "解除邮箱用户",
	})
	if _, err := services.CreateEmailIdentity(db, user.ID, user.Email, now); err != nil {
		t.Fatal(err)
	}
	handler := NewAuthHandlerWithEmailVerification(db, "remove-identity-secret", verification)
	router := gin.New()
	router.DELETE("/email", func(context *gin.Context) { context.Set("user_id", user.ID) }, handler.DeleteUserEmail)
	recorder := performIdentityJSONRequest(router, http.MethodDelete, "/email", map[string]string{
		"password": accountIdentityTestPassword,
	})
	if recorder.Code != http.StatusOK {
		t.Fatalf("解除邮箱失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Email != "" || stored.EmailVerifiedAt != nil || stored.TokenVersion != user.TokenVersion+1 {
		t.Fatalf("解除邮箱后镜像错误: %+v", stored)
	}
	if _, err := services.FindActiveEmailIdentity(db, user.Email); !errors.Is(err, gorm.ErrRecordNotFound) {
		t.Fatalf("解除邮箱后 Identity 仍有效: %v", err)
	}
	var identity models.UserLoginIdentity
	if err := db.Where("type = ? AND identifier_normalized = ?", models.LoginIdentityTypeEmail, user.Email).First(&identity).Error; err != nil {
		t.Fatal(err)
	}
	if identity.DisabledAt == nil {
		t.Fatal("解除邮箱未保留禁用审计行")
	}
}
