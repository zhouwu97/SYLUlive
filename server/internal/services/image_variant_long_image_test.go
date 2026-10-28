package services

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"shenliyuan/internal/models"
)

func TestLongImageVariantBudgetsPreserveReadingWidthAndOrientation(t *testing.T) {
	for _, variant := range []struct {
		name         string
		minimumWidth int
		maxPixels    int64
	}{
		{ImageVariantThumb, 300, 1_500_000},
		{ImageVariantMedium, 600, 5_000_000},
		{ImageVariantViewer, 900, 10_000_000},
	} {
		t.Run(variant.name, func(t *testing.T) {
			maxDimension, _, _ := imageVariantRecipe(variant.name)
			width, height := imageVariantSize(1080, 12000, maxDimension, variant.name)
			if width < variant.minimumWidth || height <= maxDimension || int64(width)*int64(height) > variant.maxPixels {
				t.Fatalf("长截图需要可读宽度和有界像素: size=%dx%d", width, height)
			}
			landscapeWidth, landscapeHeight := imageVariantSize(12000, 1080, maxDimension, variant.name)
			if landscapeWidth != height || landscapeHeight != width {
				t.Fatalf("横向长图应使用相同比例: portrait=%dx%d landscape=%dx%d", width, height, landscapeWidth, landscapeHeight)
			}
			smallWidth, smallHeight := imageVariantSize(100, 400, maxDimension, variant.name)
			if smallWidth != 100 || smallHeight != 400 {
				t.Fatalf("不应放大小图: size=%dx%d", smallWidth, smallHeight)
			}
		})
	}
}

func TestImageVariantWorkerPreservesLongTransparentScreenshot(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "long-alpha.png", "image/png")
	file.Width, file.Height = 720, 3600
	if err := db.Save(&file).Error; err != nil {
		t.Fatal(err)
	}
	source := image.NewNRGBA(image.Rect(0, 0, file.Width, file.Height))
	for y := 0; y < file.Height; y++ {
		for x := 0; x < file.Width; x++ {
			// 透明底上的文字行状图案，验证缩放时不会丢失 alpha。
			if y%24 < 16 && x%12 < 8 {
				source.SetNRGBA(x, y, color.NRGBA{R: 30, G: 60, B: 90, A: 170})
			}
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, source); err != nil {
		t.Fatal(err)
	}
	sourcePath := filepath.Join(uploadDir, "long-alpha.png")
	if err := os.WriteFile(sourcePath, encoded.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	for range 3 {
		if worked, err := worker.ProcessNext(context.Background()); err != nil || !worked {
			t.Fatalf("长截图变体应全部完成: worked=%v err=%v", worked, err)
		}
	}
	var variants []models.ImageVariant
	if err := db.Where("file_id = ?", file.ID).Find(&variants).Error; err != nil {
		t.Fatal(err)
	}
	if len(variants) != 3 {
		t.Fatalf("大图应有三个变体: got=%d", len(variants))
	}
	for _, variant := range variants {
		input, err := os.Open(filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/")))
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := png.Decode(input)
		_ = input.Close()
		if err != nil || variant.Status != models.ImageVariantStatusReady {
			t.Fatalf("长图PNG应可解码且ready: variant=%+v err=%v", variant, err)
		}
		minimumWidth := 720
		if variant.Variant == ImageVariantThumb {
			minimumWidth = 320
		}
		if decoded.Bounds().Dx() < minimumWidth || decoded.Bounds().Dy() < 5*minimumWidth {
			t.Fatalf("不应把长截图文字缩成窄条: variant=%s bounds=%v", variant.Variant, decoded.Bounds())
		}
		if alpha := color.NRGBAModel.Convert(decoded.At(0, 0)).(color.NRGBA).A; alpha == 0 || alpha == 255 {
			t.Fatalf("PNG应保留半透明像素: variant=%s alpha=%d", variant.Variant, alpha)
		}
	}
	after, err := os.ReadFile(sourcePath)
	if err != nil || !bytes.Equal(after, encoded.Bytes()) {
		t.Fatalf("生成预览不得修改保留原图: err=%v", err)
	}
}

func TestImageVariantWorkerRejectsOversizedLegacySource(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "oversized-legacy.png", "image/png")
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, image.NewNRGBA(image.Rect(0, 0, ImageMaxDimension+1, 2))); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "oversized-legacy.png"), encoded.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	if worked, err := NewImageVariantWorker(db, uploadDir).ProcessNext(context.Background()); err != nil || !worked {
		t.Fatalf("越界历史图任务应记录失败: worked=%v err=%v", worked, err)
	}
	var variant models.ImageVariant
	if err := db.Where("file_id = ? AND variant = ?", file.ID, ImageVariantThumb).First(&variant).Error; err != nil {
		t.Fatal(err)
	}
	if variant.Status != models.ImageVariantStatusFailed || !strings.Contains(variant.LastError, "分辨率超出安全范围") {
		t.Fatalf("越界源图不得进入ready: variant=%+v", variant)
	}
	if _, err := os.Stat(filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/"))); !os.IsNotExist(err) {
		t.Fatalf("越界源图不得发布变体: err=%v", err)
	}
}
