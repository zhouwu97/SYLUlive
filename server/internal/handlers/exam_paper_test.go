package handlers

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type examPaperTestEnv struct {
	db      *gorm.DB
	files   *services.ExamPaperFileService
	handler *ExamPaperHandler
	root    string
}

func newExamPaperTestEnv(t *testing.T) examPaperTestEnv {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{TranslateError: true})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.ExamPaper{},
		&models.ExamPaperUploadSession{},
		&models.ExamPaperStorageJob{},
		&models.Conversation{},
		&models.Message{},
		&models.AdminLog{},
	); err != nil {
		t.Fatalf("迁移测试数据库失败: %v", err)
	}
	if err := models.EnsureExamPaperIndexes(db); err != nil {
		t.Fatalf("创建试卷索引失败: %v", err)
	}
	if err := models.EnsureConversationIndexes(db); err != nil {
		t.Fatalf("创建私信索引失败: %v", err)
	}
	root := t.TempDir()
	files, err := services.NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化试卷文件服务失败: %v", err)
	}
	return examPaperTestEnv{
		db:      db,
		files:   files,
		handler: NewExamPaperHandler(db, files),
		root:    root,
	}
}

func createExamPaperTestUser(t *testing.T, db *gorm.DB, studentID string, role models.Role, eduBound bool, exp int) models.User {
	t.Helper()
	user := models.User{
		StudentID:    studentID,
		PasswordHash: "test",
		Nickname:     studentID,
		Role:         role,
		EduBound:     eduBound,
		Exp:          exp,
		Avatar:       "/uploads/avatar.png",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建测试用户失败: %v", err)
	}
	return user
}

func buildHandlerTestPDF() []byte {
	return buildHandlerTestPDFWithComment("")
}

func buildHandlerTestPDFWithComment(comment string) []byte {
	objects := []string{
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>\nendobj\n",
		"4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n",
	}
	var pdf bytes.Buffer
	pdf.WriteString("%PDF-1.4\n")
	if comment != "" {
		pdf.WriteString("% " + comment + "\n")
	}
	offsets := make([]int, len(objects)+1)
	for index, object := range objects {
		offsets[index+1] = pdf.Len()
		pdf.WriteString(object)
	}
	xrefOffset := pdf.Len()
	pdf.WriteString(fmt.Sprintf("xref\n0 %d\n", len(objects)+1))
	pdf.WriteString("0000000000 65535 f \n")
	for index := 1; index <= len(objects); index++ {
		pdf.WriteString(fmt.Sprintf("%010d 00000 n \n", offsets[index]))
	}
	pdf.WriteString(fmt.Sprintf("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objects)+1, xrefOffset))
	return pdf.Bytes()
}

func performExamPaperRequest(handler gin.HandlerFunc, method, path string, params gin.Params, userID uint, body []byte, contentType string) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, bytes.NewReader(body))
	if contentType != "" {
		context.Request.Header.Set("Content-Type", contentType)
	}
	context.Params = params
	context.Set("user_id", userID)
	handler(context)
	return recorder
}

func buildExamPaperUploadBody(t *testing.T, privacyConfirmed bool, pdf []byte) ([]byte, string) {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	fields := map[string]string{
		"course_name":       "高等数学",
		"academic_year":     "2025-2026",
		"semester":          "first",
		"exam_type":         "final",
		"privacy_confirmed": fmt.Sprintf("%t", privacyConfirmed),
	}
	for key, value := range fields {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatalf("写入 multipart 字段失败: %v", err)
		}
	}
	part, err := writer.CreateFormFile("file", "高数期末.pdf")
	if err != nil {
		t.Fatalf("创建 multipart 文件失败: %v", err)
	}
	if _, err := part.Write(pdf); err != nil {
		t.Fatalf("写入 multipart 文件失败: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("关闭 multipart 写入器失败: %v", err)
	}
	return body.Bytes(), writer.FormDataContentType()
}

func decodeErrorCode(t *testing.T, recorder *httptest.ResponseRecorder) string {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析错误响应失败: %v body=%s", err, recorder.Body.String())
	}
	code, _ := payload["code"].(string)
	return code
}

func TestExamPaperResponseReportsWhetherRewardIsRevocable(t *testing.T) {
	rewardedAt := time.Now().Add(-time.Hour)
	revokedAt := time.Now()

	unrewarded := examPaperToResponse(models.ExamPaper{})
	if unrewarded.RewardRevocable {
		t.Fatal("从未奖励的试卷不得标记为可撤销奖励")
	}
	revocable := examPaperToResponse(models.ExamPaper{RewardedAt: &rewardedAt})
	if !revocable.RewardRevocable {
		t.Fatal("已奖励且未撤销的试卷必须标记为可撤销奖励")
	}
	revoked := examPaperToResponse(models.ExamPaper{RewardedAt: &rewardedAt, RewardRevokedAt: &revokedAt})
	if revoked.RewardRevocable {
		t.Fatal("奖励已撤销的试卷不得标记为可撤销奖励")
	}
}

func createStoredExamPaper(t *testing.T, env examPaperTestEnv, submitter models.User, status models.ExamPaperStatus) models.ExamPaper {
	t.Helper()
	headerBody, contentType := buildExamPaperUploadBody(t, true, buildHandlerTestPDF())
	request := httptest.NewRequest(http.MethodPost, "/upload", bytes.NewReader(headerBody))
	request.Header.Set("Content-Type", contentType)
	if err := request.ParseMultipartForm(services.ExamPaperMaxFileSize + 1024); err != nil {
		t.Fatalf("解析上传请求失败: %v", err)
	}
	_, header, err := request.FormFile("file")
	if err != nil {
		t.Fatalf("读取测试上传文件失败: %v", err)
	}
	stored, err := env.files.StoreUpload(header)
	if err != nil {
		t.Fatalf("保存测试 PDF 失败: %v", err)
	}
	publishedAt := time.Now()
	paper := models.ExamPaper{
		Status: status, Source: models.ExamPaperSourceUser, SubmitterID: submitter.ID,
		CourseName: "高等数学", AcademicYear: "2025-2026",
		Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal,
		Title:   "高等数学 · 2025-2026 · 第一学期 · 期末",
		FileKey: stored.FileKey, FileSize: stored.Size, SHA256: stored.SHA256,
	}
	if status == models.ExamPaperStatusPublished {
		paper.PublishedAt = &publishedAt
	}
	if err := env.db.Create(&paper).Error; err != nil {
		t.Fatalf("创建测试试卷失败: %v", err)
	}
	return paper
}

func TestExamPaperListRequiresEduVerificationAndHidesPrivateFields(t *testing.T) {
	env := newExamPaperTestEnv(t)
	unverified := createExamPaperTestUser(t, env.db, "unverified", models.RoleUser, false, 0)
	verified := createExamPaperTestUser(t, env.db, "verified", models.RoleUser, true, 500)
	admin := createExamPaperTestUser(t, env.db, "admin", models.RoleAdmin, false, 0)
	createStoredExamPaper(t, env, verified, models.ExamPaperStatusPublished)

	blocked := performExamPaperRequest(env.handler.List, http.MethodGet, "/api/exam-papers", nil, unverified.ID, nil, "")
	if blocked.Code != http.StatusForbidden || decodeErrorCode(t, blocked) != "edu_verification_required" {
		t.Fatalf("未认证用户响应错误: status=%d body=%s", blocked.Code, blocked.Body.String())
	}

	allowed := performExamPaperRequest(env.handler.List, http.MethodGet, "/api/exam-papers", nil, admin.ID, nil, "")
	if allowed.Code != http.StatusOK {
		t.Fatalf("管理员应绕过教务认证: status=%d body=%s", allowed.Code, allowed.Body.String())
	}
	body := allowed.Body.String()
	for _, privateField := range []string{"student_id", "edu_student_id", "file_key", "sha256", "original"} {
		if strings.Contains(body, privateField) {
			t.Fatalf("公开响应泄露私有字段 %q: %s", privateField, body)
		}
	}
	if !strings.Contains(body, `"level":4`) {
		t.Fatalf("响应应包含投稿人实时全站等级: %s", body)
	}
}

// examPaperCountingReader 用于验证上传处理不会无上限读取请求体。
type examPaperCountingReader struct {
	reader *bytes.Reader
	read   int64
}

func (r *examPaperCountingReader) Read(buffer []byte) (int, error) {
	count, err := r.reader.Read(buffer)
	r.read += int64(count)
	return count, err
}

