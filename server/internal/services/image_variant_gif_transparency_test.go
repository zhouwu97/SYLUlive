package services

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/gif"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"
)

func TestImageVariantWorkerShowsGIFWithSparseOpeningFrame(t *testing.T) {
	source, err := os.ReadFile("../handlers/sticker_assets/4093d7cdb944076e0a8e4e06be2e2776.gif")
	if err != nil {
		t.Fatal(err)
	}
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "sparse-opening.gif", "image/gif")
	if err := os.WriteFile(filepath.Join(uploadDir, "sparse-opening.gif"), source, 0600); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	worked, err := worker.ProcessNext(context.Background())
	if err != nil || !worked {
		t.Fatalf("GIF 变体处理失败: worked=%v err=%v", worked, err)
	}
	var variant models.ImageVariant
	if err := db.Where("file_id = ? AND status = ?", file.ID, models.ImageVariantStatusReady).First(&variant).Error; err != nil {
		t.Fatal(err)
	}
	previewBytes, err := os.ReadFile(filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/")))
	if err != nil {
		t.Fatal(err)
	}
	preview, _, err := image.Decode(bytes.NewReader(previewBytes))
	if err != nil {
		t.Fatal(err)
	}
	if preview.Bounds() != image.Rect(0, 0, 300, 300) {
		t.Fatalf("变体没有保留 GIF 逻辑画布: %v", preview.Bounds())
	}
	visible := 0
	for y := 0; y < 300; y++ {
		for x := 0; x < 300; x++ {
			_, _, _, alpha := preview.At(x, y).RGBA()
			if alpha > 0 {
				visible++
			}
		}
	}
	if visible < 20000 {
		t.Fatalf("稀疏开场的静态预览仍然几乎空白: %d 像素", visible)
	}
}

func TestGIFSamplingBudgetRejectsTooManyFramesAndTruncatedData(t *testing.T) {
	frame := image.NewPaletted(image.Rect(0, 0, 1, 1), color.Palette{color.Transparent, color.White})
	animation := &gif.GIF{}
	for range 65 {
		animation.Image = append(animation.Image, frame)
		animation.Delay = append(animation.Delay, 1)
	}
	var encoded bytes.Buffer
	if err := gif.EncodeAll(&encoded, animation); err != nil {
		t.Fatal(err)
	}
	if gifSamplingWithinBudget(encoded.Bytes(), 1, 1) {
		t.Fatal("不能对超过预算的动画执行全帧解码")
	}
	actual, err := os.ReadFile("../handlers/sticker_assets/4093d7cdb944076e0a8e4e06be2e2776.gif")
	if err != nil {
		t.Fatal(err)
	}
	if !gifSamplingWithinBudget(actual, 300, 300) {
		t.Fatal("合法的 62 帧表情应在预算内")
	}
	if gifSamplingWithinBudget(actual[:len(actual)-100], 300, 300) {
		t.Fatal("截断的 GIF 不应进入全帧解码")
	}
}

func TestImageVariantPreservesGIFLogicalCanvasForOffsetFrame(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "offset.gif", "image/gif")
	frame := image.NewPaletted(image.Rect(7, 8, 9, 10), color.Palette{color.Transparent, color.White})
	for y := 8; y < 10; y++ {
		for x := 7; x < 9; x++ {
			frame.SetColorIndex(x, y, 1)
		}
	}
	var encoded bytes.Buffer
	if err := gif.EncodeAll(&encoded, &gif.GIF{Image: []*image.Paletted{frame}, Delay: []int{1}, Config: image.Config{Width: 10, Height: 10}}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "offset.gif"), encoded.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	if worked, err := worker.ProcessNext(context.Background()); !worked || err != nil {
		t.Fatalf("变体处理失败: %v", err)
	}
	var variant models.ImageVariant
	if err := db.Where("file_id = ? AND status = ?", file.ID, models.ImageVariantStatusReady).First(&variant).Error; err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/")))
	if err != nil {
		t.Fatal(err)
	}
	preview, _, err := image.Decode(bytes.NewReader(data))
	if err != nil || preview.Bounds() != image.Rect(0, 0, 10, 10) {
		t.Fatalf("逻辑画布错误: image=%v err=%v", preview, err)
	}
	_, _, _, blank := preview.At(0, 0).RGBA()
	_, _, _, pixel := preview.At(8, 9).RGBA()
	if blank != 0 || pixel == 0 {
		t.Fatalf("局部帧偏移或透明度错误: blank=%d pixel=%d", blank, pixel)
	}
}

