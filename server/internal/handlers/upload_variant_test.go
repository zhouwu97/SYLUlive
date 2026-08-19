package handlers

import (
	"bytes"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureImageVariantResizesAndCaches(t *testing.T) {
	root := t.TempDir()
	original := filepath.Join(root, "source.jpg")
	file, err := os.Create(original)
	if err != nil {
		t.Fatal(err)
	}
	source := image.NewRGBA(image.Rect(0, 0, 1600, 800))
	for y := 0; y < 800; y++ {
		for x := 0; x < 1600; x++ {
			source.Set(x, y, color.RGBA{R: 24, G: 96, B: 180, A: 255})
		}
	}
	if err := jpeg.Encode(file, source, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	thumb := filepath.Join(root, "source_thumb.jpg")
	if err := ensureImageVariant(original, thumb, "image/jpeg", 480); err != nil {
		t.Fatal(err)
	}
	thumbFile, err := os.Open(thumb)
	if err != nil {
		t.Fatal(err)
	}
	defer thumbFile.Close()
	config, _, err := image.DecodeConfig(thumbFile)
	if err != nil {
		t.Fatal(err)
	}
	if config.Width != 480 || config.Height != 240 {
		t.Fatalf("缩略图尺寸=%dx%d, want 480x240", config.Width, config.Height)
	}

	// 已存在的变体应直接复用，不重复写文件。
	before, err := os.Stat(thumb)
	if err != nil {
		t.Fatal(err)
	}
	if err := ensureImageVariant(original, thumb, "image/jpeg", 480); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(thumb)
	if err != nil {
		t.Fatal(err)
	}
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("缓存命中时不应重写缩略图")
	}
}

func TestImageVariantRequest(t *testing.T) {
	variant, original := imageVariantRequest("ab/hash_medium.png")
	if variant != "medium" || original != "ab/hash.png" {
		t.Fatalf("variant=%q original=%q", variant, original)
	}
	variant, original = imageVariantRequest("ab/hash.png")
	if variant != "" || original != "ab/hash.png" {
		t.Fatalf("原图解析错误: variant=%q original=%q", variant, original)
	}
}

func TestEnsureImageVariantSupportsGifFirstFrame(t *testing.T) {
	root := t.TempDir()
	original := filepath.Join(root, "source.gif")
	file, err := os.Create(original)
	if err != nil {
		t.Fatal(err)
	}
	frame := image.NewPaletted(image.Rect(0, 0, 800, 400), []color.Color{color.RGBA{R: 255, A: 255}})
	if err := gif.EncodeAll(file, &gif.GIF{Image: []*image.Paletted{frame}, Delay: []int{1}}); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	variant := filepath.Join(root, "source_thumb.gif")
	if err := ensureImageVariant(original, variant, "image/gif", 480); err != nil {
		t.Fatal(err)
	}
	decoded, err := gif.Decode(bytes.NewReader(mustReadFile(t, variant)))
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Bounds().Dx() != 480 || decoded.Bounds().Dy() != 240 {
		t.Fatalf("GIF 缩略图尺寸=%v", decoded.Bounds())
	}
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
