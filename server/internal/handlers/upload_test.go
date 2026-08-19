package handlers

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"hash/crc32"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func newUploadTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file::memory:?cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	if err := db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}); err != nil {
		t.Fatalf("migrate test db: %v", err)
	}
	return db
}

func createUploadMultipartRequest(t *testing.T, fieldName, filename string, content []byte) (*http.Request, string) {
	t.Helper()
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile(fieldName, filename)
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req, writer.FormDataContentType()
}

func TestUploadMissingPhysicalFileRecoveryRestoresExistingPath(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	handler := NewUploadHandler(uploadDir, 10<<20, db)

	pngBytes := newPNGBytes(t, 200, 200)
	hash := sha256.Sum256(pngBytes)
	hashStr := hex.EncodeToString(hash[:])

	// 1. 首次正常上传
	req1, _ := createUploadMultipartRequest(t, "file", "test.png", pngBytes)
	w1 := httptest.NewRecorder()
	c1, _ := gin.CreateTestContext(w1)
	c1.Request = req1
	c1.Set("user_id", uint(1))

	handler.Upload(c1)
	if w1.Code != http.StatusOK {
		t.Fatalf("first upload failed: code=%d body=%s", w1.Code, w1.Body.String())
	}

	var res1 map[string]interface{}
	if err := json.Unmarshal(w1.Body.Bytes(), &res1); err != nil {
		t.Fatalf("unmarshal response 1: %v", err)
	}
	url1 := res1["url"].(string)
	if res1["hash"] != hashStr {
		t.Fatalf("expected hash %s, got %v", hashStr, res1["hash"])
	}

	diskPath1, err := services.ResolveUploadPath(uploadDir, url1)
	if err != nil {
		t.Fatalf("resolve disk path 1: %v", err)
	}
	if _, err := os.Stat(diskPath1); err != nil {
		t.Fatalf("expected physical file on disk: %v", err)
	}

	// 2. 模拟磁盘物理文件丢失（数据库仍有记录）
	if err := os.Remove(diskPath1); err != nil {
		t.Fatalf("remove physical file: %v", err)
	}
	if _, err := os.Stat(diskPath1); !os.IsNotExist(err) {
		t.Fatalf("file should be removed: %v", err)
	}

	// 3. 再次上传相同内容（触发 P0 恢复逻辑）
	req2, _ := createUploadMultipartRequest(t, "file", "test.png", pngBytes)
	w2 := httptest.NewRecorder()
	c2, _ := gin.CreateTestContext(w2)
	c2.Request = req2
	c2.Set("user_id", uint(2))

	handler.Upload(c2)
	if w2.Code != http.StatusOK {
		t.Fatalf("recovery upload failed: code=%d body=%s", w2.Code, w2.Body.String())
	}

	var res2 map[string]interface{}
	if err := json.Unmarshal(w2.Body.Bytes(), &res2); err != nil {
		t.Fatalf("unmarshal response 2: %v", err)
	}
	url2 := res2["url"].(string)

	// 断言：返回的 URL 与旧 URL 保持一致（不迁移 URL），物理文件被写回原路径
	if url2 != url1 {
		t.Fatalf("expected recovered URL %q to match original %q, got %q", url1, url1, url2)
	}

	if _, err := os.Stat(diskPath1); err != nil {
		t.Fatalf("expected physical file to be restored at original path: %v", err)
	}
	restoredContent, err := os.ReadFile(diskPath1)
	if err != nil || !bytes.Equal(restoredContent, pngBytes) {
		t.Fatalf("restored file content mismatch")
	}

	// 断言：files 表中依然只有 1 条记录
	var fileCount int64
	db.Model(&models.File{}).Where("hash = ?", hashStr).Count(&fileCount)
	if fileCount != 1 {
		t.Fatalf("expected exactly 1 file record, got %d", fileCount)
	}

	// 断言：用户 2 成功获得所有权 grant
	var grantCount int64
	db.Model(&models.FileUploadGrant{}).Where("user_id = ?", 2).Count(&grantCount)
	if grantCount != 1 {
		t.Fatalf("expected user 2 grant, got %d", grantCount)
	}
}

