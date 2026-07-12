package handlers

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	"github.com/pdfcpu/pdfcpu/pkg/api"
	pdfmodel "github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"

	"shenliyuan/internal/services"
)

var paperStorageNow = time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)

const (
	paperStorageSessionID  = "11111111-1111-4111-8111-111111111111"
	paperStorageSessionID2 = "22222222-2222-4222-8222-222222222222"
)

func paperStoragePDF() []byte {
	objects := []string{
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>\nendobj\n",
		"4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n",
	}
	var pdf bytes.Buffer
	pdf.WriteString("%PDF-1.4\n")
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

func newPaperStorageTestHandler(t *testing.T, diskUsage float64) (*PaperStorageHandler, *services.ExamPaperFileService, *services.ExamPaperStorageSigner, *services.ExamPaperStorageSigner) {
	t.Helper()
	files, err := services.NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	grantSigner, err := services.NewExamPaperStorageSigner("grant-secret", func() time.Time { return paperStorageNow })
	if err != nil {
		t.Fatalf("初始化授权签名器失败: %v", err)
	}
	receiptSigner, err := services.NewExamPaperStorageSigner("receipt-secret", func() time.Time { return paperStorageNow })
	if err != nil {
		t.Fatalf("初始化回执签名器失败: %v", err)
	}
	handler := NewPaperStorageHandler(files, grantSigner, receiptSigner, 2)
	handler.now = func() time.Time { return paperStorageNow }
	handler.diskUsage = func(string) (float64, error) { return diskUsage, nil }
	return handler, files, grantSigner, receiptSigner
}

func paperStorageRouter(handler *PaperStorageHandler) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(gin.Recovery())
	RegisterPaperStorageRoutes(router, handler)
	return router
}

func signPaperStorageGrant(t *testing.T, signer *services.ExamPaperStorageSigner, purpose, method, path, sessionID, fileKey string) string {
	t.Helper()
	expectedSize := int64(0)
	userID := uint(0)
	if purpose == services.ExamPaperStoragePurposeUpload {
		expectedSize = int64(len(paperStoragePDF()))
		userID = 1
	}
	token, err := signer.SignGrant(services.ExamPaperStorageGrant{
		Purpose: purpose, Method: method, Path: path, SessionID: sessionID, FileKey: fileKey,
		UserID: userID, ExpectedSize: expectedSize, IssuedAt: paperStorageNow.Add(-time.Minute).Unix(), ExpiresAt: paperStorageNow.Add(time.Minute).Unix(), JTI: "test-jti",
	})
	if err != nil {
		t.Fatalf("签发授权失败: %v", err)
	}
	return token
}

func multipartPaperStorageRequest(t *testing.T, path, token, filename string, content []byte) *http.Request {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		t.Fatalf("创建 multipart 文件失败: %v", err)
	}
	_, _ = part.Write(content)
	_ = writer.Close()
	request := httptest.NewRequest(http.MethodPost, path, &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	return request
}

func signPaperStorageUploadGrant(t *testing.T, signer *services.ExamPaperStorageSigner, path, sessionID, jti string, expectedSize int64) string {
	t.Helper()
	token, err := signer.SignGrant(services.ExamPaperStorageGrant{
		Purpose: services.ExamPaperStoragePurposeUpload, Method: http.MethodPost, Path: path,
		SessionID: sessionID, UserID: 1, ExpectedSize: expectedSize, IssuedAt: paperStorageNow.Add(-time.Minute).Unix(),
		ExpiresAt: paperStorageNow.Add(time.Minute).Unix(), JTI: jti,
	})
	if err != nil {
		t.Fatalf("签发上传授权失败: %v", err)
	}
	return token
}

type panicPaperStorageBody struct{}

func (panicPaperStorageBody) Read([]byte) (int, error) {
	panic("上传正文不应被读取")
}

func (panicPaperStorageBody) Close() error { return nil }

