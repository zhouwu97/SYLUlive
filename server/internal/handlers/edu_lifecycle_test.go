package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestRegisterWithEduIssuesUsableCurrentAuthSession(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.EduCredentialCleanupJob{}, &models.CheckIn{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/api/edu/pre_verify":
			_, _ = writer.Write([]byte(`{"success":true,"student_id":"2026000101","name":"测试学生"}`))
		case "/api/edu/bind":
			_, _ = writer.Write([]byte(`{"success":true,"student_id":"2026000101","name":"测试学生","grade":"2026","college":"计算机学院","major":"软件工程"}`))
		default:
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()
	previousConfig := EduServiceConfig
	EduServiceConfig.BaseURL = upstream.URL
	EduServiceConfig.Token = "test-token"
	defer func() { EduServiceConfig = previousConfig }()

	const jwtSecret = "register-with-edu-test-secret"
	authHandler := NewAuthHandler(db, jwtSecret)
	userHandler := NewUserHandler(db)
	router := gin.New()
	router.POST("/register", authHandler.RegisterWithEdu)
	protected := router.Group("/protected")
	protected.Use(middleware.AuthMiddleware(db, jwtSecret))
	protected.GET("/profile", userHandler.GetProfile)

	payload := []byte(`{
		"student_id":"2026000101",
		"edu_password":"edu-password",
		"password":"app-password",
		"user_agreement_accepted":true,
		"privacy_policy_accepted":true,
		"edu_data_consent_accepted":true
	}`)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/register", bytes.NewReader(payload)))
	if recorder.Code != http.StatusCreated {
		t.Fatalf("注册失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var response struct {
		Token string           `json:"token"`
		User  SelfUserResponse `json:"user"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析注册响应失败: %v", err)
	}
	if response.Token == "" || !response.User.StudentVerified || !response.User.EduAuthorized || response.User.EduSessionState != "active" {
		t.Fatalf("注册响应未反映已提交的教务身份: %#v", response)
	}

	claims := &middleware.Claims{}
	parsed, err := jwt.ParseWithClaims(response.Token, claims, func(token *jwt.Token) (interface{}, error) {
		return []byte(jwtSecret), nil
	})
	if err != nil || !parsed.Valid {
		t.Fatalf("解析注册令牌失败: %v", err)
	}
	var stored models.User
	if err := db.First(&stored, response.User.ID).Error; err != nil {
		t.Fatalf("读取注册用户失败: %v", err)
	}
	if claims.TokenVersion != stored.TokenVersion {
		t.Fatalf("令牌版本=%d，数据库版本=%d", claims.TokenVersion, stored.TokenVersion)
	}

	profileRecorder := httptest.NewRecorder()
	profileRequest := httptest.NewRequest(http.MethodGet, "/protected/profile", nil)
	profileRequest.Header.Set("Authorization", "Bearer "+response.Token)
	router.ServeHTTP(profileRecorder, profileRequest)
	if profileRecorder.Code != http.StatusOK {
		t.Fatalf("新令牌无法访问受保护接口: status=%d body=%s", profileRecorder.Code, profileRecorder.Body.String())
	}
}

func TestGetEduStatusCannotRestoreConcurrentRevocation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	user := models.User{
		StudentID: "2026000001", PasswordHash: "hash", EduStudentID: "2026000001",
		EduAuthorized: true, EduBound: true, EduSessionState: "active",
		EduAuthorizationGeneration: 4,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}

	started := make(chan struct{})
	allowResponse := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		close(started)
		<-allowResponse
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"authorized":true,"bound":true,"session_state":"active","auto_relogin":true,"student_id":"2026000001"}`))
	}))
	defer upstream.Close()
	previousConfig := EduServiceConfig
	EduServiceConfig.BaseURL = upstream.URL
	EduServiceConfig.Token = "test-token"
	defer func() { EduServiceConfig = previousConfig }()

	handler := NewEduHandler(db)
	router := gin.New()
	router.GET("/status", func(context *gin.Context) {
		context.Set("user_id", user.ID)
	}, handler.GetEduStatus)
	recorder := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/status", nil))
		close(done)
	}()
	<-started
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
		"edu_authorized":      false,
		"edu_bound":           false,
		"edu_session_state":   "revoked",
		"edu_cleanup_pending": true,
	}).Error; err != nil {
		t.Fatalf("并发撤销授权失败: %v", err)
	}
	close(allowResponse)
	<-done

	if recorder.Code != http.StatusOK {
		t.Fatalf("查询状态失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析响应失败: %v", err)
	}
	if response["edu_authorized"] != false || response["edu_session_state"] != "revoked" {
		t.Fatalf("远端旧状态覆盖了本地撤销: %s", recorder.Body.String())
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatalf("读取用户失败: %v", err)
	}
	if stored.EduAuthorized || stored.EduBound || stored.EduSessionState != "revoked" {
		t.Fatalf("本地撤销状态被恢复: %#v", stored)
	}
}

func TestPrepareEduBindingReusesPersistedPendingGeneration(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	user := models.User{
		StudentID: "2026000012", PasswordHash: "hash", AccountStatus: "active",
		EduAuthorizationGeneration: 3,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}
	firstGeneration, err := prepareEduBinding(db, user.ID, user.StudentID)
	if err != nil {
		t.Fatalf("准备首次绑定失败: %v", err)
	}
	secondGeneration, err := prepareEduBinding(db, user.ID, user.StudentID)
	if err != nil {
		t.Fatalf("准备重试绑定失败: %v", err)
	}
	if firstGeneration != 4 || secondGeneration != firstGeneration {
		t.Fatalf("待绑定代次未被复用: first=%d second=%d", firstGeneration, secondGeneration)
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatalf("读取待绑定用户失败: %v", err)
	}
	if stored.EduBindingState != "pending" || stored.EduBindingPendingGeneration != firstGeneration || stored.EduBindingPendingStudentID != user.StudentID || stored.EduBindingStartedAt == nil {
		t.Fatalf("待绑定状态未持久化: %#v", stored)
	}
}