func TestExamPaperUploadStopsReadingOversizedRequestAtLimit(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "stream-limit-user", models.RoleUser, true, 0)

	// 请求体比文件上限多 2 MiB。预期处理器在额外 1 MiB 的 multipart 开销范围内停止读取。
	overflow := bytes.Repeat([]byte{'x'}, int(services.ExamPaperMaxFileSize+2*1024*1024))
	body, contentType := buildExamPaperUploadBody(t, true, overflow)
	reader := &examPaperCountingReader{reader: bytes.NewReader(body)}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/exam-papers", reader)
	context.Request.Header.Set("Content-Type", contentType)
	context.Set("user_id", user.ID)

	env.handler.Upload(context)

	if recorder.Code != http.StatusRequestEntityTooLarge || decodeErrorCode(t, recorder) != "file_too_large" {
		t.Fatalf("超限请求应返回 file_too_large，status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	const multipartOverheadAllowance = int64(1024 * 1024)
	if reader.read > services.ExamPaperMaxFileSize+multipartOverheadAllowance+1 {
		t.Fatalf("超限请求读取过多：read=%d，limit=%d", reader.read, services.ExamPaperMaxFileSize+multipartOverheadAllowance+1)
	}
}

func TestExamPaperUploadRequiresPrivacyAndCreatesPendingSubmission(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "uploader", models.RoleUser, true, 0)
	pdf := buildHandlerTestPDF()

	body, contentType := buildExamPaperUploadBody(t, false, pdf)
	blocked := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, user.ID, body, contentType)
	if blocked.Code != http.StatusBadRequest || decodeErrorCode(t, blocked) != "privacy_confirmation_required" {
		t.Fatalf("隐私确认校验错误: status=%d body=%s", blocked.Code, blocked.Body.String())
	}

	body, contentType = buildExamPaperUploadBody(t, true, pdf)
	created := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, user.ID, body, contentType)
	if created.Code != http.StatusCreated || !strings.Contains(created.Body.String(), `"status":"pending"`) {
		t.Fatalf("普通投稿创建失败: status=%d body=%s", created.Code, created.Body.String())
	}
	if strings.Contains(created.Body.String(), "file_key") || strings.Contains(created.Body.String(), "sha256") {
		t.Fatalf("上传响应泄露私有文件信息: %s", created.Body.String())
	}

	body, contentType = buildExamPaperUploadBody(t, true, pdf)
	duplicate := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, user.ID, body, contentType)
	if duplicate.Code != http.StatusConflict || decodeErrorCode(t, duplicate) != "duplicate_exam_paper" {
		t.Fatalf("重复投稿校验错误: status=%d body=%s", duplicate.Code, duplicate.Body.String())
	}

	var count int64
	if err := env.db.Model(&models.ExamPaper{}).Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("重复投稿后数据库记录数错误: count=%d err=%v", count, err)
	}
	entries, err := os.ReadDir(env.root)
	if err != nil {
		t.Fatalf("读取私有目录失败: %v", err)
	}
	fileCount := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			fileCount++
		}
	}
	if fileCount != 1 {
		t.Fatalf("重复投稿文件未清理: fileCount=%d", fileCount)
	}
}

func TestExamPaperUploadRejectsWhenPendingQuotaReachedBeforeReadingBody(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "quota-user", models.RoleUser, true, 0)
	for index := 0; index < 5; index++ {
		paper := models.ExamPaper{
			Status:       models.ExamPaperStatusPending,
			Source:       models.ExamPaperSourceUser,
			SubmitterID:  user.ID,
			CourseName:   fmt.Sprintf("quota-%d", index),
			AcademicYear: "2025-2026",
			Semester:     models.ExamPaperSemesterFirst,
			ExamType:     models.ExamPaperTypeFinal,
			Title:        fmt.Sprintf("quota-%d", index),
			FileKey:      fmt.Sprintf("quota-%d.pdf", index),
			FileSize:     1,
			SHA256:       fmt.Sprintf("quota-hash-%d", index),
		}
		if err := env.db.Create(&paper).Error; err != nil {
			t.Fatalf("创建待审核配额记录失败: %v", err)
		}
	}

	response := performExamPaperRequest(
		env.handler.Upload,
		http.MethodPost,
		"/api/exam-papers",
		nil,
		user.ID,
		[]byte("not a multipart body"),
		"application/octet-stream",
	)
	if response.Code != http.StatusTooManyRequests || decodeErrorCode(t, response) != "exam_paper_pending_limit_reached" {
		t.Fatalf("超过待审核配额应先返回 429，status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestExamPaperUploadRateLimitsBurstSubmissions(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "burst-user", models.RoleUser, true, 0)

	for index := 0; index < 3; index++ {
		body, contentType := buildExamPaperUploadBody(t, true, buildHandlerTestPDFWithComment(fmt.Sprintf("burst-%d", index)))
		response := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, user.ID, body, contentType)
		if response.Code != http.StatusCreated {
			t.Fatalf("第 %d 次突发上传应成功: status=%d body=%s", index+1, response.Code, response.Body.String())
		}
	}

	body, contentType := buildExamPaperUploadBody(t, true, buildHandlerTestPDFWithComment("burst-limited"))
	response := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, user.ID, body, contentType)
	if response.Code != http.StatusTooManyRequests || decodeErrorCode(t, response) != "exam_paper_upload_rate_limited" {
		t.Fatalf("短时间第 4 次上传应被限流: status=%d body=%s", response.Code, response.Body.String())
	}
}

type remoteExamPaperHandlerTestEnv struct {
	grantSigner   *services.ExamPaperStorageSigner
	receiptSigner *services.ExamPaperStorageSigner
	uploads       *services.ExamPaperUploadService
	remote        *services.ExamPaperRemoteClient
}

func configureRemoteExamPaperHandler(t *testing.T, env *examPaperTestEnv, mode string) remoteExamPaperHandlerTestEnv {
	t.Helper()
	now := func() time.Time { return examPaperUploadHandlerTestNow }
	grantSigner, err := services.NewExamPaperStorageSigner("handler-grant-secret", now)
	if err != nil {
		t.Fatalf("创建上传授权签名器失败: %v", err)
	}
	receiptSigner, err := services.NewExamPaperStorageSigner("handler-receipt-secret", now)
	if err != nil {
		t.Fatalf("创建上传回执签名器失败: %v", err)
	}
	uploads := services.NewExamPaperUploadService(env.db, grantSigner, receiptSigner, now, nil)
	remoteClient, err := services.NewExamPaperRemoteClient("https://sylulive.online", grantSigner, nil, now)
	if err != nil {
		t.Fatalf("创建远端文件客户端失败: %v", err)
	}
	storageJobs := services.NewExamPaperStorageJobService(env.db, remoteClient, now)
	env.handler = NewExamPaperHandlerWithStorage(env.db, env.files, mode, "https://sylulive.online/", uploads, remoteClient, storageJobs)
	return remoteExamPaperHandlerTestEnv{grantSigner: grantSigner, receiptSigner: receiptSigner, uploads: uploads, remote: remoteClient}
}

var examPaperUploadHandlerTestNow = time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)

func validRemoteExamPaperUploadSessionPayload() map[string]any {
	return map[string]any{
		"course_name": "高等数学", "academic_year": "2025-2026", "semester": "first", "exam_type": "final",
		"privacy_confirmed": true, "file_size": 1024,
	}
}