func paperStorageReceiptFromResponse(t *testing.T, response *httptest.ResponseRecorder) string {
	t.Helper()
	var payload struct {
		Receipt string `json:"receipt"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil || payload.Receipt == "" {
		t.Fatalf("解析上传回执失败: receipt=%q err=%v body=%s", payload.Receipt, err, response.Body.String())
	}
	return payload.Receipt
}

func oversizedMultipartPaperStorageRequest(t *testing.T, path, token string) *http.Request {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "paper.pdf")
	if err != nil {
		t.Fatalf("创建 multipart 文件失败: %v", err)
	}
	_, _ = part.Write(paperStoragePDF())
	extra, err := writer.CreateFormField("padding")
	if err != nil {
		t.Fatalf("创建 multipart 附加字段失败: %v", err)
	}
	_, _ = extra.Write(bytes.Repeat([]byte("x"), int(services.ExamPaperMaxRequestBodySize)))
	_ = writer.Close()
	request := httptest.NewRequest(http.MethodPost, path, &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	request.Header.Set("Authorization", "Bearer "+token)
	return request
}

func TestPaperStorageUploadRequiresGrantAndReturnsVerifiableReceipt(t *testing.T) {
	handler, files, grantSigner, receiptSigner := newPaperStorageTestHandler(t, 20)
	router := paperStorageRouter(handler)
	path := "/v1/uploads/" + paperStorageSessionID

	unauthorized := httptest.NewRecorder()
	router.ServeHTTP(unauthorized, multipartPaperStorageRequest(t, path, "", "paper.pdf", paperStoragePDF()))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("无授权上传状态码错误: %d", unauthorized.Code)
	}

	token := signPaperStorageGrant(t, grantSigner, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if response.Code != http.StatusCreated {
		t.Fatalf("上传状态码错误: %d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Receipt string `json:"receipt"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析上传响应失败: %v", err)
	}
	receipt, err := receiptSigner.VerifyReceipt(payload.Receipt)
	if err != nil {
		t.Fatalf("验证上传回执失败: %v", err)
	}
	if receipt.SessionID != paperStorageSessionID || receipt.FileSize != int64(len(paperStoragePDF())) {
		t.Fatalf("上传回执内容错误: %+v", receipt)
	}
	if _, err := files.Metadata(receipt.FileKey); err != nil {
		t.Fatalf("上传文件未落盘: %v", err)
	}
}

