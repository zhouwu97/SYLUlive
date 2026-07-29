package handlers

import (
	"bytes"
	"fmt"
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

func TestServeStickerReturnsNotModifiedForMatchingETag(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/stickers/:id", ServeSticker)

	const validID = "0cc4a3688e7b222b977fef3a078619b6"
	request := httptest.NewRequest(http.MethodGet, "/stickers/"+validID, nil)
	request.Header.Set("If-None-Match", `"sticker-`+validID+`"`)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)

	if response.Code != http.StatusNotModified {
		t.Fatalf("status=%d body_bytes=%d", response.Code, response.Body.Len())
	}
	if response.Body.Len() != 0 {
		t.Fatalf("304 body_bytes=%d", response.Body.Len())
	}
	if response.Header().Get("ETag") != `"sticker-`+validID+`"` {
		t.Fatalf("etag=%q", response.Header().Get("ETag"))
	}
}

func TestServeStickerHeadReturnsMetadataWithoutBody(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/stickers/:id", ServeSticker)
	router.HEAD("/stickers/:id", ServeSticker)

	const validID = "0cc4a3688e7b222b977fef3a078619b6"
	getResponse := httptest.NewRecorder()
	router.ServeHTTP(
		getResponse,
		httptest.NewRequest(http.MethodGet, "/stickers/"+validID, nil),
	)
	headResponse := httptest.NewRecorder()
	router.ServeHTTP(
		headResponse,
		httptest.NewRequest(http.MethodHead, "/stickers/"+validID, nil),
	)

	if headResponse.Code != http.StatusOK {
		t.Fatalf("status=%d", headResponse.Code)
	}
	if headResponse.Body.Len() != 0 {
		t.Fatalf("head body_bytes=%d", headResponse.Body.Len())
	}
	if got, want := headResponse.Header().Get("Content-Length"), fmt.Sprint(getResponse.Body.Len()); got != want {
		t.Fatalf("content-length=%q want=%q", got, want)
	}
	if headResponse.Header().Get("Content-Type") != "image/gif" {
		t.Fatalf("content-type=%q", headResponse.Header().Get("Content-Type"))
	}
}