func TestCreateRemoteExamPaperUploadSessionReturnsDirectUploadURL(t *testing.T) {
	env := newExamPaperTestEnv(t)
	remote := configureRemoteExamPaperHandler(t, &env, "remote")
	user := createExamPaperTestUser(t, env.db, "remote-uploader", models.RoleUser, true, 0)

	response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, validRemoteExamPaperUploadSessionPayload())
	if response.Code != http.StatusCreated {
		t.Fatalf("创建远端上传会话失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		SessionID   string    `json:"session_id"`
		UploadURL   string    `json:"upload_url"`
		UploadToken string    `json:"upload_token"`
		ExpiresAt   time.Time `json:"expires_at"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析上传会话响应失败: %v", err)
	}
	if payload.SessionID == "" || payload.UploadURL != "https://sylulive.online/v1/uploads/"+payload.SessionID {
		t.Fatalf("直传地址错误: %+v", payload)
	}
	if !payload.ExpiresAt.Equal(examPaperUploadHandlerTestNow.Add(services.ExamPaperUploadSessionTTL)) {
		t.Fatalf("会话过期时间错误: %s", payload.ExpiresAt)
	}
	grant, err := remote.grantSigner.VerifyGrant(payload.UploadToken, services.ExamPaperStoragePurposeUpload, http.MethodPost, "/v1/uploads/"+payload.SessionID)
	if err != nil || grant.UserID != user.ID {
		t.Fatalf("上传授权范围错误: grant=%+v err=%v", grant, err)
	}
	if strings.Contains(response.Body.String(), "storage_key") || strings.Contains(response.Body.String(), "sha256") {
		t.Fatalf("上传会话响应泄露私有文件信息: %s", response.Body.String())
	}
}

func TestRemoteExamPaperUploadSessionJSONBodyLimitsAndMalformedPayloads(t *testing.T) {
	validCreateBody, err := json.Marshal(validRemoteExamPaperUploadSessionPayload())
	if err != nil {
		t.Fatalf("编码合法创建会话请求失败: %v", err)
	}
	validCompleteBody := []byte(`{"receipt":"placeholder"}`)
	withSuffix := func(body, suffix []byte) []byte {
		result := append([]byte(nil), body...)
		return append(result, suffix...)
	}
	overLimitWhitespace := bytes.Repeat([]byte{' '}, int(maxExamPaperJSONBodyBytes)+1)
	tests := []struct {
		name       string
		handler    func(*ExamPaperHandler) gin.HandlerFunc
		path       string
		params     gin.Params
		body       []byte
		wantStatus int
		wantCode   string
	}{
		{name: "创建会话请求体超限", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CreateUploadSession }, path: "/api/exam-papers/upload-sessions", body: []byte(`{"course_name":"` + strings.Repeat("x", 70*1024) + `"}`), wantStatus: http.StatusRequestEntityTooLarge, wantCode: "request_body_too_large"},
		{name: "创建会话合法JSON后超限空白", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CreateUploadSession }, path: "/api/exam-papers/upload-sessions", body: withSuffix(validCreateBody, overLimitWhitespace), wantStatus: http.StatusRequestEntityTooLarge, wantCode: "request_body_too_large"},
		{name: "创建会话合法JSON后尾随垃圾", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CreateUploadSession }, path: "/api/exam-papers/upload-sessions", body: withSuffix(validCreateBody, []byte("garbage")), wantStatus: http.StatusBadRequest, wantCode: "invalid_upload_session_request"},
		{name: "创建会话包含第二个JSON值", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CreateUploadSession }, path: "/api/exam-papers/upload-sessions", body: withSuffix(validCreateBody, []byte(` {}`)), wantStatus: http.StatusBadRequest, wantCode: "invalid_upload_session_request"},
		{name: "创建会话JSON畸形", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CreateUploadSession }, path: "/api/exam-papers/upload-sessions", body: []byte(`{"course_name":`), wantStatus: http.StatusBadRequest, wantCode: "invalid_upload_session_request"},
		{name: "完成会话请求体超限", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CompleteUploadSession }, path: "/api/exam-papers/upload-sessions/session-1/complete", params: gin.Params{{Key: "id", Value: "session-1"}}, body: []byte(`{"receipt":"` + strings.Repeat("x", 70*1024) + `"}`), wantStatus: http.StatusRequestEntityTooLarge, wantCode: "request_body_too_large"},
		{name: "完成会话合法JSON后超限空白", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CompleteUploadSession }, path: "/api/exam-papers/upload-sessions/session-1/complete", params: gin.Params{{Key: "id", Value: "session-1"}}, body: withSuffix(validCompleteBody, overLimitWhitespace), wantStatus: http.StatusRequestEntityTooLarge, wantCode: "request_body_too_large"},
		{name: "完成会话合法JSON后尾随垃圾", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CompleteUploadSession }, path: "/api/exam-papers/upload-sessions/session-1/complete", params: gin.Params{{Key: "id", Value: "session-1"}}, body: withSuffix(validCompleteBody, []byte("garbage")), wantStatus: http.StatusBadRequest, wantCode: "upload_receipt_invalid"},
		{name: "完成会话包含第二个JSON值", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CompleteUploadSession }, path: "/api/exam-papers/upload-sessions/session-1/complete", params: gin.Params{{Key: "id", Value: "session-1"}}, body: withSuffix(validCompleteBody, []byte(` {}`)), wantStatus: http.StatusBadRequest, wantCode: "upload_receipt_invalid"},
		{name: "完成会话JSON畸形", handler: func(handler *ExamPaperHandler) gin.HandlerFunc { return handler.CompleteUploadSession }, path: "/api/exam-papers/upload-sessions/session-1/complete", params: gin.Params{{Key: "id", Value: "session-1"}}, body: []byte(`{"receipt":`), wantStatus: http.StatusBadRequest, wantCode: "upload_receipt_invalid"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			env := newExamPaperTestEnv(t)
			configureRemoteExamPaperHandler(t, &env, "remote")
			user := createExamPaperTestUser(t, env.db, "json-limit-"+test.name, models.RoleUser, true, 0)
			response := performExamPaperRequest(test.handler(env.handler), http.MethodPost, test.path, test.params, user.ID, test.body, "application/json")
			if response.Code != test.wantStatus || decodeErrorCode(t, response) != test.wantCode {
				t.Fatalf("JSON 请求错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestCreateRemoteExamPaperUploadSessionValidatesBusinessBoundaries(t *testing.T) {
	t.Run("未确认隐私", func(t *testing.T) {
		env := newExamPaperTestEnv(t)
		configureRemoteExamPaperHandler(t, &env, "remote")
		user := createExamPaperTestUser(t, env.db, "remote-no-privacy", models.RoleUser, true, 0)
		payload := validRemoteExamPaperUploadSessionPayload()
		payload["privacy_confirmed"] = false
		response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, payload)
		if response.Code != http.StatusBadRequest || decodeErrorCode(t, response) != "privacy_confirmation_required" {
			t.Fatalf("隐私确认错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
		}
	})

	t.Run("元数据非法", func(t *testing.T) {
		env := newExamPaperTestEnv(t)
		configureRemoteExamPaperHandler(t, &env, "remote")
		user := createExamPaperTestUser(t, env.db, "remote-bad-metadata", models.RoleUser, true, 0)
		payload := validRemoteExamPaperUploadSessionPayload()
		payload["semester"] = "invalid"
		response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, payload)
		if response.Code != http.StatusBadRequest || decodeErrorCode(t, response) != "invalid_exam_paper_metadata" {
			t.Fatalf("元数据错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
		}
	})

	t.Run("普通用户未教务认证", func(t *testing.T) {
		env := newExamPaperTestEnv(t)
		configureRemoteExamPaperHandler(t, &env, "remote")
		user := createExamPaperTestUser(t, env.db, "remote-unverified", models.RoleUser, false, 0)
		response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, validRemoteExamPaperUploadSessionPayload())
		if response.Code != http.StatusForbidden || decodeErrorCode(t, response) != "edu_verification_required" {
			t.Fatalf("教务认证错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
		}
	})

	t.Run("待审核配额已满", func(t *testing.T) {
		env := newExamPaperTestEnv(t)
		configureRemoteExamPaperHandler(t, &env, "remote")
		user := createExamPaperTestUser(t, env.db, "remote-pending-limit", models.RoleUser, true, 0)
		for index := 0; index < services.ExamPaperMaxPendingSubmissionsPerUser; index++ {
			paper := models.ExamPaper{Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: user.ID, CourseName: fmt.Sprintf("配额-%d", index), AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: fmt.Sprintf("配额-%d", index), FileKey: fmt.Sprintf("remote-quota-%d.pdf", index), FileSize: 1, SHA256: fmt.Sprintf("remote-quota-sha-%d", index)}
			if err := env.db.Create(&paper).Error; err != nil {
				t.Fatalf("创建配额测试试卷失败: %v", err)
			}
		}
		response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, validRemoteExamPaperUploadSessionPayload())
		if response.Code != http.StatusTooManyRequests || decodeErrorCode(t, response) != "exam_paper_pending_limit_reached" {
			t.Fatalf("待审核配额错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
		}
	})

	t.Run("短时创建会话限流", func(t *testing.T) {
		env := newExamPaperTestEnv(t)
		configureRemoteExamPaperHandler(t, &env, "remote")
		user := createExamPaperTestUser(t, env.db, "remote-rate-limit", models.RoleUser, true, 0)
		for index := 0; index < maxExamPaperUploadsPerWindow; index++ {
			response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, validRemoteExamPaperUploadSessionPayload())
			if response.Code != http.StatusCreated {
				t.Fatalf("第 %d 次创建上传会话失败: status=%d body=%s", index+1, response.Code, response.Body.String())
			}
		}
		response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, validRemoteExamPaperUploadSessionPayload())
		if response.Code != http.StatusTooManyRequests || decodeErrorCode(t, response) != "exam_paper_upload_rate_limited" {
			t.Fatalf("创建会话限流错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
		}
	})
}

func TestCompleteRemoteExamPaperUploadSessionMapsPendingQuotaToTooManyRequests(t *testing.T) {
	env := newExamPaperTestEnv(t)
	remote := configureRemoteExamPaperHandler(t, &env, "remote")
	user := createExamPaperTestUser(t, env.db, "remote-complete-quota", models.RoleUser, true, 0)
	metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
	session, _, err := remote.uploads.CreateSession(user, metadata, 1024)
	if err != nil {
		t.Fatalf("创建测试会话失败: %v", err)
	}
	for index := 0; index < services.ExamPaperMaxPendingSubmissionsPerUser; index++ {
		paper := models.ExamPaper{Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: user.ID, CourseName: fmt.Sprintf("完成配额-%d", index), AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: fmt.Sprintf("完成配额-%d", index), FileKey: fmt.Sprintf("complete-quota-%d.pdf", index), FileSize: 1, SHA256: fmt.Sprintf("complete-quota-sha-%d", index)}
		if err := env.db.Create(&paper).Error; err != nil {
			t.Fatalf("创建配额试卷失败: %v", err)
		}
	}
	receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "17171717-1717-4717-8717-171717171717.pdf", FileSize: 1024, SHA256: "5234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadHandlerTestNow.Unix()})
	if err != nil {
		t.Fatalf("签发测试回执失败: %v", err)
	}

	response := performExamPaperJSONRequest(env.handler.CompleteUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions/"+session.ID+"/complete", gin.Params{{Key: "id", Value: session.ID}}, user.ID, map[string]any{"receipt": receipt})
	if response.Code != http.StatusTooManyRequests || decodeErrorCode(t, response) != "exam_paper_pending_limit_reached" {
		t.Fatalf("完成配额错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCompleteRemoteExamPaperUploadSessionCreatesSubmission(t *testing.T) {
	env := newExamPaperTestEnv(t)
	remote := configureRemoteExamPaperHandler(t, &env, "remote")
	user := createExamPaperTestUser(t, env.db, "remote-completer", models.RoleUser, true, 0)
	metadata, err := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
	if err != nil {
		t.Fatalf("创建测试元数据失败: %v", err)
	}
	session, _, err := remote.uploads.CreateSession(user, metadata, 1024)
	if err != nil {
		t.Fatalf("创建测试上传会话失败: %v", err)
	}
	receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{
		SessionID: session.ID, FileKey: "11111111-1111-4111-8111-111111111111.pdf", FileSize: 1024,
		SHA256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadHandlerTestNow.Unix(),
	})
	if err != nil {
		t.Fatalf("签发测试回执失败: %v", err)
	}

	response := performExamPaperJSONRequest(
		env.handler.CompleteUploadSession,
		http.MethodPost,
		"/api/exam-papers/upload-sessions/"+session.ID+"/complete",
		gin.Params{{Key: "id", Value: session.ID}},
		user.ID,
		map[string]any{"receipt": receipt},
	)
	if response.Code != http.StatusCreated || !strings.Contains(response.Body.String(), `"status":"pending"`) {
		t.Fatalf("完成远端上传会话失败: status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "file_key") || strings.Contains(response.Body.String(), "sha256") {
		t.Fatalf("完成响应泄露私有文件信息: %s", response.Body.String())
	}
	var paper models.ExamPaper
	if err := env.db.First(&paper).Error; err != nil {
		t.Fatalf("读取远端试卷失败: %v", err)
	}
	if paper.StorageBackend != models.ExamPaperStorageRemote {
		t.Fatalf("试卷存储后端错误: %s", paper.StorageBackend)
	}
}

func TestCompleteRemoteExamPaperUploadSessionMapsBoundaryErrors(t *testing.T) {
	tests := []struct {
		name       string
		prepare    func(t *testing.T, env *examPaperTestEnv, remote remoteExamPaperHandlerTestEnv, owner, caller models.User) (*models.ExamPaperUploadSession, string)
		wantStatus int
		wantCode   string
	}{
		{
			name: "伪造回执", wantStatus: http.StatusBadRequest, wantCode: "upload_receipt_invalid",
			prepare: func(t *testing.T, _ *examPaperTestEnv, remote remoteExamPaperHandlerTestEnv, _ models.User, caller models.User) (*models.ExamPaperUploadSession, string) {
				metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
				session, _, err := remote.uploads.CreateSession(caller, metadata, 1024)
				if err != nil {
					t.Fatalf("创建测试会话失败: %v", err)
				}
				return session, "forged-receipt"
			},
		},
		{
			name: "他人会话", wantStatus: http.StatusNotFound, wantCode: "upload_session_not_found",
			prepare: func(t *testing.T, _ *examPaperTestEnv, remote remoteExamPaperHandlerTestEnv, owner, _ models.User) (*models.ExamPaperUploadSession, string) {
				metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
				session, _, err := remote.uploads.CreateSession(owner, metadata, 1024)
				if err != nil {
					t.Fatalf("创建测试会话失败: %v", err)
				}
				receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "22222222-2222-4222-8222-222222222222.pdf", FileSize: 1024, SHA256: "2234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadHandlerTestNow.Unix()})
				if err != nil {
					t.Fatalf("签发测试回执失败: %v", err)
				}
				return session, receipt
			},
		},
		{
			name: "过期会话", wantStatus: http.StatusGone, wantCode: "upload_session_expired",
			prepare: func(t *testing.T, env *examPaperTestEnv, remote remoteExamPaperHandlerTestEnv, _ models.User, caller models.User) (*models.ExamPaperUploadSession, string) {
				metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
				session, _, err := remote.uploads.CreateSession(caller, metadata, 1024)
				if err != nil {
					t.Fatalf("创建测试会话失败: %v", err)
				}
				if err := env.db.Model(session).Update("expires_at", examPaperUploadHandlerTestNow.Add(-time.Second)).Error; err != nil {
					t.Fatalf("设置过期会话失败: %v", err)
				}
				receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "33333333-3333-4333-8333-333333333333.pdf", FileSize: 1024, SHA256: "3234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadHandlerTestNow.Unix()})
				if err != nil {
					t.Fatalf("签发测试回执失败: %v", err)
				}
				return session, receipt
			},
		},
		{
			name: "重复文件", wantStatus: http.StatusConflict, wantCode: "duplicate_exam_paper",
			prepare: func(t *testing.T, env *examPaperTestEnv, remote remoteExamPaperHandlerTestEnv, _ models.User, caller models.User) (*models.ExamPaperUploadSession, string) {
				const duplicateSHA = "4234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
				if err := env.db.Create(&models.ExamPaper{Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: caller.ID, CourseName: "已有试卷", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal, Title: "已有试卷", FileKey: "existing.pdf", FileSize: 1024, SHA256: duplicateSHA}).Error; err != nil {
					t.Fatalf("创建重复试卷失败: %v", err)
				}
				metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
				session, _, err := remote.uploads.CreateSession(caller, metadata, 1024)
				if err != nil {
					t.Fatalf("创建测试会话失败: %v", err)
				}
				receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "44444444-4444-4444-8444-444444444444.pdf", FileSize: 1024, SHA256: duplicateSHA, IssuedAt: examPaperUploadHandlerTestNow.Unix()})
				if err != nil {
					t.Fatalf("签发测试回执失败: %v", err)
				}
				return session, receipt
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			env := newExamPaperTestEnv(t)
			remote := configureRemoteExamPaperHandler(t, &env, "remote")
			owner := createExamPaperTestUser(t, env.db, "remote-owner-"+test.name, models.RoleUser, true, 0)
			caller := createExamPaperTestUser(t, env.db, "remote-caller-"+test.name, models.RoleUser, true, 0)
			session, receipt := test.prepare(t, &env, remote, owner, caller)
			response := performExamPaperJSONRequest(env.handler.CompleteUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions/"+session.ID+"/complete", gin.Params{{Key: "id", Value: session.ID}}, caller.ID, map[string]any{"receipt": receipt})
			if response.Code != test.wantStatus || decodeErrorCode(t, response) != test.wantCode {
				t.Fatalf("错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestCompleteRemoteExamPaperUploadSessionMapsDatabaseFailureToInternalError(t *testing.T) {
	env := newExamPaperTestEnv(t)
	remote := configureRemoteExamPaperHandler(t, &env, "remote")
	user := createExamPaperTestUser(t, env.db, "remote-db-failure", models.RoleUser, true, 0)
	metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
	session, _, err := remote.uploads.CreateSession(user, metadata, 1024)
	if err != nil {
		t.Fatalf("创建测试会话失败: %v", err)
	}
	receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.pdf", FileSize: 1024, SHA256: "e234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadHandlerTestNow.Unix()})
	if err != nil {
		t.Fatalf("签发测试回执失败: %v", err)
	}
	if err := env.db.Migrator().DropTable(&models.ExamPaper{}); err != nil {
		t.Fatalf("注入数据库失败场景失败: %v", err)
	}

	response := performExamPaperJSONRequest(env.handler.CompleteUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions/"+session.ID+"/complete", gin.Params{{Key: "id", Value: session.ID}}, user.ID, map[string]any{"receipt": receipt})
	if response.Code != http.StatusInternalServerError || decodeErrorCode(t, response) != "internal_error" {
		t.Fatalf("内部错误映射不符合预期: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestRemoteExamPaperUploadRequiresNewClientWithoutReadingMultipartBody(t *testing.T) {
	env := newExamPaperTestEnv(t)
	configureRemoteExamPaperHandler(t, &env, "remote")
	user := createExamPaperTestUser(t, env.db, "legacy-remote-uploader", models.RoleUser, true, 0)
	reader := &examPaperCountingReader{reader: bytes.NewReader(bytes.Repeat([]byte{'x'}, 1024))}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/exam-papers", reader)
	context.Request.Header.Set("Content-Type", "multipart/form-data")
	context.Set("user_id", user.ID)

	env.handler.Upload(context)

	if recorder.Code != http.StatusUpgradeRequired || decodeErrorCode(t, recorder) != "client_upgrade_required" {
		t.Fatalf("旧客户端上传应要求升级: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if reader.read != 0 {
		t.Fatalf("主服务器不应读取旧客户端 PDF 请求体: read=%d", reader.read)
	}
}

func TestReadonlyRemoteExamPaperStorageRejectsNewUploads(t *testing.T) {
	env := newExamPaperTestEnv(t)
	remote := configureRemoteExamPaperHandler(t, &env, "remote")
	user := createExamPaperTestUser(t, env.db, "readonly-uploader", models.RoleUser, true, 0)
	metadata, _ := models.NormalizeExamPaperMetadata("高等数学", "2025-2026", models.ExamPaperSemesterFirst, models.ExamPaperTypeFinal)
	session, _, err := remote.uploads.CreateSession(user, metadata, 1024)
	if err != nil {
		t.Fatalf("创建切换前上传会话失败: %v", err)
	}
	receipt, err := remote.receiptSigner.SignReceipt(services.ExamPaperUploadReceipt{SessionID: session.ID, FileKey: "ffffffff-ffff-4fff-8fff-ffffffffffff.pdf", FileSize: 1024, SHA256: "f234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", IssuedAt: examPaperUploadHandlerTestNow.Unix()})
	if err != nil {
		t.Fatalf("签发切换前回执失败: %v", err)
	}
	env.handler = NewExamPaperHandlerWithStorage(env.db, env.files, "readonly-remote", "https://sylulive.online", remote.uploads)

	response := performExamPaperJSONRequest(env.handler.CreateUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions", nil, user.ID, validRemoteExamPaperUploadSessionPayload())
	if response.Code != http.StatusServiceUnavailable || decodeErrorCode(t, response) != "storage_unavailable" {
		t.Fatalf("只读远端模式应拒绝新上传: status=%d body=%s", response.Code, response.Body.String())
	}
	legacy := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, user.ID, []byte("not-read"), "multipart/form-data")
	if legacy.Code != http.StatusServiceUnavailable || decodeErrorCode(t, legacy) != "storage_unavailable" {
		t.Fatalf("只读远端模式应拒绝旧 multipart 上传: status=%d body=%s", legacy.Code, legacy.Body.String())
	}
	completed := performExamPaperJSONRequest(env.handler.CompleteUploadSession, http.MethodPost, "/api/exam-papers/upload-sessions/"+session.ID+"/complete", gin.Params{{Key: "id", Value: session.ID}}, user.ID, map[string]any{"receipt": receipt})
	if completed.Code != http.StatusCreated {
		t.Fatalf("只读远端模式应允许完成既有会话: status=%d body=%s", completed.Code, completed.Body.String())
	}
}

func TestExamPaperPreviewDoesNotCountAndDownloadCountsOnce(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "reader", models.RoleUser, true, 0)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusPublished)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	preview := performExamPaperRequest(env.handler.Preview, http.MethodGet, "/api/exam-papers/1/preview", params, user.ID, nil, "")
	if preview.Code != http.StatusOK || !strings.HasPrefix(preview.Header().Get("Content-Disposition"), "inline") {
		t.Fatalf("预览响应错误: status=%d disposition=%q body=%s", preview.Code, preview.Header().Get("Content-Disposition"), preview.Body.String())
	}
	var afterPreview models.ExamPaper
	env.db.First(&afterPreview, paper.ID)
	if afterPreview.DownloadCount != 0 {
		t.Fatalf("预览不应增加下载量: %d", afterPreview.DownloadCount)
	}

	download := performExamPaperRequest(env.handler.Download, http.MethodGet, "/api/exam-papers/1/download", params, user.ID, nil, "")
	if download.Code != http.StatusOK || !strings.HasPrefix(download.Header().Get("Content-Disposition"), "attachment") {
		t.Fatalf("下载响应错误: status=%d disposition=%q", download.Code, download.Header().Get("Content-Disposition"))
	}
	var afterDownload models.ExamPaper
	env.db.First(&afterDownload, paper.ID)
	if afterDownload.DownloadCount != 1 {
		t.Fatalf("明确下载应原子增加一次下载量: %d", afterDownload.DownloadCount)
	}
}

func createRemoteExamPaper(t *testing.T, env examPaperTestEnv, submitter models.User, status models.ExamPaperStatus, fileKey string) models.ExamPaper {
	t.Helper()
	paper := models.ExamPaper{
		Status: status, Source: models.ExamPaperSourceUser, SubmitterID: submitter.ID,
		StorageBackend: models.ExamPaperStorageRemote, CourseName: "高等数学", AcademicYear: "2025-2026",
		Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal,
		Title: "高等数学远端试卷", FileKey: fileKey, FileSize: 12, SHA256: strings.Repeat("a", 64),
	}
	if err := env.db.Create(&paper).Error; err != nil {
		t.Fatalf("创建远端试卷失败: %v", err)
	}
	return paper
}

func TestRemoteExamPaperPreviewAndDownloadRedirectWithScopedPurpose(t *testing.T) {
	env := newExamPaperTestEnv(t)
	remote := configureRemoteExamPaperHandler(t, &env, examPaperStorageModeRemote)
	user := createExamPaperTestUser(t, env.db, "remote-reader", models.RoleUser, true, 0)
	paper := createRemoteExamPaper(t, env, user, models.ExamPaperStatusPublished, "remote paper.pdf")
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	preview := performExamPaperRequest(env.handler.Preview, http.MethodGet, "/api/exam-papers/1/preview", params, user.ID, nil, "")
	if preview.Code != http.StatusFound {
		t.Fatalf("远端预览应重定向: status=%d body=%s", preview.Code, preview.Body.String())
	}
	verifyRemoteExamPaperLocation(t, remote.grantSigner, preview.Header().Get("Location"), paper, services.ExamPaperStoragePurposePreview)

	download := performExamPaperRequest(env.handler.Download, http.MethodGet, "/api/exam-papers/1/download", params, user.ID, nil, "")
	if download.Code != http.StatusFound {
		t.Fatalf("远端下载应重定向: status=%d body=%s", download.Code, download.Body.String())
	}
	verifyRemoteExamPaperLocation(t, remote.grantSigner, download.Header().Get("Location"), paper, services.ExamPaperStoragePurposeDownload)
	var refreshed models.ExamPaper
	require.NoError(t, env.db.First(&refreshed, paper.ID).Error)
	require.Equal(t, int64(1), refreshed.DownloadCount)
}

func verifyRemoteExamPaperLocation(t *testing.T, signer *services.ExamPaperStorageSigner, location string, paper models.ExamPaper, purpose string) {
	t.Helper()
	parsed, err := url.Parse(location)
	require.NoError(t, err)
	require.Equal(t, "sylulive.online", parsed.Host)
	grant, err := signer.VerifyGrant(parsed.Query().Get("token"), purpose, http.MethodGet, parsed.EscapedPath())
	require.NoError(t, err)
	require.Equal(t, paper.ID, grant.PaperID)
	require.Equal(t, paper.FileKey, grant.FileKey)
}

type failingExamPaperFileURLSigner struct{}

func (failingExamPaperFileURLSigner) SignedFileURL(models.ExamPaper, string, time.Duration) (string, error) {
	return "", errors.New("签名失败")
}

func TestRemoteExamPaperDownloadSigningFailureDoesNotCount(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "remote-sign-fail", models.RoleUser, true, 0)
	paper := createRemoteExamPaper(t, env, user, models.ExamPaperStatusPublished, "sign-fail.pdf")
	env.handler.remoteFiles = failingExamPaperFileURLSigner{}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Download, http.MethodGet, "/api/exam-papers/1/download", params, user.ID, nil, "")
	require.Equal(t, http.StatusInternalServerError, response.Code)
	var refreshed models.ExamPaper
	require.NoError(t, env.db.First(&refreshed, paper.ID).Error)
	require.Zero(t, refreshed.DownloadCount)
}

func TestExamPaperWithdrawDeletesPendingRecordAndFile(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "withdrawer", models.RoleUser, true, 30)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusPending)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("撤回投稿失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Message    string `json:"message"`
		ExpRevoked bool   `json:"exp_revoked"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析撤回响应失败: %v", err)
	}
	if payload.Message != "投稿已撤回" || payload.ExpRevoked {
		t.Fatalf("待审核投稿撤回应返回未撤销经验: %s", response.Body.String())
	}
	var count int64
	env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&count)
	if count != 0 {
		t.Fatalf("撤回后记录仍存在: %d", count)
	}
	var refreshed models.User
	if err := env.db.First(&refreshed, user.ID).Error; err != nil || refreshed.Exp != 30 {
		t.Fatalf("待审核投稿撤回不应扣除经验: exp=%d err=%v", refreshed.Exp, err)
	}
	if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); !os.IsNotExist(err) {
		t.Fatalf("撤回后私有文件仍存在: %v", err)
	}
}

