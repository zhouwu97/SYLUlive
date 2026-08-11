package handlers

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func TestCompetitionAwardEvidenceStorageIsolatedFromPublicFiles(t *testing.T) {
	db := newCompetitionTestDB(t)
	privateDir := t.TempDir()
	publicDir := t.TempDir()
	handler, err := NewCompetitionHandlerWithEvidenceStorage(db, privateDir, 1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	uploadHandler := NewUploadHandler(publicDir, 1024*1024, db)
	content := validEvidencePNG(t)
	hashBytes := sha256.Sum256(content)
	hashValue := hex.EncodeToString(hashBytes[:])
	publicRelative := filepath.ToSlash(filepath.Join(hashValue[:2], hashValue+".png"))
	publicPath := filepath.Join(publicDir, filepath.FromSlash(publicRelative))
	if err := os.MkdirAll(filepath.Dir(publicPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(publicPath, content, 0o644); err != nil {
		t.Fatal(err)
	}
	publicFile := models.File{
		Hash: hashValue, Path: "/uploads/" + publicRelative, Size: int64(len(content)),
		MimeType: "image/png", UploaderID: 10, Status: "active", AccessScope: models.FileAccessPublic,
	}
	if err := db.Create(&publicFile).Error; err != nil {
		t.Fatal(err)
	}

	privateUpload, privateID := uploadPrivateEvidence(t, handler, 20, content)
	var privatePayload map[string]any
	if err := json.Unmarshal(privateUpload.Body.Bytes(), &privatePayload); err != nil {
		t.Fatal(err)
	}
	if _, exposed := privatePayload["url"]; exposed {
		t.Fatalf("私有上传响应泄露公共 URL: %s", privateUpload.Body.String())
	}

	for _, method := range []string{http.MethodGet, http.MethodHead} {
		response := servePublicFile(t, uploadHandler, method, publicRelative)
		if response.Code != http.StatusOK {
			t.Fatalf("public %s status=%d body=%s", method, response.Code, response.Body.String())
		}
		if response.Header().Get("Cache-Control") != "public, max-age=31536000, immutable" {
			t.Fatalf("public cache header=%q", response.Header().Get("Cache-Control"))
		}
		if method == http.MethodHead && response.Body.Len() != 0 {
			t.Fatalf("HEAD 返回了文件正文，长度=%d", response.Body.Len())
		}
	}

	var privateFile models.CompetitionAwardEvidenceFile
	if err := db.First(&privateFile, privateID).Error; err != nil {
		t.Fatal(err)
	}
	guessedPublic := servePublicFile(t, uploadHandler, http.MethodGet, privateFile.Path)
	if guessedPublic.Code != http.StatusNotFound {
		t.Fatalf("未认领私有材料可从公共路径访问: status=%d", guessedPublic.Code)
	}
	invalidBody := strings.Replace(validCompetitionAwardBody(time.Now().Year()), `"competition_title":"程序设计竞赛"`, `"competition_title":""`, 1)
	invalidBody = strings.Replace(invalidBody, `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, privateID), 1)
	failedCreate := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/api/user/competition-awards", invalidBody, 20, 0)
	if failedCreate.Code != http.StatusBadRequest {
		t.Fatalf("invalid create status=%d body=%s", failedCreate.Code, failedCreate.Body.String())
	}
	if err := db.First(&privateFile, privateID).Error; err != nil || privateFile.Status != "temporary" || privateFile.ClaimedAt != nil {
		t.Fatalf("失败创建错误认领材料: file=%+v err=%v", privateFile, err)
	}
	if response := servePublicFile(t, uploadHandler, http.MethodGet, privateFile.Path); response.Code != http.StatusNotFound {
		t.Fatalf("失败创建后材料变为公开: status=%d", response.Code)
	}
}

func TestCompetitionAwardEvidenceSameContentDoesNotShareAuthorization(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler, err := NewCompetitionHandlerWithEvidenceStorage(db, t.TempDir(), 1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	content := validEvidencePNG(t)
	_, firstID := uploadPrivateEvidence(t, handler, 31, content)
	_, secondID := uploadPrivateEvidence(t, handler, 32, content)
	if firstID == secondID {
		t.Fatalf("不同用户错误复用了同一私有文件 ID: %d", firstID)
	}
	var first, second models.CompetitionAwardEvidenceFile
	if err := db.First(&first, firstID).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.First(&second, secondID).Error; err != nil {
		t.Fatal(err)
	}
	if first.Path == second.Path || first.UploaderID == second.UploaderID {
		t.Fatalf("不同用户私有材料未隔离: first=%+v second=%+v", first, second)
	}

	foreignBody := strings.Replace(validCompetitionAwardBody(time.Now().Year()), `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, secondID), 1)
	if response := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/", foreignBody, 31, 0); response.Code != http.StatusBadRequest {
		t.Fatalf("A 用户引用 B 材料 status=%d body=%s", response.Code, response.Body.String())
	}
	ownedBody := strings.Replace(validCompetitionAwardBody(time.Now().Year()), `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, secondID), 1)
	created := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/", ownedBody, 32, 0)
	if created.Code != http.StatusCreated {
		t.Fatalf("B 用户创建经历 status=%d body=%s", created.Code, created.Body.String())
	}
	var award models.UserCompetitionAward
	if err := db.Where("user_id = ?", 32).First(&award).Error; err != nil {
		t.Fatal(err)
	}
	if response := evidenceRequest(t, handler.DownloadOwnCompetitionAwardEvidence, award.ID, secondID, 31, "user"); response.Code != http.StatusNotFound {
		t.Fatalf("A 用户读取 B 材料 status=%d", response.Code)
	}
}

func uploadPrivateEvidence(t *testing.T, handler *CompetitionHandler, userID uint, content []byte) (*httptest.ResponseRecorder, uint) {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "evidence.png")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/user/competition-awards/evidence", &body)
	context.Request.Header.Set("Content-Type", writer.FormDataContentType())
	context.Set("user_id", userID)
	handler.UploadCompetitionAwardEvidence(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("upload status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		EvidenceFileID uint `json:"evidence_file_id"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response.EvidenceFileID == 0 {
		t.Fatalf("upload response=%s err=%v", recorder.Body.String(), err)
	}
	return recorder, response.EvidenceFileID
}

func servePublicFile(t *testing.T, handler *UploadHandler, method, relative string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, "/uploads/"+relative, nil)
	context.Params = gin.Params{{Key: "filepath", Value: "/" + filepath.ToSlash(relative)}}
	handler.ServePublic(context)
	return recorder
}

func validEvidencePNG(t *testing.T) []byte {
	t.Helper()
	content, err := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
	if err != nil {
		t.Fatal(err)
	}
	return content
}