func TestUploadMultipleMissingPhysicalFileRecovery(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newUploadTestDB(t)
	uploadDir := t.TempDir()
	handler := NewUploadHandler(uploadDir, 10<<20, db)

	pngBytes := newPNGBytes(t, 150, 150)
	hash := sha256.Sum256(pngBytes)
	hashStr := hex.EncodeToString(hash[:])

	// 1. 首次上传
	req1, _ := createUploadMultipartRequest(t, "file", "multi1.png", pngBytes)
	w1 := httptest.NewRecorder()
	c1, _ := gin.CreateTestContext(w1)
	c1.Request = req1
	c1.Set("user_id", uint(1))
	handler.Upload(c1)
	if w1.Code != http.StatusOK {
		t.Fatalf("upload 1: %v", w1.Body.String())
	}

	var res1 map[string]interface{}
	json.Unmarshal(w1.Body.Bytes(), &res1)
	url1 := res1["url"].(string)
	diskPath1, _ := services.ResolveUploadPath(uploadDir, url1)

	// 删除磁盘文件
	os.Remove(diskPath1)

	// 2. 批量上传再次提交该文件
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, _ := writer.CreateFormFile("files", "multi1.png")
	part.Write(pngBytes)
	writer.Close()

	req2 := httptest.NewRequest(http.MethodPost, "/upload/multiple", body)
	req2.Header.Set("Content-Type", writer.FormDataContentType())
	w2 := httptest.NewRecorder()
	c2, _ := gin.CreateTestContext(w2)
	c2.Request = req2
	c2.Set("user_id", uint(2))

	handler.UploadMultiple(c2)
	if w2.Code != http.StatusOK {
		t.Fatalf("upload multiple: %v", w2.Body.String())
	}

	// 验证磁盘文件已恢复
	if _, err := os.Stat(diskPath1); err != nil {
		t.Fatalf("expected physical file restored: %v", err)
	}

	var fileCount int64
	db.Model(&models.File{}).Where("hash = ?", hashStr).Count(&fileCount)
	if fileCount != 1 {
		t.Fatalf("expected 1 file record, got %d", fileCount)
	}
}

func TestValidateImageFileDimensionAndPixelLimits(t *testing.T) {
	// 1. 正常尺寸通过
	normal := newPNGBytes(t, 800, 600)
	meta, err := validateImageFile(bytes.NewReader(normal))
	if err != nil {
		t.Fatalf("normal image should pass: %v", err)
	}
	if meta.Width != 800 || meta.Height != 600 {
		t.Fatalf("expected 800x600, got %dx%d", meta.Width, meta.Height)
	}

	// 2. 构造一个单边超过 12,000 的虚构 PNG header 模拟高分辨率攻击
	oversizedPNG := createFakePNGHeader(13000, 100)
	_, err = validateImageFile(bytes.NewReader(oversizedPNG))
	if err == nil || err.Error() != "图片分辨率过高" {
		t.Fatalf("expected '图片分辨率过高', got %v", err)
	}

	// 3. 构造一个总像素超过 50,000,000 的虚构 PNG header (8000 x 8000 = 64M pixels)
	overpixelPNG := createFakePNGHeader(8000, 8000)
	_, err = validateImageFile(bytes.NewReader(overpixelPNG))
	if err == nil || err.Error() != "图片分辨率过高" {
		t.Fatalf("expected '图片分辨率过高', got %v", err)
	}
}

// createFakePNGHeader 构造带有效 CRC 的 PNG IHDR 头，用于测试 DecodeConfig 尺寸防御
func createFakePNGHeader(width, height uint32) []byte {
	var buf bytes.Buffer
	// PNG signature (8 bytes)
	buf.Write([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A})
	// IHDR length = 13
	buf.Write([]byte{0x00, 0x00, 0x00, 0x0D})
	ihdrData := make([]byte, 17)
	copy(ihdrData[0:4], []byte("IHDR"))
	ihdrData[4] = byte(width >> 24)
	ihdrData[5] = byte(width >> 16)
	ihdrData[6] = byte(width >> 8)
	ihdrData[7] = byte(width)

	ihdrData[8] = byte(height >> 24)
	ihdrData[9] = byte(height >> 16)
	ihdrData[10] = byte(height >> 8)
	ihdrData[11] = byte(height)

	ihdrData[12] = 8 // bit depth
	ihdrData[13] = 6 // color type RGBA
	ihdrData[14] = 0 // compression
	ihdrData[15] = 0 // filter
	ihdrData[16] = 0 // interlace
	buf.Write(ihdrData)

	crc := crc32.ChecksumIEEE(ihdrData)
	buf.Write([]byte{
		byte(crc >> 24),
		byte(crc >> 16),
		byte(crc >> 8),
		byte(crc),
	})
	// IEND chunk
	buf.Write([]byte{0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82})
	return buf.Bytes()
}