func TestRemoteExamPaperWithdrawEnqueuesTrashInTransaction(t *testing.T) {
	env := newExamPaperTestEnv(t)
	configureRemoteExamPaperHandler(t, &env, examPaperStorageModeRemote)
	user := createExamPaperTestUser(t, env.db, "remote-withdraw", models.RoleUser, true, 0)
	paper := createRemoteExamPaper(t, env, user, models.ExamPaperStatusPending, "withdraw.pdf")
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	require.Equal(t, http.StatusOK, response.Code)
	var job models.ExamPaperStorageJob
	require.NoError(t, env.db.Where("file_key = ? AND operation = ?", paper.FileKey, services.ExamPaperStoragePurposeDelete).First(&job).Error)
	require.Nil(t, job.CompletedAt)
}

func TestRemoteExamPaperWithdrawRollsBackWhenTrashEnqueueFails(t *testing.T) {
	env := newExamPaperTestEnv(t)
	configureRemoteExamPaperHandler(t, &env, examPaperStorageModeRemote)
	user := createExamPaperTestUser(t, env.db, "remote-withdraw-rollback", models.RoleUser, true, 0)
	paper := createRemoteExamPaper(t, env, user, models.ExamPaperStatusPending, "withdraw-rollback.pdf")
	require.NoError(t, env.db.Migrator().DropTable(&models.ExamPaperStorageJob{}))
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	require.Equal(t, http.StatusInternalServerError, response.Code)
	var retained models.ExamPaper
	require.NoError(t, env.db.First(&retained, paper.ID).Error)
}