func TestLoginEduIsRetired(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	handler := NewAuthHandler(db, "test-secret")
	router := gin.New()
	router.POST("/login_edu", handler.LoginEdu)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/login_edu", nil))
	if recorder.Code != http.StatusGone || !containsJSONCode(recorder.Body.Bytes(), "LEGACY_EDU_LOGIN_RETIRED") {
		t.Fatalf("旧教务登录入口未退役: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestFailedEduRegistrationCompensationPersistsIdentityDeletionJob(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.EduCredentialCleanupJob{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	user := models.User{
		StudentID:     "2026000002",
		PasswordHash:  "hash",
		AccountStatus: "registration_pending",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建注册占位账号失败: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer upstream.Close()
	previousConfig := EduServiceConfig
	EduServiceConfig.BaseURL = upstream.URL
	EduServiceConfig.Token = "test-token"
	defer func() { EduServiceConfig = previousConfig }()

	cleanupJobs := services.NewEduCredentialCleanupJobService(db, nil, nil)
	handler := NewAuthHandlerWithEmailVerificationAndCleanup(db, "test-secret", nil, cleanupJobs)
	if handler.compensateFailedEduRegistrationBinding(user.ID) {
		t.Fatal("远端清理失败不应被当作已完成")
	}

	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatalf("读取补偿账号失败: %v", err)
	}
	if stored.AccountStatus != "registration_cleanup_pending" || stored.EduAuthorized || stored.EduBound || stored.EduSessionState != "revoked" || !stored.EduCleanupPending {
		t.Fatalf("补偿账号状态错误: %#v", stored)
	}
	var job models.EduCredentialCleanupJob
	if err := db.Where("user_id = ? AND completed_at IS NULL", user.ID).First(&job).Error; err != nil {
		t.Fatalf("未写入远端清理任务: %v", err)
	}
	if !job.DeleteIdentity || job.ExpectedGeneration != 1 {
		t.Fatalf("远端清理任务语义错误: %#v", job)
	}
}

func TestRevokeEduAuthorizationRevokesEducationConsent(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AccountSecurityAuditLog{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	user := models.User{
		StudentID: "2026000004", PasswordHash: "hash", EduStudentID: "2026000004",
		EduAuthorized: true, EduBound: true, EduSessionState: "active", EduAuthorizationGeneration: 1,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}
	if err := db.Create(&models.UserLegalConsent{
		UserID: user.ID, Document: models.LegalDocumentEduDataConsent, Version: models.LegalDocumentVersion,
		AcknowledgementType: "separate_consent", Scope: "education", Scene: "edu_binding",
	}).Error; err != nil {
		t.Fatalf("创建教务授权记录失败: %v", err)
	}

	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/edu/authorization" {
			writer.WriteHeader(http.StatusNotFound)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"success":true}`))
	}))
	defer upstream.Close()
	previousConfig := EduServiceConfig
	EduServiceConfig.BaseURL = upstream.URL
	EduServiceConfig.Token = "test-token"
	defer func() { EduServiceConfig = previousConfig }()

	handler := NewEduHandler(db)
	router := gin.New()
	router.DELETE("/authorization", func(context *gin.Context) { context.Set("user_id", user.ID) }, handler.RevokeEduAuthorization)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodDelete, "/authorization", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("撤销教务授权失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var consent models.UserLegalConsent
	if err := db.Where("user_id = ? AND document = ?", user.ID, models.LegalDocumentEduDataConsent).First(&consent).Error; err != nil {
		t.Fatalf("读取教务授权记录失败: %v", err)
	}
	if consent.RevokedAt == nil {
		t.Fatal("撤销教务授权后专项同意记录仍处于有效状态")
	}
}

func TestChangePasswordReturnsRefreshedAuthSession(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("迁移测试表失败: %v", err)
	}
	oldPassword := "old-password"
	passwordHash, err := bcrypt.GenerateFromPassword([]byte(oldPassword), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("生成密码哈希失败: %v", err)
	}
	user := models.User{StudentID: "2026000003", PasswordHash: string(passwordHash), AccountStatus: "active"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}

	handler := NewAuthHandler(db, "test-secret")
	router := gin.New()
	router.POST("/change_password", func(context *gin.Context) {
		context.Set("user_id", user.ID)
	}, handler.ChangePassword)
	payload, err := json.Marshal(map[string]string{
		"old_password": oldPassword,
		"new_password": "new-password",
	})
	if err != nil {
		t.Fatalf("序列化修改密码请求失败: %v", err)
	}
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/change_password", bytes.NewReader(payload)))
	if recorder.Code != http.StatusOK {
		t.Fatalf("修改密码失败: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Token string          `json:"token"`
		User  json.RawMessage `json:"user"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("解析修改密码响应失败: %v", err)
	}
	if response.Token == "" || len(response.User) == 0 || string(response.User) == "null" {
		t.Fatalf("修改密码未返回新会话: %s", recorder.Body.String())
	}
	var stored models.User
	if err := db.First(&stored, user.ID).Error; err != nil {
		t.Fatalf("读取修改后的用户失败: %v", err)
	}
	if stored.TokenVersion != user.TokenVersion+1 || bcrypt.CompareHashAndPassword([]byte(stored.PasswordHash), []byte("new-password")) != nil {
		t.Fatalf("密码或会话版本未正确更新: %#v", stored)
	}
}

func containsJSONCode(body []byte, expected string) bool {
	var response map[string]string
	return json.Unmarshal(body, &response) == nil && response["code"] == expected
}
