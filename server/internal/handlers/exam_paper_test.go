package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
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

func TestExamPaperWithdrawDeletesPendingRecordAndFile(t *testing.T) {
	env := newExamPaperTestEnv(t)
	user := createExamPaperTestUser(t, env.db, "withdrawer", models.RoleUser, true, 0)
	paper := createStoredExamPaper(t, env, user, models.ExamPaperStatusPending)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(paper.ID)}}

	response := performExamPaperRequest(env.handler.Withdraw, http.MethodDelete, "/api/exam-papers/my-submissions/1", params, user.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("撤回投稿失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var count int64
	env.db.Model(&models.ExamPaper{}).Where("id = ?", paper.ID).Count(&count)
	if count != 0 {
		t.Fatalf("撤回后记录仍存在: %d", count)
	}
	if _, err := os.Stat(filepath.Join(env.root, paper.FileKey)); !os.IsNotExist(err) {
		t.Fatalf("撤回后私有文件仍存在: %v", err)
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

func TestExamPaperMySubmissionsReturnsPendingAndPublishedOnly(t *testing.T) {
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

	response := performExamPaperRequest(env.handler.MySubmissions, http.MethodGet, "/api/exam-papers/my-submissions", nil, user.ID, nil, "")
	if response.Code != http.StatusOK {
		t.Fatalf("????????: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Items []struct {
			Status models.ExamPaperStatus `json:"status"`
		} `json:"items"`
		Total int64 `json:"total"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("????????: %v", err)
	}
	if payload.Total != 2 || len(payload.Items) != 2 {
		t.Fatalf("????????: %s", response.Body.String())
	}
	for _, item := range payload.Items {
		if item.Status == models.ExamPaperStatusUnpublished {
			t.Fatalf("?????????????: %s", response.Body.String())
		}
	}
}
