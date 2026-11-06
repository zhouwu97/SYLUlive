package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/gif"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestReplyGIFPreviewBackfillAndServing(t *testing.T) {
	// 使用仓库内的真实透明动图，覆盖多帧素材而不依赖用户本机目录。
	original, err := stickerAssetFS.ReadFile("sticker_assets/0cc4a3688e7b222b977fef3a078619b6.gif")
	require.NoError(t, err)
	firstFrame, err := gif.Decode(bytes.NewReader(original))
	require.NoError(t, err)
	var transparent image.Point
	found := false
	for y := firstFrame.Bounds().Min.Y; y < firstFrame.Bounds().Max.Y && !found; y++ {
		for x := firstFrame.Bounds().Min.X; x < firstFrame.Bounds().Max.X; x++ {
			if _, _, _, alpha := firstFrame.At(x, y).RGBA(); alpha == 0 {
				transparent, found = image.Pt(x, y), true
				break
			}
		}
	}
	require.True(t, found, "测试 GIF 首帧需要包含透明像素")
	require.LessOrEqual(t, firstFrame.Bounds().Dx(), services.ImageVariantThumbMaxDimension)
	require.LessOrEqual(t, firstFrame.Bounds().Dy(), services.ImageVariantThumbMaxDimension)

	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	uploadDir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(uploadDir, "transparent.gif"), original, 0o600))
	file := models.File{Hash: "transparent-gif", Path: "/uploads/transparent.gif", Size: int64(len(original)), MimeType: "image/gif", Status: models.FileStatusActive, AccessScope: models.FileAccessPublic}
	require.NoError(t, db.Create(&file).Error)
	reply := models.Reply{PostID: post.ID, AuthorID: 1, Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&reply).Error)
	require.NoError(t, db.Create(&models.ReplyImage{ReplyID: reply.ID, FileID: file.ID}).Error)
	old := models.ImageVariant{FileID: file.ID, Variant: "thumb", RecipeVersion: 1, Status: models.ImageVariantStatusPending, Path: "/uploads/transparent_v1_thumb.jpg", MimeType: "image/jpeg"}
	require.NoError(t, db.Create(&old).Error)

	// 启动回填可重复执行，历史任务保留给旧版本回滚。
	require.NoError(t, services.BackfillPublicImageVariantTasks(db))
	require.NoError(t, services.BackfillPublicImageVariantTasks(db))
	var count int64
	require.NoError(t, db.Model(&models.ImageVariant{}).Where("file_id = ?", file.ID).Count(&count).Error)
	require.EqualValues(t, 3, count)

	listImage := func() struct {
		ThumbURL  string            `json:"thumb_url"`
		OriginURL string            `json:"origin_url"`
		Status    map[string]string `json:"variant_status"`
	} {
		t.Helper()
		response := performReplyListRequest(t, db, post.ID, "", 0)
		require.Equal(t, http.StatusOK, response.Code, response.Body.String())
		var body struct {
			Replies []struct {
				Images []struct {
					ThumbURL  string            `json:"thumb_url"`
					OriginURL string            `json:"origin_url"`
					Status    map[string]string `json:"variant_status"`
				} `json:"images"`
			} `json:"replies"`
		}
		require.NoError(t, json.Unmarshal(response.Body.Bytes(), &body))
		require.Len(t, body.Replies, 1)
		require.Len(t, body.Replies[0].Images, 1)
		return body.Replies[0].Images[0]
	}
	before := listImage()
	require.Equal(t, file.Path, before.ThumbURL)
	require.Equal(t, "pending", before.Status["thumb"])

	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/uploads/*filepath", NewUploadHandler(uploadDir, 10<<20, db).ServePublic)
	request := func(path string) *httptest.ResponseRecorder {
		t.Helper()
		response := httptest.NewRecorder()
		router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		return response
	}
	legacy := request(old.Path)
	require.Equal(t, http.StatusOK, legacy.Code)
	require.Equal(t, "image/gif", legacy.Header().Get("Content-Type"))
	require.Equal(t, "no-store", legacy.Header().Get("Cache-Control"))
	require.Equal(t, original, legacy.Body.Bytes())
	require.Equal(t, http.StatusNotFound, request("/uploads/transparent_v2_thumb.png").Code)

	worker := services.NewImageVariantWorker(db, uploadDir)
	for range 2 {
		worked, err := worker.ProcessNext(context.Background())
		require.NoError(t, err)
		require.True(t, worked)
	}
	var oldAfter models.ImageVariant
	require.NoError(t, db.First(&oldAfter, old.ID).Error)
	require.Equal(t, models.ImageVariantStatusPending, oldAfter.Status)
	updated := listImage()
	require.Equal(t, "/uploads/transparent_v2_thumb.png", updated.ThumbURL)
	require.Equal(t, file.Path, updated.OriginURL)
	require.Equal(t, "ready", updated.Status["thumb"])
	preview := request(updated.ThumbURL)
	require.Equal(t, http.StatusOK, preview.Code)
	require.Equal(t, "image/png", preview.Header().Get("Content-Type"))
	decoded, err := png.Decode(bytes.NewReader(preview.Body.Bytes()))
	require.NoError(t, err)
	_, _, _, alpha := decoded.At(transparent.X-firstFrame.Bounds().Min.X, transparent.Y-firstFrame.Bounds().Min.Y).RGBA()
	require.Zero(t, alpha)
	legacy = request(old.Path)
	require.Equal(t, http.StatusOK, legacy.Code)
	require.Equal(t, "image/png", legacy.Header().Get("Content-Type"))
	require.Equal(t, "no-store", legacy.Header().Get("Cache-Control"))
	require.Equal(t, preview.Body.Bytes(), legacy.Body.Bytes())

	// 图片撤回后新旧地址都不能绕过公开权限。
	require.NoError(t, db.Model(&file).Update("access_scope", models.FileAccessPrivate).Error)
	require.Equal(t, http.StatusNotFound, request(updated.ThumbURL).Code)
	require.Equal(t, http.StatusNotFound, request(old.Path).Code)
}