func TestExamPaperWithdrawPermanentlyDeletesRewardedSubmission(t *testing.T) {
	statuses := []models.ExamPaperStatus{
		models.ExamPaperStatusPublished,
		models.ExamPaperStatusUnpublished,
	}
	for _, status := range statuses {
		t.Run(string(status), func(t *testing.T) {
			env := newExamPaperTestEnv(t)
			user := createExamPaperTestUser(t, env.db, "delete-"+string(status), models.RoleUser, true, 30)
			paper := createStoredExamPaper(t, env, user, status)
			rewardedAt := time.Now().Add(-time.Hour)
			if err := env.db.Model(&paper).Update("rewarded_at", rewardedAt).Error; err != nil {
				t.Fatalf("设置奖励时间失败: %v", err)
			}
			params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

			response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
			if response.Code != http.StatusOK {
				t.Fatalf("永久删除投稿失败: status=%d body=%s", response.Code, response.Body.String())
			}
			var payload struct {
				Message    string `json:"message"`
				ExpRevoked bool   `json:"exp_revoked"`
			}
			if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
				t.Fatalf("解析永久删除响应失败: %v", err)
			}
			if payload.Message != "投稿已永久删除" || !payload.ExpRevoked {
				t.Fatalf("永久删除响应错误: %s", response.Body.String())
			}

			var count int64
			if err := env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&count).Error; err != nil || count != 0 {
				t.Fatalf("永久删除后投稿记录仍存在: count=%d err=%v", count, err)
			}
			var refreshed models.User
			if err := env.db.First(&refreshed, user.ID).Error; err != nil || refreshed.Exp != 20 {
				t.Fatalf("永久删除后经验撤销错误: exp=%d err=%v", refreshed.Exp, err)
			}
			if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); !os.IsNotExist(err) {
				t.Fatalf("永久删除后文件仍存在: %v", err)
			}

			repeated := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
			if repeated.Code != http.StatusNotFound || decodeErrorCode(t, repeated) != "exam_paper_not_found" {
				t.Fatalf("重复删除应返回 404: status=%d body=%s", repeated.Code, repeated.Body.String())
			}
			if err := env.db.First(&refreshed, user.ID).Error; err != nil || refreshed.Exp != 20 {
				t.Fatalf("重复删除不应重复扣除经验: exp=%d err=%v", refreshed.Exp, err)
			}
		})
	}
}

