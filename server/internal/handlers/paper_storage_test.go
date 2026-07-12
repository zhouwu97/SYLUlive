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
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/services"
)

var paperStorageNow = time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)

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
	RegisterPaperStorageRoutes(router, handler)
	return router
}

func signPaperStorageGrant(t *testing.T, signer *services.ExamPaperStorageSigner, purpose, method, path, sessionID, fileKey string) string {
	t.Helper()
	token, err := signer.SignGrant(services.ExamPaperStorageGrant{
		Purpose: purpose, Method: method, Path: path, SessionID: sessionID, FileKey: fileKey,
		IssuedAt: paperStorageNow.Add(-time.Minute).Unix(), ExpiresAt: paperStorageNow.Add(time.Minute).Unix(), JTI: "test-jti",
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
	path := "/v1/uploads/session-1"

	unauthorized := httptest.NewRecorder()
	router.ServeHTTP(unauthorized, multipartPaperStorageRequest(t, path, "", "paper.pdf", paperStoragePDF()))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("无授权上传状态码错误: %d", unauthorized.Code)
	}

	token := signPaperStorageGrant(t, grantSigner, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, "session-1", "")
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
	if receipt.SessionID != "session-1" || receipt.FileSize != int64(len(paperStoragePDF())) {
		t.Fatalf("上传回执内容错误: %+v", receipt)
	}
	if _, err := files.Metadata(receipt.FileKey); err != nil {
		t.Fatalf("上传文件未落盘: %v", err)
	}
}

func TestPaperStorageUploadMapsValidationSizeAndCapacityErrors(t *testing.T) {
	tests := []struct {
		name    string
		disk    float64
		content []byte
		want    int
	}{
		{name: "非法 PDF", disk: 20, content: []byte("not-pdf"), want: http.StatusUnprocessableEntity},
		{name: "文件超限", disk: 20, content: append([]byte("%PDF-"), bytes.Repeat([]byte("x"), int(services.ExamPaperMaxFileSize))...), want: http.StatusRequestEntityTooLarge},
		{name: "磁盘达到拒绝阈值", disk: 85, content: paperStoragePDF(), want: http.StatusInsufficientStorage},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler, _, signer, _ := newPaperStorageTestHandler(t, tt.disk)
			router := paperStorageRouter(handler)
			path := "/v1/uploads/session-1"
			token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, "session-1", "")
			response := httptest.NewRecorder()
			router.ServeHTTP(response, multipartPaperStorageRequest(t, path, token, "paper.pdf", tt.content))
			if response.Code != tt.want {
				t.Fatalf("状态码错误: got=%d want=%d body=%s", response.Code, tt.want, response.Body.String())
			}
		})
	}
}

func TestPaperStorageUploadRejectsOversizedMultipartBodyAndReleasesSemaphore(t *testing.T) {
	handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
	path := "/v1/uploads/session-1"
	token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, "session-1", "")
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

type failingReceiptSigner struct{}

func (failingReceiptSigner) SignReceipt(services.ExamPaperUploadReceipt) (string, error) {
	return "", errors.New("签发失败")
}

func TestPaperStorageUploadRollsBackWhenMarkerOrReceiptFails(t *testing.T) {
	for _, failure := range []string{"marker", "receipt"} {
		t.Run(failure, func(t *testing.T) {
			handler, files, signer, _ := newPaperStorageTestHandler(t, 20)
			if failure == "marker" {
				handler.markPending = func(string) error { return errors.New("标记失败") }
			} else {
				handler.receiptSigner = failingReceiptSigner{}
			}
			path := "/v1/uploads/session-1"
			token := signPaperStorageGrant(t, signer, services.ExamPaperStoragePurposeUpload, http.MethodPost, path, "session-1", "")
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