func TestImageVariantWorkerPreservesGIFTransparency(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "transparent.gif", "image/gif")
	frame := image.NewPaletted(image.Rect(0, 0, 960, 480), color.Palette{
		color.Transparent, color.NRGBA{R: 240, G: 80, B: 30, A: 255},
	})
	for y := 200; y < 280; y++ {
		for x := 430; x < 530; x++ {
			frame.SetColorIndex(x, y, 1)
		}
	}
	source, err := os.Create(filepath.Join(uploadDir, "transparent.gif"))
	if err != nil {
		t.Fatal(err)
	}
	if err := gif.EncodeAll(source, &gif.GIF{Image: []*image.Paletted{frame}, Delay: []int{1}}); err != nil {
		t.Fatal(err)
	}
	if err := source.Close(); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	for range 2 {
		worked, err := worker.ProcessNext(context.Background())
		if err != nil || !worked {
			t.Fatalf("GIF 变体处理失败: worked=%v err=%v", worked, err)
		}
	}
	var variants []models.ImageVariant
	if err := db.Where("file_id = ?", file.ID).Find(&variants).Error; err != nil {
		t.Fatal(err)
	}
	if len(variants) != 2 {
		t.Fatalf("GIF 变体数量=%d", len(variants))
	}
	for _, variant := range variants {
		if variant.Status != models.ImageVariantStatusReady {
			t.Fatalf("GIF 变体未就绪: %+v", variant)
		}
		input, err := os.Open(filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/")))
		if err != nil {
			t.Fatal(err)
		}
		preview, format, err := image.Decode(input)
		_ = input.Close()
		if err != nil {
			t.Fatal(err)
		}
		if format != "png" || variant.MimeType != "image/png" || !strings.Contains(variant.Path, "_v2_") {
			t.Errorf("%s 变体格式或地址错误: format=%s mime=%s path=%s", variant.Variant, format, variant.MimeType, variant.Path)
		}
		if alpha := color.NRGBAModel.Convert(preview.At(0, 0)).(color.NRGBA).A; alpha != 0 {
			t.Errorf("%s 变体透明区域丢失: format=%s alpha=%d", variant.Variant, format, alpha)
		}
		bounds := preview.Bounds()
		if alpha := color.NRGBAModel.Convert(preview.At(bounds.Dx()/2, bounds.Dy()/2)).(color.NRGBA).A; alpha != 255 {
			t.Errorf("%s 变体的不透明像素被破坏: alpha=%d", variant.Variant, alpha)
		}
	}
}

func TestGIFVariantRecoversAfterMissingOriginal(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "retry.gif", "image/gif")
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	worked, err := worker.ProcessNext(context.Background())
	if err != nil || !worked {
		t.Fatalf("未处理缺失原图的任务: worked=%v err=%v", worked, err)
	}
	var failed models.ImageVariant
	if err := db.Where("file_id = ? AND status = ?", file.ID, models.ImageVariantStatusFailed).First(&failed).Error; err != nil {
		t.Fatal(err)
	}
	if failed.NextAttemptAt == nil {
		t.Fatal("缺失原图时应安排重试")
	}
	frame := image.NewPaletted(image.Rect(0, 0, 16, 16), color.Palette{color.Transparent, color.White})
	output, err := os.Create(filepath.Join(uploadDir, "retry.gif"))
	if err != nil {
		t.Fatal(err)
	}
	if err := gif.Encode(output, frame, nil); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&failed).Update("next_attempt_at", time.Now().Add(-time.Second)).Error; err != nil {
		t.Fatal(err)
	}
	for range 2 {
		worked, err := worker.ProcessNext(context.Background())
		if err != nil || !worked {
			t.Fatalf("恢复后的任务未处理: worked=%v err=%v", worked, err)
		}
	}
	if err := db.First(&failed, failed.ID).Error; err != nil {
		t.Fatal(err)
	}
	if failed.Status != models.ImageVariantStatusReady || failed.Attempts != 2 || failed.MimeType != "image/png" {
		t.Fatalf("GIF 变体未恢复: %+v", failed)
	}
}

func TestGIFVariantBackfillRecoversOnlyOldWorkerMimeFailure(t *testing.T) {
	db := newImageVariantTestDB(t)
	file := createPublicVariantFile(t, db, t.TempDir(), "rollback.gif", "image/gif")
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&models.ImageVariant{}).
		Where("file_id = ? AND variant = ?", file.ID, ImageVariantThumb).
		Updates(map[string]interface{}{
			"status": models.ImageVariantStatusFailed, "attempts": 3,
			"next_attempt_at": nil, "last_error": "原图/变体 MIME 与任务不一致",
		}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&models.ImageVariant{}).
		Where("file_id = ? AND variant = ?", file.ID, ImageVariantMedium).
		Updates(map[string]interface{}{
			"status": models.ImageVariantStatusFailed, "attempts": 3,
			"next_attempt_at": nil, "last_error": "读取原图失败",
		}).Error; err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	var variants []models.ImageVariant
	if err := db.Where("file_id = ?", file.ID).Find(&variants).Error; err != nil {
		t.Fatal(err)
	}
	if len(variants) != 2 {
		t.Fatalf("任务数量=%d", len(variants))
	}
	for _, variant := range variants {
		switch variant.Variant {
		case ImageVariantThumb:
			if variant.Status != models.ImageVariantStatusPending || variant.Attempts != 0 || variant.LastError != "" {
				t.Fatalf("旧 worker 造成的终态失败未恢复: %+v", variant)
			}
		case ImageVariantMedium:
			if variant.Status != models.ImageVariantStatusFailed || variant.Attempts != 3 || variant.LastError != "读取原图失败" {
				t.Fatalf("不相关的失败不应重置: %+v", variant)
			}
		}
	}
}