func TestExamPaperWithdrawRejectsNonOwnerWithoutChangingData(t *testing.T) {
	env := newExamPaperTestEnv(t)
	owner := createExamPaperTestUser(t, env.db, "delete-owner", models.RoleUser, true, 30)
	other := createExamPaperTestUser(t, env.db, "delete-other", models.RoleUser, true, 50)
	paper := createStoredExamPaper(t, env, owner, models.ExamPaperStatusPublished)
	rewardedAt := time.Now().Add(-time.Hour)
	if err := env.db.Model(&paper).Update("rewarded_at", rewardedAt).Error; err != nil {
		t.Fatalf("设置奖励时间失败: %v", err)
	}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, other.ID, nil, "")
	if response.Code != http.StatusNotFound || decodeErrorCode(t, response) != "exam_paper_not_found" {
		t.Fatalf("非投稿人删除应返回 404: status=%d body=%s", response.Code, response.Body.String())
	}
	var stored models.ExamPaper
	if err := env.db.First(&stored, paper.ID).Error; err != nil || stored.RewardRevokedAt != nil {
		t.Fatalf("非投稿人删除不应修改投稿: paper=%#v err=%v", stored, err)
	}
	var refreshedOwner models.User
	if err := env.db.First(&refreshedOwner, owner.ID).Error; err != nil || refreshedOwner.Exp != 30 {
		t.Fatalf("非投稿人删除不应扣除投稿人经验: exp=%d err=%v", refreshedOwner.Exp, err)
	}
	if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); err != nil {
		t.Fatalf("非投稿人删除不应删除文件: %v", err)
	}
}

