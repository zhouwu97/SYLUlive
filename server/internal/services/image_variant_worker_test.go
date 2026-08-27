package services

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func newImageVariantTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := "file:" + strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name()) + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.File{}, &models.ImageVariant{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func createPublicVariantFile(t *testing.T, db *gorm.DB, uploadDir, name, mimeType string) models.File {
	t.Helper()
	file := models.File{
		Hash:        "variant-" + strings.ReplaceAll(t.Name()+name, "/", "-"),
		Path:        "/uploads/" + name,
		MimeType:    mimeType,
		AccessScope: models.FileAccessPublic,
		Status:      "active",
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	return file
}

func readImageConfig(t *testing.T, filename string) (image.Config, string) {
	t.Helper()
	input, err := os.Open(filename)
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	config, format, err := image.DecodeConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	return config, format
}

func TestImageVariantWorkerGeneratesJPEGVariantsAtomically(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "photo.jpg", "image/jpeg")
	source := image.NewRGBA(image.Rect(0, 0, 1600, 800))
	for y := 0; y < 800; y++ {
		for x := 0; x < 1600; x++ {
			source.SetRGBA(x, y, color.RGBA{R: uint8(x % 255), G: uint8(y % 255), B: 90, A: 255})
		}
	}
	output, err := os.Create(filepath.Join(uploadDir, "photo.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(output, source, &jpeg.Options{Quality: 94}); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}

	worker := NewImageVariantWorker(db, uploadDir)
	for range 2 {
		worked, err := worker.ProcessNext(context.Background())
		if err != nil || !worked {
			t.Fatalf("worker 未处理任务: worked=%v err=%v", worked, err)
		}
	}
	var variants []models.ImageVariant
	if err := db.Where("file_id = ?", file.ID).Order("variant ASC").Find(&variants).Error; err != nil {
		t.Fatal(err)
	}
	if len(variants) != 2 {
		t.Fatalf("变体数量=%d", len(variants))
	}
	for _, variant := range variants {
		if variant.Status != models.ImageVariantStatusReady || variant.MimeType != "image/jpeg" || variant.Size <= 0 {
			t.Fatalf("变体未完成: %+v", variant)
		}
		config, format := readImageConfig(t, filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/")))
		if format != "jpeg" {
			t.Fatalf("变体格式=%q", format)
		}
		if variant.Variant == ImageVariantThumb && (config.Width != 480 || config.Height != 240) {
			t.Fatalf("thumb 尺寸=%dx%d", config.Width, config.Height)
		}
		if variant.Variant == ImageVariantMedium && (config.Width != 1280 || config.Height != 640) {
			t.Fatalf("medium 尺寸=%dx%d", config.Width, config.Height)
		}
		quality := 80
		if variant.Variant == ImageVariantMedium {
			quality = 84
		}
		encoded, err := os.ReadFile(filepath.Join(uploadDir, strings.TrimPrefix(variant.Path, "/uploads/")))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Contains(encoded, jpegQuantizationTables(t, quality)) {
			t.Fatalf("%s 未使用 JPEG Q%d", variant.Variant, quality)
		}
	}
	entries, err := os.ReadDir(uploadDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".image-variant-") {
			t.Fatalf("不应遗留临时文件: %s", entry.Name())
		}
	}
}

func TestImageVariantWorkerPreservesTransparentPNG(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "alpha.png", "image/png")
	source := image.NewNRGBA(image.Rect(0, 0, 960, 480))
	for y := 0; y < 480; y++ {
		for x := 0; x < 960; x++ {
			source.SetNRGBA(x, y, color.NRGBA{R: 20, G: 160, B: 230, A: uint8(x % 220)})
		}
	}
	output, err := os.Create(filepath.Join(uploadDir, "alpha.png"))
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(output, source); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	for range 2 {
		if _, err := worker.ProcessNext(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	var thumb models.ImageVariant
	if err := db.Where("file_id = ? AND variant = ?", file.ID, ImageVariantThumb).First(&thumb).Error; err != nil {
		t.Fatal(err)
	}
	config, format := readImageConfig(t, filepath.Join(uploadDir, strings.TrimPrefix(thumb.Path, "/uploads/")))
	if format != "png" || config.Width != 480 || config.Height != 240 {
		t.Fatalf("PNG 变体格式或尺寸错误: format=%s size=%dx%d", format, config.Width, config.Height)
	}
	decoded, err := os.Open(filepath.Join(uploadDir, strings.TrimPrefix(thumb.Path, "/uploads/")))
	if err != nil {
		t.Fatal(err)
	}
	defer decoded.Close()
	imageValue, err := png.Decode(decoded)
	if err != nil {
		t.Fatal(err)
	}
	if alpha := color.NRGBAModel.Convert(imageValue.At(240, 120)).(color.NRGBA).A; alpha == 255 {
		t.Fatal("透明 PNG 变体丢失 alpha 通道")
	}
}

func TestImageVariantWorkerSkipsUnsupportedGIF(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "motion.gif", "image/gif")
	frame := image.NewPaletted(image.Rect(0, 0, 32, 32), color.Palette{color.Transparent, color.RGBA{R: 255, A: 255}})
	if err := gif.EncodeAll(mustCreateFile(t, filepath.Join(uploadDir, "motion.gif")), &gif.GIF{Image: []*image.Paletted{frame}, Delay: []int{1}}); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	worked, err := worker.ProcessNext(context.Background())
	if err != nil || worked {
		t.Fatalf("GIF 不应被 worker 领取: worked=%v err=%v", worked, err)
	}
	var variants []models.ImageVariant
	if err := db.Where("file_id = ?", file.ID).Find(&variants).Error; err != nil {
		t.Fatal(err)
	}
	for _, variant := range variants {
		if variant.Status != models.ImageVariantStatusUnsupported {
			t.Fatalf("GIF 状态=%q", variant.Status)
		}
	}
}

func TestImageVariantWorkerRetriesMissingSourceWithBackoff(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "missing.jpg", "image/jpeg")
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	worker := NewImageVariantWorker(db, uploadDir)
	worker.maxAttempts = 2
	worked, err := worker.ProcessNext(context.Background())
	if err != nil || !worked {
		t.Fatalf("首次失败任务未处理: worked=%v err=%v", worked, err)
	}
	var variant models.ImageVariant
	if err := db.Where("file_id = ? AND variant = ?", file.ID, ImageVariantThumb).First(&variant).Error; err != nil {
		t.Fatal(err)
	}
	if variant.Status != models.ImageVariantStatusFailed || variant.Attempts != 1 || variant.NextAttemptAt == nil || variant.LastError == "" {
		t.Fatalf("首次失败状态错误: %+v", variant)
	}
	past := time.Now().Add(-time.Second)
	if err := db.Model(&models.ImageVariant{}).Where("id = ?", variant.ID).Update("next_attempt_at", &past).Error; err != nil {
		t.Fatal(err)
	}
	worked, err = worker.ProcessNext(context.Background())
	if err != nil || !worked {
		t.Fatalf("第二次失败任务未处理: worked=%v err=%v", worked, err)
	}
	var finalVariant models.ImageVariant
	if err := db.First(&finalVariant, variant.ID).Error; err != nil {
		t.Fatal(err)
	}
	if finalVariant.Status != models.ImageVariantStatusFailed || finalVariant.Attempts != 2 || finalVariant.NextAttemptAt != nil {
		t.Fatalf("达到最大次数后的状态错误: %+v", finalVariant)
	}
}

func TestImageVariantWorkerConcurrentClaimOnlyProcessesOnce(t *testing.T) {
	db := newImageVariantTestDB(t)
	uploadDir := t.TempDir()
	file := createPublicVariantFile(t, db, uploadDir, "concurrent.jpg", "image/jpeg")
	output, err := os.Create(filepath.Join(uploadDir, "concurrent.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(output, image.NewRGBA(image.Rect(0, 0, 64, 32)), nil); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	if err := CreatePublicImageVariantTasks(db, []uint{file.ID}); err != nil {
		t.Fatal(err)
	}
	if err := db.Where("file_id = ? AND variant = ?", file.ID, ImageVariantMedium).Delete(&models.ImageVariant{}).Error; err != nil {
		t.Fatal(err)
	}
	workerA := NewImageVariantWorker(db, uploadDir)
	workerB := NewImageVariantWorker(db, uploadDir)
	var group sync.WaitGroup
	results := make(chan struct {
		worked bool
		err    error
	}, 2)
	for _, worker := range []*ImageVariantWorker{workerA, workerB} {
		group.Add(1)
		go func(worker *ImageVariantWorker) {
			defer group.Done()
			worked, err := worker.ProcessNext(context.Background())
			results <- struct {
				worked bool
				err    error
			}{worked: worked, err: err}
		}(worker)
	}
	group.Wait()
	close(results)
	processed := 0
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		if result.worked {
			processed++
		}
	}
	if processed != 1 {
		t.Fatalf("并发领取次数=%d，期望 1", processed)
	}
	var variant models.ImageVariant
	if err := db.Where("file_id = ? AND variant = ?", file.ID, ImageVariantThumb).First(&variant).Error; err != nil {
		t.Fatal(err)
	}
	if variant.Status != models.ImageVariantStatusReady || variant.Attempts != 1 {
		t.Fatalf("并发任务状态错误: %+v", variant)
	}
}

func mustCreateFile(t *testing.T, filename string) *os.File {
	t.Helper()
	file, err := os.Create(filename)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = file.Close() })
	return file
}

func jpegQuantizationTables(t *testing.T, quality int) []byte {
	t.Helper()
	var output bytes.Buffer
	if err := jpeg.Encode(&output, image.NewRGBA(image.Rect(0, 0, 1, 1)), &jpeg.Options{Quality: quality}); err != nil {
		t.Fatal(err)
	}
	data := output.Bytes()
	start := bytes.Index(data, []byte{0xff, 0xdb})
	if start < 0 {
		t.Fatal("参考 JPEG 缺少量化表")
	}
	end := start
	for end+4 <= len(data) && data[end] == 0xff && data[end+1] == 0xdb {
		length := int(data[end+2])<<8 | int(data[end+3])
		end += 2 + length
	}
	return data[start:end]
}
