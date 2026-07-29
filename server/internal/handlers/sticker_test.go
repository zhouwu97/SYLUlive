package handlers

import (
	"bytes"
	"image/gif"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestServeStickerUsesCatalogWhitelistAndImmutableCache(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/stickers/:id", ServeSticker)

	validID := "0cc4a3688e7b222b977fef3a078619b6"
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/stickers/"+validID, nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if response.Header().Get("Content-Type") != "image/gif" {
		t.Fatalf("content-type=%q", response.Header().Get("Content-Type"))
	}
	if response.Header().Get("Cache-Control") != "public, max-age=31536000, immutable" {
		t.Fatalf("cache-control=%q", response.Header().Get("Cache-Control"))
	}
	if body := response.Body.Bytes(); len(body) < 6 || string(body[:6]) != "GIF89a" {
		t.Fatal("动态表情不是有效的 GIF89a 文件")
	}
	decoded, err := gif.DecodeAll(bytes.NewReader(response.Body.Bytes()))
	if err != nil {
		t.Fatalf("动态表情解码失败: %v", err)
	}
	if decoded.Config.Width != 300 || decoded.Config.Height != 300 {
		t.Fatalf("动态表情尺寸=%dx%d", decoded.Config.Width, decoded.Config.Height)
	}
	if len(decoded.Image) < 2 {
		t.Fatalf("动态表情帧数=%d", len(decoded.Image))
	}

	missing := httptest.NewRecorder()
	router.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/stickers/not-found", nil))
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing status=%d", missing.Code)
	}
}