func TestExamPaperWithdrawDeletesAlreadyRevokedUnpublishedWithoutDeductingExp(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "delete-revoked", models.RoleUser, true, 20)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusUnpublished)
	rewardedAt := time.Now().Add(-2 * time.Hour)
	revokedAt := time.Now().Add(-time.Hour)
	if err := env.db.Model(&paper).Updates(map[string]any{
		"rewarded_at": rewardedAt, "reward_revoked_at": revokedAt,
	}).Error; err != nil {
		t.Fatalf("设置已撤销奖励状态失败: %v", err)
	}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"exp_revoked":false`) {
		t.Fatalf("删除已撤销投稿失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var refreshed models.User
	if err := env.db.First(&refreshed, user.ID).Error; err != nil || refreshed.Exp != 20 {
		t.Fatalf("已撤销投稿删除不应再次扣经验: exp=%d err=%v", refreshed.Exp, err)
	}
}

func TestExamPaperWithdrawDeletesUnrewardedAdminSubmissionWithoutDeductingExp(t *testing.T) {
	env := newExamPaperTestEnv(t)
	admin := createExamPaperTestUser(t, env.db, "delete-admin", models.RoleAdmin, false, 120)
	paper := createStoredExamPaper(t, env, admin, models.ExamPaperStatusPublished)
	if err := env.db.Model(&paper).Update("source", models.ExamPaperSourceAdmin).Error; err != nil {
		t.Fatalf("设置管理员来源失败: %v", err)
	}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, admin.ID, nil, "")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"exp_revoked":false`) {
		t.Fatalf("删除未奖励的管理员投稿失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var refreshed models.User
	if err := env.db.First(&refreshed, admin.ID).Error; err != nil || refreshed.Exp != 120 {
		t.Fatalf("未奖励管理员投稿删除不应扣经验: exp=%d err=%v", refreshed.Exp, err)
	}
}

func TestExamPaperWithdrawRollsBackWhenRecordDeleteFails(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "delete-rollback", models.RoleUser, true, 30)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusPublished)
	rewardedAt := time.Now().Add(-time.Hour)
	if err := env.db.Model(&paper).Update("rewarded_at", rewardedAt).Error; err != nil {
		t.Fatalf("设置奖励时间失败: %v", err)
	}

	const callbackName = "test:fail_exam_paper_delete"
	if err := env.db.Callback().Delete().Before("gorm:delete").Register(callbackName, func(tx *gorm.DB) {
		if _, ok := tx.Statement.Model.(*models.ExamPaper); ok {
			tx.AddError(errors.New("注入试卷删除失败"))
		}
	}); err != nil {
		t.Fatalf("注册删除失败回调失败: %v", err)
	}
	t.Cleanup(func() {
		if err := env.db.Callback().Delete().Remove(callbackName); err != nil {
			t.Errorf("移除删除失败回调失败: %v", err)
		}
	})
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("事务删除失败应返回 500: status=%d body=%s", response.Code, response.Body.String())
	}
	var stored models.ExamPaper
	if err := env.db.First(&stored, paper.ID).Error; err != nil {
		t.Fatalf("事务失败后投稿记录应保留: %v", err)
	}
	if stored.RewardRevokedAt != nil {
		t.Fatalf("事务失败后奖励撤销时间应回滚: %v", stored.RewardRevokedAt)
	}
	var refreshed models.User
	if err := env.db.First(&refreshed, user.ID).Error; err != nil || refreshed.Exp != 30 {
		t.Fatalf("事务失败后经验应回滚: exp=%d err=%v", refreshed.Exp, err)
	}
	if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); err != nil {
		t.Fatalf("事务失败前不应删除文件: %v", err)
	}
}

func TestExamPaperLocalWithdrawReportsPurgeFailureAfterCommit(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "withdraw-purge-failure", models.RoleUser, true, 0)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusPending)
	env.handler.purgeLocalDelete = func(services.ExamPaperTrashMove) error { return errors.New("清理暂存文件失败") }

	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}
	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	if response.Code != http.StatusInternalServerError || !strings.Contains(response.Body.String(), "exam_paper_file_cleanup_pending") {
		t.Fatalf("暂存文件清理失败应可观察: status=%d body=%s", response.Code, response.Body.String())
	}
	var count int64
	env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&count)
	if count != 0 {
		t.Fatalf("数据库事务已提交，记录应删除: %d", count)
	}
}

func TestExamPaperWithdrawCleansRecordWhenStoredFileAlreadyMissing(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "withdraw-missing-file", models.RoleUser, true, 0)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusPending)
	if err := os.Remove(filepath.Join(env.root, paper.FileKey)); err != nil {
		t.Fatalf("删除测试 PDF 失败: %v", err)
	}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("文件已丢失时撤回应清理记录: status=%d body=%s", response.Code, response.Body.String())
	}
	var count int64
	env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&count)
	if count != 0 {
		t.Fatalf("撤回后记录应删除: %d", count)
	}
}

func TestExamPaperAdminUploadPublishesWithoutRewardAndWritesLog(t *testing.T) {
	env := newExamPaperTestEnv(t)
	admin := createExamPaperTestUser(t, env.db, "direct-admin", models.RoleAdmin, false, 120)
	body, contentType := buildExamPaperUploadBody(t, true, buildHandlerTestPDF())

	response := performExamPaperRequest(env.handler.Upload, http.MethodPost, "/api/exam-papers", nil, admin.ID, body, contentType)
	if response.Code != http.StatusCreated || !strings.Contains(response.Body.String(), `"status":"published"`) {
		t.Fatalf("管理员直接上传失败: status=%d body=%s", response.Code, response.Body.String())
	}

	var paper models.ExamPaper
	if err := env.db.First(&paper).Error; err != nil {
		t.Fatalf("读取管理员上传记录失败: %v", err)
	}
	if paper.Source != models.ExamPaperSourceAdmin || paper.ReviewerID == nil || *paper.ReviewerID != admin.ID || paper.PublishedAt == nil {
		t.Fatalf("管理员上传审核字段错误: %#v", paper)
	}
	if paper.RewardedAt != nil {
		t.Fatal("管理员直接上传不得写入奖励时间")
	}
	var refreshed models.User
	env.db.First(&refreshed, admin.ID)
	if refreshed.Exp != 120 {
		t.Fatalf("管理员直接上传不得增加经验: %d", refreshed.Exp)
	}
	var logCount int64
	env.db.Model(&models.AdminLog{}).Where("admin_id = ? AND action = ?", admin.ID, "直接发布试卷").Count(&logCount)
	if logCount != 1 {
		t.Fatalf("管理员直接上传必须写入一条操作日志: %d", logCount)
	}
}

