package handlers

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"

	"shenliyuan/internal/models"
)

// newPNGBytes 生成 width x height 的真实 PNG 内容。
func newPNGBytes(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

func TestValidateImageFileReturnsRealMimeAndDimensions(t *testing.T) {
	// PNG 内容即使被外部命名成 .jpg，也应检测出 image/png 与真实宽高。
	src := bytes.NewReader(newPNGBytes(t, 320, 480))
	meta, err := validateImageFile(src)
	if err != nil {
		t.Fatalf("validateImageFile: %v", err)
	}
	if meta.MimeType != "image/png" {
		t.Fatalf("mime type = %q, want image/png", meta.MimeType)
	}
	if meta.Width != 320 || meta.Height != 480 {
		t.Fatalf("dimensions = %dx%d, want 320x480", meta.Width, meta.Height)
	}
}

func TestCanonicalImageExtMapsDetectedMime(t *testing.T) {
	cases := map[string]string{
		"image/jpeg": ".jpg",
		"image/png":  ".png",
		"image/gif":  ".gif",
		"image/webp": ".jpg", // 未纳入支持的类型统一落到 .jpg
	}
	for mimeType, want := range cases {
		if got := canonicalImageExt(mimeType); got != want {
			t.Errorf("canonicalImageExt(%q) = %q, want %q", mimeType, got, want)
		}
	}
}

// 直接构造图片模型，验证 MessageFileDTO 会带出宽高（客户端据此按比例渲染）。
func TestPrivateMessageFileDTOCarriesDimensions(t *testing.T) {
	file := &models.File{
		ID:       7,
		MimeType: "image/png",
		Size:     123,
		Width:    1080,
		Height:   1440,
	}
	dto := privateMessageFileResponse(file)
	if dto == nil {
		t.Fatal("expected dto")
	}
	if dto.Width != 1080 || dto.Height != 1440 {
		t.Fatalf("dto dimensions = %dx%d, want 1080x1440", dto.Width, dto.Height)
	}
}