func TestPaperStorageUploadReplaysReceiptWithoutReadingBodyAcrossRestart(t *testing.T) {
	handler, files, grantSigner, receiptSigner := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageUploadGrant(t, grantSigner, path, paperStorageSessionID, "replay-jti", int64(len(paperStoragePDF())))
	first := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(first, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if first.Code != http.StatusCreated {
		t.Fatalf("首次上传失败: code=%d body=%s", first.Code, first.Body.String())
	}
	firstReceipt := paperStorageReceiptFromResponse(t, first)

	replayRequest := httptest.NewRequest(http.MethodPost, path, strings.NewReader("正文不应被读取"))
	replayRequest.Header.Set("Content-Type", "application/json")
	replayRequest.Header.Set("Authorization", "Bearer "+token)
	replay := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(replay, replayRequest)
	if replay.Code != http.StatusCreated || paperStorageReceiptFromResponse(t, replay) != firstReceipt {
		t.Fatalf("顺序重放未返回原回执: code=%d body=%s", replay.Code, replay.Body.String())
	}

	restartedFiles, err := services.NewExamPaperFileService(files.RootDir())
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	restarted := NewPaperStorageHandler(restartedFiles, grantSigner, receiptSigner, 2)
	restarted.now = func() time.Time { return paperStorageNow }
	restarted.diskUsage = func(string) (float64, error) { return 20, nil }
	restartReplay := httptest.NewRecorder()
	paperStorageRouter(restarted).ServeHTTP(restartReplay, replayRequest.Clone(replayRequest.Context()))
	if restartReplay.Code != http.StatusCreated || paperStorageReceiptFromResponse(t, restartReplay) != firstReceipt {
		t.Fatalf("重启重放未返回原回执: code=%d body=%s", restartReplay.Code, restartReplay.Body.String())
	}
	rootEntries, err := os.ReadDir(files.RootDir())
	if err != nil {
		t.Fatalf("读取存储目录失败: %v", err)
	}
	pdfCount := 0
	for _, entry := range rootEntries {
		if filepath.Ext(entry.Name()) == ".pdf" {
			pdfCount++
		}
	}
	pendingEntries, err := os.ReadDir(filepath.Join(files.RootDir(), ".pending"))
	if err != nil || pdfCount != 1 || len(pendingEntries) != 1 {
		t.Fatalf("重放产生重复文件: pdf=%d pending=%d err=%v", pdfCount, len(pendingEntries), err)
	}
}

func TestPaperStorageUploadSizeMismatchAbortsReservationAndAllowsRetry(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageUploadGrant(t, signer, path, paperStorageSessionID, "size-jti", int64(len(paperStoragePDF())))
	originalStore := handler.storePending
	handler.storePending = func(filename string, source io.Reader, expectedSize int64) (*services.StoredExamPaperFile, error) {
		stored, err := originalStore(filename, source, expectedSize)
		if stored != nil {
			stored.Size++
		}
		return stored, err
	}
	bad := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(bad, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if bad.Code != http.StatusUnprocessableEntity || !bytes.Contains(bad.Body.Bytes(), []byte(`"error":"file_size_mismatch"`)) {
		t.Fatalf("大小不符响应错误: code=%d body=%s", bad.Code, bad.Body.String())
	}
	handler.storePending = originalStore
	retry := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(retry, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if retry.Code != http.StatusCreated {
		t.Fatalf("大小不符后同 token 无法重试: code=%d body=%s", retry.Code, retry.Body.String())
	}
	pendingEntries, err := os.ReadDir(filepath.Join(files.RootDir(), ".pending"))
	if err != nil || len(pendingEntries) != 1 {
		t.Fatalf("重试后 pending 数量错误: count=%d err=%v", len(pendingEntries), err)
	}
}

func TestPaperStorageUploadCompletionPersistenceFailureRollsBackAndAllowsRetry(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageUploadGrant(t, signer, path, paperStorageSessionID, "persistence-jti", int64(len(paperStoragePDF())))
	originalComplete := handler.completeUploadSession
	handler.completeUploadSession = func(string, string, string, services.StoredExamPaperFile, time.Time) error {
		return errors.New("模拟完成记录持久化失败")
	}
	failed := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(failed, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if failed.Code != http.StatusInternalServerError {
		t.Fatalf("完成记录持久化失败状态码错误: code=%d body=%s", failed.Code, failed.Body.String())
	}
	pendingEntries, err := os.ReadDir(filepath.Join(files.RootDir(), ".pending"))
	if err != nil || len(pendingEntries) != 0 {
		t.Fatalf("持久化失败后遗留 pending: count=%d err=%v", len(pendingEntries), err)
	}
	handler.completeUploadSession = originalComplete
	retry := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(retry, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if retry.Code != http.StatusCreated {
		t.Fatalf("持久化失败后同 token 无法重试: code=%d body=%s", retry.Code, retry.Body.String())
	}
}

func TestPaperStorageUploadConcurrentReplayReturnsConflict(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageUploadGrant(t, signer, path, paperStorageSessionID, "concurrent-jti", int64(len(paperStoragePDF())))
	originalStore := handler.storePending
	entered := make(chan struct{})
	release := make(chan struct{})
	handler.storePending = func(filename string, source io.Reader, expectedSize int64) (*services.StoredExamPaperFile, error) {
		close(entered)
		<-release
		return originalStore(filename, source, expectedSize)
	}
	first := httptest.NewRecorder()
	firstDone := make(chan struct{})
	go func() {
		paperStorageRouter(handler).ServeHTTP(first, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
		close(firstDone)
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("首次上传未进入存储阶段")
	}
	second := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(second, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if second.Code != http.StatusConflict || !bytes.Contains(second.Body.Bytes(), []byte(`"error":"upload_session_in_progress"`)) {
		t.Fatalf("并发重放响应错误: code=%d body=%s", second.Code, second.Body.String())
	}
	close(release)
	select {
	case <-firstDone:
	case <-time.After(5 * time.Second):
		t.Fatal("首次上传未完成")
	}
	if first.Code != http.StatusCreated {
		t.Fatalf("首次上传失败: code=%d body=%s", first.Code, first.Body.String())
	}
}

func TestPaperStorageUploadRejectsInvalidSessionClaimsBeforeStore(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	storeCalled := false
	handler.storePending = func(string, io.Reader, int64) (*services.StoredExamPaperFile, error) {
		storeCalled = true
		return nil, errors.New("不应调用")
	}
	for _, item := range []struct {
		name, sessionID string
		expectedSize    int64
	}{
		{name: "非法会话 ID", sessionID: "session-1", expectedSize: int64(len(paperStoragePDF()))},
		{name: "缺少预期大小", sessionID: paperStorageSessionID, expectedSize: 0},
	} {
		t.Run(item.name, func(t *testing.T) {
			path := "/v1/uploads/" + item.sessionID
			token := signPaperStorageUploadGrant(t, signer, path, item.sessionID, "invalid-jti", item.expectedSize)
			response := httptest.NewRecorder()
			paperStorageRouter(handler).ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
			if response.Code != http.StatusBadRequest || !bytes.Contains(response.Body.Bytes(), []byte(`"error":"upload_session_invalid"`)) {
				t.Fatalf("非法上传声明响应错误: code=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
	if storeCalled {
		t.Fatal("非法上传声明不应读取或存储文件")
	}
}

func TestPaperStorageUploadRetryExhaustionRejectsBeforeReadingBodyAcrossRestart(t *testing.T) {
	handler, files, signer, receiptSigner := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageUploadGrant(t, signer, path, paperStorageSessionID, "retry-limit-jti", int64(len(paperStoragePDF())))
	invalidPDF := bytes.Repeat([]byte("x"), len(paperStoragePDF()))
	for attempt := 0; attempt < services.ExamPaperMaxUploadFailuresPerSession; attempt++ {
		response := httptest.NewRecorder()
		paperStorageRouter(handler).ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", invalidPDF))
		if response.Code != http.StatusUnprocessableEntity {
			t.Fatalf("第 %d 次失败状态码错误: code=%d body=%s", attempt+1, response.Code, response.Body.String())
		}
	}
	assertLocked := func(t *testing.T, current *PaperStorageHandler) {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, path, nil)
		request.Body = panicPaperStorageBody{}
		request.Header.Set("Content-Type", "multipart/form-data; boundary=unused")
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		paperStorageRouter(current).ServeHTTP(response, request)
		if response.Code != http.StatusTooManyRequests || !bytes.Contains(response.Body.Bytes(), []byte(`"error":"upload_retry_exhausted"`)) {
			t.Fatalf("失败次数耗尽响应错误: code=%d body=%s", response.Code, response.Body.String())
		}
		if len(current.validations) != 0 {
			t.Fatalf("失败次数耗尽不应占用 validation slot: %d", len(current.validations))
		}
	}
	assertLocked(t, handler)

	restartedFiles, err := services.NewExamPaperFileService(files.RootDir())
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	restarted := NewPaperStorageHandler(restartedFiles, signer, receiptSigner, 2)
	restarted.now = func() time.Time { return paperStorageNow }
	restarted.diskUsage = func(string) (float64, error) { return 20, nil }
	assertLocked(t, restarted)
}

func TestPaperStorageUploadMapsUnclaimedQuotaBeforeReadingBody(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	for index := 0; index < 5; index++ {
		sessionID := fmt.Sprintf("50000000-0000-4000-8000-%012d", index+1)
		jti := fmt.Sprintf("http-quota-%d", index)
		if _, err := files.BeginUploadSessionForUser(sessionID, jti, 42, services.ExamPaperMaxFileSize, paperStorageNow.Add(time.Minute), paperStorageNow); err != nil {
			t.Fatalf("创建配额状态失败: %v", err)
		}
		stored := services.StoredExamPaperFile{FileKey: sessionID + ".pdf", Size: services.ExamPaperMaxFileSize, SHA256: strings.Repeat("e", 64)}
		if err := files.CompleteUploadSession(sessionID, jti, "receipt-"+sessionID, stored, paperStorageNow); err != nil {
			t.Fatalf("完成配额状态失败: %v", err)
		}
	}
	sessionID := "50000000-0000-4000-8000-000000000006"
	path := "/v1/uploads/" + sessionID
	token, err := signer.SignGrant(services.ExamPaperStorageGrant{
		Purpose: services.ExamPaperStoragePurposeUpload, Method: http.MethodPost, Path: path,
		SessionID: sessionID, UserID: 42, ExpectedSize: 1, IssuedAt: paperStorageNow.Add(-time.Minute).Unix(),
		ExpiresAt: paperStorageNow.Add(time.Minute).Unix(), JTI: "http-quota-over",
	})
	if err != nil {
		t.Fatalf("签发配额测试授权失败: %v", err)
	}
	request := httptest.NewRequest(http.MethodPost, path, nil)
	request.Body = panicPaperStorageBody{}
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, request)
	if response.Code != http.StatusTooManyRequests || !bytes.Contains(response.Body.Bytes(), []byte(`"error":"upload_unclaimed_quota_exceeded"`)) {
		t.Fatalf("未认领配额响应错误: code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestPaperStorageUploadPrioritizesInProgressOverFullQuota(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	for index := 0; index < 5; index++ {
		sessionID := fmt.Sprintf("51000000-0000-4000-8000-%012d", index+1)
		if _, err := files.BeginUploadSessionForUser(sessionID, fmt.Sprintf("http-full-quota-%d", index), 53, services.ExamPaperMaxFileSize, paperStorageNow.Add(time.Minute), paperStorageNow); err != nil {
			t.Fatalf("填充配额失败: %v", err)
		}
	}
	sessionID := "51000000-0000-4000-8000-000000000001"
	path := "/v1/uploads/" + sessionID
	token, err := signer.SignGrant(services.ExamPaperStorageGrant{
		Purpose: services.ExamPaperStoragePurposeUpload, Method: http.MethodPost, Path: path,
		SessionID: sessionID, UserID: 53, ExpectedSize: services.ExamPaperMaxFileSize, IssuedAt: paperStorageNow.Add(-time.Minute).Unix(),
		ExpiresAt: paperStorageNow.Add(time.Minute).Unix(), JTI: "http-full-quota-0",
	})
	if err != nil {
		t.Fatalf("签发并发重放授权失败: %v", err)
	}
	request := httptest.NewRequest(http.MethodPost, path, nil)
	request.Body = panicPaperStorageBody{}
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !bytes.Contains(response.Body.Bytes(), []byte(`"error":"upload_session_in_progress"`)) {
		t.Fatalf("满配额时同 token 重放响应错误: code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestPaperStorageUploadMapsValidationSizeAndCapacityErrors(t *testing.T) {
	tests := []struct {
		name         string
		disk         float64
		content      []byte
		expectedSize int64
		want         int
	}{
		{name: "非法 PDF", disk: 20, content: []byte("not-pdf"), expectedSize: int64(len("not-pdf")), want: http.StatusUnprocessableEntity},
		{name: "文件超限", disk: 20, content: append([]byte("%PDF-"), bytes.Repeat([]byte("x"), int(services.ExamPaperMaxFileSize))...), expectedSize: services.ExamPaperMaxFileSize, want: http.StatusRequestEntityTooLarge},
		{name: "磁盘达到拒绝阈值", disk: 85, content: paperStoragePDF(), expectedSize: int64(len(paperStoragePDF())), want: http.StatusInsufficientStorage},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler, _, signer, _ := newPaperStorageTestHandler(t, tt.disk)
			router := paperStorageRouter(handler)
			path := "/v1/uploads/" + paperStorageSessionID
			token := signPaperStorageUploadGrant(t, signer, path, paperStorageSessionID, "validation-mapping-jti", tt.expectedSize)
			response := httptest.NewRecorder()
			router.ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", tt.content))
			if response.Code != tt.want {
				t.Fatalf("状态码错误: got=%d want=%d body=%s", response.Code, tt.want, response.Body.String())
			}
		})
	}
}

func TestPaperStorageUploadRejectsEncryptedPDFWith422(t *testing.T) {
	plainPath := filepath.Join(t.TempDir(), "plain.pdf")
	encryptedPath := filepath.Join(t.TempDir(), "encrypted.pdf")
	if err := os.WriteFile(plainPath, paperStoragePDF(), 0o600); err != nil {
		t.Fatalf("写入明文 PDF 失败: %v", err)
	}
	if err := api.EncryptFile(plainPath, encryptedPath, pdfmodel.NewAESConfiguration("open-password", "owner-password", 256)); err != nil {
		t.Fatalf("生成加密 PDF 失败: %v", err)
	}
	encrypted, err := os.ReadFile(encryptedPath)
	if err != nil {
		t.Fatalf("读取加密 PDF 失败: %v", err)
	}
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "encrypted.pdf", encrypted))
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("加密 PDF 状态码错误: %d body=%s", response.Code, response.Body.String())
	}
}

func TestPaperStorageUploadRejectsOversizedMultipartBodyAndReleasesSemaphore(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, oversizedMultipartPaperStorageRequest(t, path, token))
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("请求体超限状态码错误: %d body=%s", response.Code, response.Body.String())
	}
	if len(handler.validations) != 0 {
		t.Fatalf("校验信号量发生泄漏: %d", len(handler.validations))
	}
	entries, err := os.ReadDir(files.RootDir())
	if err != nil {
		t.Fatalf("读取存储目录失败: %v", err)
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) == ".pdf" {
			t.Fatalf("请求体超限后遗留文件: %s", entry.Name())
		}
	}
	pendingEntries, err := os.ReadDir(filepath.Join(files.RootDir(), ".pending"))
	if err != nil {
		t.Fatalf("读取 pending 目录失败: %v", err)
	}
	if len(pendingEntries) != 0 {
		t.Fatalf("请求体超限后遗留 pending marker: %d", len(pendingEntries))
	}
}

func TestPaperStorageUploadMapsMultipartClientErrorsToBadRequest(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	tests := []struct {
		name        string
		contentType string
		body        string
	}{
		{name: "错误 content type", contentType: "application/json", body: `{}`},
		{name: "缺少 boundary", contentType: "multipart/form-data", body: ""},
		{name: "畸形 multipart", contentType: "multipart/form-data; boundary=broken", body: "--broken\r\nContent-Disposition: form-data; name=\"file\"; filename=\"paper.pdf\"\r\nBadHeader\r\n\r\nx\r\n--broken--\r\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(tt.body))
			request.Header.Set("Content-Type", tt.contentType)
			request.Header.Set("Authorization", "Bearer "+token)
			response := httptest.NewRecorder()
			paperStorageRouter(handler).ServeHTTP(response, request)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("multipart 客户端错误状态码错误: %d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestPaperStorageDownloadUsesAuthorizedInternalRedirect(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	stored, err := files.StoreUploadReader("paper.pdf", bytes.NewReader(paperStoragePDF()))
	if err != nil {
		t.Fatalf("准备文件失败: %v", err)
	}
	router := paperStorageRouter(handler)
	path := "/v1/files/" + stored.FileKey
	for _, tt := range []struct{ purpose, disposition string }{
		{services.ExamPaperStoragePurposePreview, "inline"},
		{services.ExamPaperStoragePurposeDownload, "attachment"},
	} {
		token := signPaperStorageGrant(t, signer, tt.purpose, http.MethodGet, path, "", stored.FileKey)
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		if response.Code != http.StatusOK || response.Header().Get("X-Accel-Redirect") != "/_paper_files/"+url.PathEscape(stored.FileKey) {
			t.Fatalf("下载响应错误: code=%d headers=%v", response.Code, response.Header())
		}
		if got := response.Header().Get("Content-Disposition"); len(got) < len(tt.disposition) || got[:len(tt.disposition)] != tt.disposition {
			t.Fatalf("Content-Disposition 错误: %q", got)
		}
		if response.Header().Get("Cache-Control") != "private, no-store" || response.Body.Len() != 0 {
			t.Fatalf("下载不应由 Go 返回文件本体: headers=%v size=%d", response.Header(), response.Body.Len())
		}
	}
	bare := httptest.NewRecorder()
	router.ServeHTTP(bare, httptest.NewRequest(http.MethodGet, path, nil))
	if bare.Code != http.StatusUnauthorized {
		t.Fatalf("裸访问应拒绝: %d", bare.Code)
	}
}

func TestPaperStorageDownloadRejectsWrongPurposeAndExpiredGrant(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	stored, err := files.StoreUploadReader("paper.pdf", bytes.NewReader(paperStoragePDF()))
	if err != nil {
		t.Fatalf("准备文件失败: %v", err)
	}
	path := "/v1/files/" + stored.FileKey
	wrongPurpose := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeMetadata, http.MethodGet, path, "", stored.FileKey)
	expired, err := signer.SignGrant(services.ExamPaperStorageGrant{
		Purpose: services.ExamPaperStoragePurposePreview, Method: http.MethodGet, Path: path, FileKey: stored.FileKey,
		IssuedAt: paperStorageNow.Add(-2 * time.Minute).Unix(), ExpiresAt: paperStorageNow.Add(-time.Minute).Unix(), JTI: "expired",
	})
	if err != nil {
		t.Fatalf("签发过期授权失败: %v", err)
	}
	for _, token := range []string{wrongPurpose, expired} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		paperStorageRouter(handler).ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("错误授权应拒绝: %d", response.Code)
		}
	}
}

func TestPaperStorageMetadataReturns404ForAuthorizedMissingFile(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	fileKey := "00000000-0000-0000-0000-000000000000.pdf"
	path := "/internal/v1/files/" + fileKey + "/meta"
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeMetadata, http.MethodGet, path, "", fileKey)
	request := httptest.NewRequest(http.MethodGet, path, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("合法签名但文件不存在应返回 404: %d body=%s", response.Code, response.Body.String())
	}
}

func TestPaperStorageRejectsEncodedBackslashTraversalAtRoutes(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	for _, route := range []struct {
		method, path, purpose string
	}{
		{http.MethodGet, "/v1/files/..%5C..%5Csecret.pdf", services.ExamPaperStoragePurposeDownload},
		{http.MethodGet, "/internal/v1/files/..%5C..%5Csecret.pdf/meta", services.ExamPaperStoragePurposeMetadata},
	} {
		request := httptest.NewRequest(route.method, route.path, nil)
		fileKey := request.URL.Path[strings.Index(request.URL.Path, "/files/")+len("/files/"):]
		fileKey = strings.TrimSuffix(fileKey, "/meta")
		if !strings.Contains(fileKey, `\`) {
			t.Fatalf("测试路径未解码为反斜杠 file key: %q", fileKey)
		}
		token, err := signer.SignGrant(services.ExamPaperStorageGrant{
			Purpose: route.purpose, Method: route.method, Path: request.URL.Path, FileKey: fileKey,
			IssuedAt: paperStorageNow.Add(-time.Minute).Unix(), ExpiresAt: paperStorageNow.Add(time.Minute).Unix(), JTI: "traversal",
		})
		if err != nil {
			t.Fatalf("签发路径穿越测试授权失败: %v", err)
		}
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		paperStorageRouter(handler).ServeHTTP(response, request)
		if response.Code != http.StatusNotFound || !bytes.Contains(response.Body.Bytes(), []byte(`"error":"not found"`)) || response.Header().Get("X-Accel-Redirect") != "" {
			t.Fatalf("路径穿越应由 handler 明确拒绝: code=%d body=%s headers=%v", response.Code, response.Body.String(), response.Header())
		}
	}
}

func TestPaperStorageInternalLifecycleRoutes(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 42)
	stored, err := files.StoreUploadReader("paper.pdf", bytes.NewReader(paperStoragePDF()))
	if err != nil {
		t.Fatalf("准备文件失败: %v", err)
	}
	if err := files.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建标记失败: %v", err)
	}
	router := paperStorageRouter(handler)
	requests := []struct {
		method, path, purpose string
		want                  int
	}{
		{http.MethodGet, "/internal/v1/files/" + stored.FileKey + "/meta", services.ExamPaperStoragePurposeMetadata, http.StatusOK},
		{http.MethodPost, "/internal/v1/files/" + stored.FileKey + "/claim", services.ExamPaperStoragePurposeClaim, http.StatusOK},
		{http.MethodPost, "/internal/v1/files/" + stored.FileKey + "/claim", services.ExamPaperStoragePurposeClaim, http.StatusOK},
		{http.MethodPost, "/internal/v1/files/" + stored.FileKey + "/trash", services.ExamPaperStoragePurposeDelete, http.StatusOK},
		{http.MethodPost, "/internal/v1/files/" + stored.FileKey + "/trash", services.ExamPaperStoragePurposeDelete, http.StatusOK},
	}
	for _, tt := range requests {
		token := signPaperStorageGrant(t, signer, tt.purpose, tt.method, tt.path, "", stored.FileKey)
		request := httptest.NewRequest(tt.method, tt.path, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		if response.Code != tt.want {
			t.Fatalf("生命周期接口错误: %s %s code=%d body=%s", tt.method, tt.path, response.Code, response.Body.String())
		}
	}
}

func TestPaperStorageHealthThresholdsAndMaintenance(t *testing.T) {
	for _, tt := range []struct {
		usage  float64
		status string
	}{{69, "ok"}, {70, "warning"}, {95, "readonly"}} {
		handler, _, _, _ := newPaperStorageTestHandler(t, tt.usage)
		response := httptest.NewRecorder()
		paperStorageRouter(handler).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/healthz", nil))
		if response.Code != http.StatusOK || !bytes.Contains(response.Body.Bytes(), []byte(`"status":"`+tt.status+`"`)) {
			t.Fatalf("健康状态错误: usage=%v code=%d body=%s", tt.usage, response.Code, response.Body.String())
		}
	}
}

func TestPaperStorageMaintenanceRequiresGrantAndCleansExpiredContent(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 42)
	stored, err := files.StoreUploadReader("old.pdf", bytes.NewReader(paperStoragePDF()))
	if err != nil {
		t.Fatalf("准备维护文件失败: %v", err)
	}
	if err := files.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建维护标记失败: %v", err)
	}
	old := paperStorageNow.Add(-7*24*time.Hour - time.Second)
	if err := os.Chtimes(filepath.Join(files.RootDir(), ".pending", stored.FileKey), old, old); err != nil {
		t.Fatalf("设置维护文件时间失败: %v", err)
	}
	router := paperStorageRouter(handler)
	unauthorized := httptest.NewRecorder()
	router.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodPost, "/internal/v1/maintenance", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("无授权维护应返回 401: %d", unauthorized.Code)
	}
	path := "/internal/v1/maintenance"
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeMaintenance, http.MethodPost, path, "", "")
	request := httptest.NewRequest(http.MethodPost, path, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !bytes.Contains(response.Body.Bytes(), []byte(`"unclaimed_files_removed":1`)) || !bytes.Contains(response.Body.Bytes(), []byte(`"pending_markers_removed":1`)) || !bytes.Contains(response.Body.Bytes(), []byte(`"trash_files_removed"`)) || !bytes.Contains(response.Body.Bytes(), []byte(`"disk_usage_percent"`)) {
		t.Fatalf("维护响应结构或清理计数错误: code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestPaperStorageValidationSemaphoreBlocksUntilReleased(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	handler.validations = make(chan struct{}, 1)
	handler.validations <- struct{}{}
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	request := multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF())
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		paperStorageRouter(handler).ServeHTTP(response, request)
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("校验槽已满时上传不应提前完成")
	case <-time.After(100 * time.Millisecond):
	}
	<-handler.validations
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("释放校验槽后上传未完成")
	}
	if response.Code != http.StatusCreated || len(handler.validations) != 0 {
		t.Fatalf("释放校验槽后结果或信号量错误: code=%d slots=%d", response.Code, len(handler.validations))
	}
	invalid := httptest.NewRecorder()
	badPath := "/v1/uploads/" + paperStorageSessionID2
	badToken := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, badPath, paperStorageSessionID2, "")
	paperStorageRouter(handler).ServeHTTP(invalid, multipartPaperStorageRequest(t, badPath, badToken, "bad.pdf", []byte("bad")))
	if len(handler.validations) != 0 {
		t.Fatalf("异常路径泄漏校验槽: %d", len(handler.validations))
	}
}

func TestPaperStorageUploadMapsInternalStoreErrorTo500(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	handler.storePending = func(string, io.Reader, int64) (*services.StoredExamPaperFile, error) {
		return nil, errors.New("模拟磁盘写入失败")
	}
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("内部 I/O 错误应返回 500: %d body=%s", response.Code, response.Body.String())
	}
}

func TestPaperStorageUploadPanicReleasesValidationSlot(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 1)
	panicOnce := true
	original := handler.storePending
	handler.storePending = func(filename string, source io.Reader, expectedSize int64) (*services.StoredExamPaperFile, error) {
		if panicOnce {
			panicOnce = false
			panic("模拟校验 panic")
		}
		return original(filename, source, expectedSize)
	}
	path := "/v1/uploads/" + paperStorageSessionID
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
	first := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(first, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if first.Code != http.StatusInternalServerError || len(handler.validations) != 0 {
		t.Fatalf("panic 后状态或 slot 错误: code=%d slots=%d", first.Code, len(handler.validations))
	}
	second := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(second, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
	if second.Code != http.StatusCreated || len(handler.validations) != 0 {
		t.Fatalf("panic 后 slot 不可复用: code=%d slots=%d", second.Code, len(handler.validations))
	}
}

func TestPaperStorageDownloadUsesLightweightStatWithoutMetadataHash(t *testing.T) {
	handler, _, signer, _ := newPaperStorageTestHandler(t, 20)
	tempFile := filepath.Join(t.TempDir(), "regular.pdf")
	if err := os.WriteFile(tempFile, paperStoragePDF(), 0o600); err != nil {
		t.Fatalf("创建 stat 测试文件失败: %v", err)
	}
	info, err := os.Stat(tempFile)
	if err != nil {
		t.Fatalf("读取 stat 测试文件失败: %v", err)
	}
	handler.statFile = func(string) (os.FileInfo, error) { return info, nil }
	fileKey := "00000000-0000-0000-0000-000000000001.pdf"
	path := "/v1/files/" + fileKey
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeDownload, http.MethodGet, path, "", fileKey)
	request := httptest.NewRequest(http.MethodGet, path, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	paperStorageRouter(handler).ServeHTTP(response, request)
	if response.Code != http.StatusOK || response.Header().Get("X-Accel-Redirect") == "" {
		t.Fatalf("轻量 stat 后应直接重定向: code=%d headers=%v", response.Code, response.Header())
	}
}

type failingReceiptSigner struct{}

func (failingReceiptSigner) SignReceipt(services.ExamPaperUploadReceipt) (string, error) {
	return "", errors.New("签发失败")
}

func TestPaperStorageUploadRollsBackWhenMarkerOrReceiptFails(t *testing.T) {
	for _, failure := range []string{"marker", "receipt"} {
		t.Run(failure, func(t *testing.T) {
			handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
			if failure == "marker" {
				handler.storePending = func(string, io.Reader, int64) (*services.StoredExamPaperFile, error) {
					return nil, errors.New("标记失败")
				}
			} else {
				handler.receiptSigner = failingReceiptSigner{}
			}
			path := "/v1/uploads/" + paperStorageSessionID
			token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, paperStorageSessionID, "")
			response := httptest.NewRecorder()
			paperStorageRouter(handler).ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", paperStoragePDF()))
			if response.Code != http.StatusInternalServerError {
				t.Fatalf("失败状态码错误: %d", response.Code)
			}
			entries, err := os.ReadDir(files.RootDir())
			if err != nil {
				t.Fatalf("读取存储目录失败: %v", err)
			}
			for _, entry := range entries {
				if filepath.Ext(entry.Name()) == ".pdf" {
					t.Fatalf("失败后遗留孤儿文件: %s", entry.Name())
				}
			}
		})
	}
}