func TestExamPaperListAppliesFiltersAndDownloadSort(t *testing.T) {
	env := newExamPaperTestEnv(t)
	reader := createExamPaperTestUser(t, env.db, "filter-reader", models.RoleUser, true, 0)
	contributor := createExamPaperTestUser(t, env.db, "filter-contributor", models.RoleUser, true, 0)
	now := time.Now()
	papers := []models.ExamPaper{
		{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "线性代数", AcademicYear: "2024-2025", Semester: models.ExamPaperSemesterSecond,
			ExamType: models.ExamPaperTypeMidterm, Title: "线性代数 · 2024-2025 · 第二学期 · 期中",
			FileKey: "filter-1.pdf", FileSize: 1, SHA256: "filter-hash-1", DownloadCount: 12, PublishedAt: &now,
		},
		{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "线性代数", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: "线性代数 · 2025-2026 · 第一学期 · 期末",
			FileKey: "filter-2.pdf", FileSize: 1, SHA256: "filter-hash-2", DownloadCount: 99, PublishedAt: &now,
		},
		{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "高等数学", AcademicYear: "2024-2025", Semester: models.ExamPaperSemesterSecond,
			ExamType: models.ExamPaperTypeMidterm, Title: "高等数学 · 2024-2025 · 第二学期 · 期中",
			FileKey: "filter-3.pdf", FileSize: 1, SHA256: "filter-hash-3", DownloadCount: 50, PublishedAt: &now,
		},
	}
	if err := env.db.Create(&papers).Error; err != nil {
		t.Fatalf("创建筛选测试数据失败: %v", err)
	}

	path := "/api/exam-papers?keyword=" + url.QueryEscape("线性") + "&academic_year=2024-2025&semester=second&exam_type=midterm&sort=downloads&page=1&page_size=1"
	response := performExamPaperRequest(env.handler.List, http.MethodGet, path, nil, reader.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("筛选列表失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Items []struct {
			ID uint `json:"id"`
		} `json:"items"`
		Total int64 `json:"total"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析筛选响应失败: %v", err)
	}
	if payload.Total != 1 || len(payload.Items) != 1 || payload.Items[0].ID != papers[0].ID {
		t.Fatalf("筛选结果错误: %s", response.Body.String())
	}
}

func TestExamPaperListReturnsGlobalPublishedAcademicYears(t *testing.T) {
	env := newExamPaperTestEnv(t)
	reader := createExamPaperTestUser(t, env.db, "year-reader", models.RoleUser, true, 0)
	contributor := createExamPaperTestUser(t, env.db, "year-contributor", models.RoleUser, true, 0)
	now := time.Now()
	papers := []models.ExamPaper{
		{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "高等数学", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: "高等数学 2025", FileKey: "year-1.pdf",
			FileSize: 1, SHA256: "year-hash-1", PublishedAt: &now,
		},
		{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "线性代数", AcademicYear: "2024-2025", Semester: models.ExamPaperSemesterSecond,
			ExamType: models.ExamPaperTypeMidterm, Title: "线性代数 2024", FileKey: "year-2.pdf",
			FileSize: 1, SHA256: "year-hash-2", PublishedAt: &now,
		},
		{
			Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "大学物理", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: "大学物理 2025", FileKey: "year-3.pdf",
			FileSize: 1, SHA256: "year-hash-3", PublishedAt: &now,
		},
		{
			Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: contributor.ID,
			CourseName: "待审核", AcademicYear: "2023-2024", Semester: models.ExamPaperSemesterFirst,
			ExamType: models.ExamPaperTypeFinal, Title: "待审核 2023", FileKey: "year-4.pdf",
			FileSize: 1, SHA256: "year-hash-4",
		},
	}
	if err := env.db.Create(&papers).Error; err != nil {
		t.Fatal(err)
	}

	response := performExamPaperRequest(
		env.handler.List,
		http.MethodGet,
		"/api/exam-papers?keyword="+url.QueryEscape("高等")+"&academic_year=2025-2026",
		nil,
		reader.ID,
		nil,
		"",
	)
	if response.Code != http.StatusOK {
		t.Fatalf("列表请求失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Total         int64    `json:"total"`
		AcademicYears []string `json:"academic_years"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Total != 1 {
		t.Fatalf("筛选结果数量错误: %d", payload.Total)
	}
	wantYears := []string{"2025-2026", "2024-2025"}
	if !reflect.DeepEqual(payload.AcademicYears, wantYears) {
		t.Fatalf("学年集合 = %v，期望 %v", payload.AcademicYears, wantYears)
	}
}

func TestExamPaperGetOnlyReturnsPublishedPaper(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "detail-user", models.RoleUser, true, 0)
	published := models.ExamPaper{
		Status: models.ExamPaperStatusPublished, Source: models.ExamPaperSourceUser, SubmitterID: user.ID,
		CourseName: "????", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
		ExamType: models.ExamPaperTypeFinal, Title: "???? ? 2025-2026 ? ???? ? ??",
		FileKey: "detail-published.pdf", FileSize: 1, SHA256: "detail-published-hash",
	}
	pending := published
	pending.ID = 0
	pending.Status = models.ExamPaperStatusPending
	pending.FileKey = "detail-pending.pdf"
	pending.SHA256 = "detail-pending-hash"
	if err := env.db.Create(&published).Error; err != nil {
		t.Fatalf("?????????: %v", err)
	}
	if err := env.db.Create(&pending).Error; err != nil {
		t.Fatalf("?????????: %v", err)
	}

	okResponse := performExamPaperRequest(env.handler.Get, http.MethodGet, "/api/exam-papers/1", gin.Params{{Key: "id", Value: fmt.Sprint(published.ID)}}, user.ID, nil, "")
	if okResponse.Code != http.StatusOK || !strings.Contains(okResponse.Body.String(), published.Title) {
		t.Fatalf("?????????: status=%d body=%s", okResponse.Code, okResponse.Body.String())
	}
	pendingResponse := performExamPaperRequest(env.handler.Get, http.MethodGet, "/api/exam-papers/2", gin.Params{{Key: "id", Value: fmt.Sprint(pending.ID)}}, user.ID, nil, "")
	if pendingResponse.Code != http.StatusNotFound || decodeErrorCode(t, pendingResponse) != "exam_paper_not_found" {
		t.Fatalf("???????????????: status=%d body=%s", pendingResponse.Code, pendingResponse.Body.String())
	}
}

func TestExamPaperMySubmissionsFiltersStatusAndReturnsCounts(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "submission-user", models.RoleUser, true, 0)
	other := createExamPaperTestUser(t, env.db, "submission-other", models.RoleUser, true, 0)
	statuses := []models.ExamPaperStatus{
		models.ExamPaperStatusPending,
		models.ExamPaperStatusPublished,
		models.ExamPaperStatusUnpublished,
	}
	for index, status := range statuses {
		paper := models.ExamPaper{
			Status: status, Source: models.ExamPaperSourceUser, SubmitterID: user.ID,
			CourseName: fmt.Sprintf("??%d", index), AcademicYear: "2025-2026",
			Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal,
			Title:   fmt.Sprintf("??%d ? 2025-2026 ? ???? ? ??", index),
			FileKey: fmt.Sprintf("submission-%d.pdf", index), FileSize: 1, SHA256: fmt.Sprintf("submission-hash-%d", index),
		}
		if status == models.ExamPaperStatusUnpublished {
			paper.FileKey = ""
		}
		if err := env.db.Create(&paper).Error; err != nil {
			t.Fatalf("??????????: %v", err)
		}
	}
	otherPaper := models.ExamPaper{
		Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser, SubmitterID: other.ID,
		CourseName: "????", AcademicYear: "2025-2026", Semester: models.ExamPaperSemesterFirst,
		ExamType: models.ExamPaperTypeFinal, Title: "???? ? 2025-2026 ? ???? ? ??",
		FileKey: "other.pdf", FileSize: 1, SHA256: "other-submission-hash",
	}
	if err := env.db.Create(&otherPaper).Error; err != nil {
		t.Fatalf("????????: %v", err)
	}

	response := performExamPaperRequest(env.handler.MySubmissions, http.MethodGet, "/api/exam-papers/my-submissions?status=unpublished", nil, user.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("????????: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Items []struct {
			Status models.ExamPaperStatus `json:"status"`
		} `json:"items"`
		Total        int64            `json:"total"`
		StatusCounts map[string]int64 `json:"status_counts"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("????????: %v", err)
	}
	if payload.Total != 1 || len(payload.Items) != 1 || payload.Items[0].Status != models.ExamPaperStatusUnpublished {
		t.Fatalf("状态筛选结果错误: %s", response.Body.String())
	}
	if payload.StatusCounts["all"] != 3 || payload.StatusCounts["pending"] != 1 || payload.StatusCounts["published"] != 1 || payload.StatusCounts["unpublished"] != 1 {
		t.Fatalf("投稿状态计数错误: %s", response.Body.String())
	}

	legacy := performExamPaperRequest(env.handler.MySubmissions, http.MethodGet, "/api/exam-papers/my-submissions", nil, user.ID, nil, "")
	var legacyPayload struct {
		Items []struct {
			Status models.ExamPaperStatus `json:"status"`
		} `json:"items"`
		Total int64 `json:"total"`
	}
	if err := json.Unmarshal(legacy.Body.Bytes(), &legacyPayload); err != nil {
		t.Fatalf("解析兼容响应失败: %v", err)
	}
	if legacyPayload.Total != 2 || len(legacyPayload.Items) != 2 {
		t.Fatalf("未传 status 时必须保持旧客户端行为: %s", legacy.Body.String())
	}
	for _, item := range legacyPayload.Items {
		if item.Status == models.ExamPaperStatusUnpublished {
			t.Fatalf("旧客户端默认响应不能包含已下架投稿: %s", legacy.Body.String())
		}
	}

	all := performExamPaperRequest(env.handler.MySubmissions, http.MethodGet, "/api/exam-papers/my-submissions?status=all", nil, user.ID, nil, "")
	var allPayload struct {
		Total int64 `json:"total"`
	}
	if err := json.Unmarshal(all.Body.Bytes(), &allPayload); err != nil || allPayload.Total != 3 {
		t.Fatalf("显式 all 必须返回全部状态: %s", all.Body.String())
	}

	invalid := performExamPaperRequest(env.handler.MySubmissions, http.MethodGet, "/api/exam-papers/my-submissions?status=deleted", nil, user.ID, nil, "")
	if invalid.Code != http.StatusBadRequest || decodeErrorCode(t, invalid) != "invalid_exam_paper_status" {
		t.Fatalf("非法状态必须被拒绝: status=%d body=%s", invalid.Code, invalid.Body.String())
	}
}

func TestExamPaperMySubmissionsEmptyCountsIncludeAllStatuses(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "empty-submission-user", models.RoleUser, true, 0)
	response := performExamPaperRequest(env.handler.MySubmissions, http.MethodGet, "/api/exam-papers/my-submissions?status=all", nil, user.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("空投稿列表响应失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		StatusCounts map[string]int64 `json:"status_counts"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析空投稿计数失败: %v", err)
	}
	for _, status := range []string{"all", "pending", "published", "unpublished"} {
		value, ok := payload.StatusCounts[status]
		if !ok || value != 0 {
			t.Fatalf("空投稿必须显式返回 %s=0: %s", status, response.Body.String())
		}
	}
}
