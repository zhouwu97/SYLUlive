package handlers

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/gif"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
)

func TestUploadRejectsMissingPixelDataWithoutPersisting(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, multiple := range []bool{false, true} {
		t.Run(map[bool]string{false: "single", true: "multiple"}[multiple], func(t *testing.T) {
			db := newUploadTestDB(t)
			uploadDir := t.TempDir()
			handler := NewUploadHandler(uploadDir, 10<<20, db)
			var before int64
			db.Model(&models.File{}).Count(&before)
			field := "file"
			if multiple {
				field = "files"
			}
			request, _ := createUploadMultipartRequest(t, field, "broken.png", createFakePNGHeader(641, 479))
			response := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(response)
			context.Request = request
			context.Set("user_id", uint(1))
			if multiple {
				handler.UploadMultiple(context)
				var body struct {
					Results []map[string]any `json:"results"`
					Total   int              `json:"total"`
				}
				if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if body.Total != 0 || len(body.Results) != 1 || body.Results[0]["error"] == nil {
					t.Fatalf("损坏图片必须作为失败项返回: %s", response.Body.String())
				}
			} else {
				handler.Upload(context)
				if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "图片文件损坏") {
					t.Fatalf("损坏图片响应: code=%d body=%s", response.Code, response.Body.String())
				}
			}
			var after int64
			db.Model(&models.File{}).Count(&after)
			entries, err := os.ReadDir(uploadDir)
			if err != nil || after != before || len(entries) != 0 {
				t.Fatalf("损坏图片不应创建文件或记录: before=%d after=%d entries=%v err=%v", before, after, entries, err)
			}
		})
	}
}

func TestValidateImageFileAcceptsGIFWithPartialFirstFrame(t *testing.T) {
	frame := image.NewPaletted(image.Rect(10, 10, 30, 30), color.Palette{color.Black, color.White})
	var encoded bytes.Buffer
	if err := gif.EncodeAll(&encoded, &gif.GIF{
		Image: []*image.Paletted{frame}, Delay: []int{10},
		Config: image.Config{ColorModel: frame.Palette, Width: 100, Height: 100},
	}); err != nil {
		t.Fatal(err)
	}
	input := bytes.NewReader(encoded.Bytes())
	metadata, err := validateImageFile(input)
	if err != nil || metadata.Width != 100 || metadata.Height != 100 || metadata.MimeType != "image/gif" {
		t.Fatalf("合法的局部首帧GIF不应被拒绝: metadata=%+v err=%v", metadata, err)
	}
	position, err := input.Seek(0, 1)
	if err != nil || position != 0 {
		t.Fatalf("校验后应重置读取位置，保证保存完整原图: position=%d err=%v", position, err)
	}
}

func TestUploadMultipleEnforcesOneToNineImages(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, count := range []int{0, 9, 10} {
		t.Run(strconv.Itoa(count), func(t *testing.T) {
			db := newUploadTestDB(t)
			uploadDir := t.TempDir()
			handler := NewUploadHandler(uploadDir, 10<<20, db)
			var body bytes.Buffer
			writer := multipart.NewWriter(&body)
			for index := 0; index < count; index++ {
				part, err := writer.CreateFormFile("files", "photo.png")
				if err != nil {
					t.Fatal(err)
				}
				if _, err := part.Write(newPNGBytes(t, 10+index, 10)); err != nil {
					t.Fatal(err)
				}
			}
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/api/upload_multiple", &body)
			request.Header.Set("Content-Type", writer.FormDataContentType())
			response := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(response)
			context.Request = request
			context.Set("user_id", uint(1))
			handler.UploadMultiple(context)
			if count == 9 {
				var result struct {
					Total int `json:"total"`
				}
				if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
					t.Fatal(err)
				}
				if response.Code != http.StatusOK || result.Total != 9 {
					t.Fatalf("9张应全部上传成功: code=%d body=%s", response.Code, response.Body.String())
				}
			} else if response.Code != http.StatusBadRequest {
				t.Fatalf("空请求和10张请求应在写盘前拒绝: count=%d code=%d body=%s", count, response.Code, response.Body.String())
			} else if entries, err := os.ReadDir(uploadDir); err != nil || len(entries) != 0 {
				t.Fatalf("无效数量不应先保存部分图片: entries=%v err=%v", entries, err)
			}
		})
	}
}

func TestGrantFileToUserRefreshesRetentionWithoutChangingFile(t *testing.T) {
	db := newUploadTestDB(t)
	old := time.Now().Add(-7 * time.Hour)
	file := models.File{
		Hash: "handler-retention-renew", Path: "/uploads/handler-retention-renew.png", MimeType: "image/png",
		Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, CreatedAt: old,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	grant := models.FileUploadGrant{FileID: file.ID, UserID: 1, CreatedAt: old}
	if err := db.Create(&grant).Error; err != nil {
		t.Fatal(err)
	}
	before := time.Now().Add(-time.Second)
	if err := NewUploadHandler(t.TempDir(), 10<<20, db).grantFileToUser(file.ID, 1); err != nil {
		t.Fatal(err)
	}
	if err := db.First(&grant, grant.ID).Error; err != nil {
		t.Fatal(err)
	}
	if !grant.CreatedAt.After(before) {
		t.Fatalf("成功重复上传必须刷新临时保留窗口: created_at=%v", grant.CreatedAt)
	}
	if err := db.First(&file, file.ID).Error; err != nil {
		t.Fatal(err)
	}
	if file.Status != models.FileStatusTemporary || file.AccessScope != models.FileAccessPrivate || !file.CreatedAt.Equal(old) {
		t.Fatalf("刷新授权不应发布图片或重写创建时间: file=%+v", file)
	}
	if err := db.Model(&file).Update("status", models.FileStatusDeleting).Error; err != nil {
		t.Fatal(err)
	}
	if err := NewUploadHandler(t.TempDir(), 10<<20, db).grantFileToUser(file.ID, 1); err == nil {
		t.Fatal("deleting文件不得通过续期重新取得授权")
	}
}
