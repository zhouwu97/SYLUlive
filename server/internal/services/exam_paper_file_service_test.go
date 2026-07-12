package services

import (
	"bytes"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/pdfcpu/pdfcpu/pkg/api"
	pdfmodel "github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func buildMinimalPDF() []byte {
	objects := []string{
		"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
		"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
		"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>\nendobj\n",
		"4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n",
	}

	var pdf bytes.Buffer
	pdf.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objects)+1)
	for index, object := range objects {
		offsets[index+1] = pdf.Len()
		pdf.WriteString(object)
	}
	xrefOffset := pdf.Len()
	pdf.WriteString(fmt.Sprintf("xref\n0 %d\n", len(objects)+1))
	pdf.WriteString("0000000000 65535 f \n")
	for index := 1; index <= len(objects); index++ {
		pdf.WriteString(fmt.Sprintf("%010d 00000 n \n", offsets[index]))
	}
	pdf.WriteString(fmt.Sprintf("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objects)+1, xrefOffset))
	return pdf.Bytes()
}

func multipartFileHeader(t *testing.T, filename string, content []byte) *multipart.FileHeader {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		t.Fatalf("创建 multipart 文件失败: %v", err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatalf("写入 multipart 文件失败: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("关闭 multipart 写入器失败: %v", err)
	}

	request := httptest.NewRequest("POST", "/upload", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	if err := request.ParseMultipartForm(int64(len(content)) + 1024); err != nil {
		t.Fatalf("解析 multipart 请求失败: %v", err)
	}
	_, header, err := request.FormFile("file")
	if err != nil {
		t.Fatalf("读取 multipart 文件失败: %v", err)
	}
	return header
}

func TestExamPaperFileServiceStoresValidatedPDFPrivately(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}

	stored, err := service.StoreUpload(multipartFileHeader(t, "期末试卷.pdf", buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存合法 PDF 失败: %v", err)
	}
	if stored.FileKey == "" || filepath.Base(stored.FileKey) != stored.FileKey {
		t.Fatalf("文件键必须是随机基础文件名: %q", stored.FileKey)
	}
	if stored.Size != int64(len(buildMinimalPDF())) {
		t.Fatalf("文件大小错误: %d", stored.Size)
	}
	if len(stored.SHA256) != 64 {
		t.Fatalf("SHA-256 长度错误: %q", stored.SHA256)
	}

	info, err := os.Stat(filepath.Join(root, stored.FileKey))
	if err != nil {
		t.Fatalf("私有文件不存在: %v", err)
	}
	if info.Size() != stored.Size {
		t.Fatalf("落盘文件大小错误: %d", info.Size())
	}
}

func TestExamPaperFileServiceRejectsInvalidAndOversizedFiles(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}

	tests := []struct {
		name     string
		filename string
		content  []byte
		wantErr  error
	}{
		{name: "扩展名非法", filename: "试卷.txt", content: buildMinimalPDF(), wantErr: ErrInvalidPDF},
		{name: "文件头非法", filename: "试卷.pdf", content: []byte("not a pdf"), wantErr: ErrInvalidPDF},
		{name: "PDF结构损坏", filename: "试卷.pdf", content: []byte("%PDF-garbage"), wantErr: ErrInvalidPDF},
		{name: "文件超限", filename: "试卷.pdf", content: append([]byte("%PDF-"), bytes.Repeat([]byte("x"), int(ExamPaperMaxFileSize))...), wantErr: ErrExamPaperFileTooLarge},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := service.StoreUpload(multipartFileHeader(t, tt.filename, tt.content))
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("错误类型不符: got=%v want=%v", err, tt.wantErr)
			}
		})
	}
}

func TestExamPaperFileServiceRejectsEncryptedPDF(t *testing.T) {
	plainPath := filepath.Join(t.TempDir(), "plain.pdf")
	encryptedPath := filepath.Join(t.TempDir(), "encrypted.pdf")
	if err := os.WriteFile(plainPath, buildMinimalPDF(), 0o600); err != nil {
		t.Fatalf("写入明文 PDF 失败: %v", err)
	}
	conf := pdfmodel.NewAESConfiguration("open-password", "owner-password", 256)
	if err := api.EncryptFile(plainPath, encryptedPath, conf); err != nil {
		t.Fatalf("写入明文 PDF 失败: %v", err)
	}
	encryptedBytes, err := os.ReadFile(encryptedPath)
	if err != nil {
		t.Fatalf("写入明文 PDF 失败: %v", err)
	}

	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	_, err = service.StoreUpload(multipartFileHeader(t, "加密试卷.pdf", encryptedBytes))
	if !errors.Is(err, ErrEncryptedPDF) {
		t.Fatalf("加密 PDF 应返回专用错误: %v", err)
	}
}

func TestExamPaperFileServiceTrashRecoveryUsesDatabaseState(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.ExamPaper{}); err != nil {
		t.Fatalf("迁移数据库失败: %v", err)
	}

	user := models.User{StudentID: "trash-user", PasswordHash: "test"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建用户失败: %v", err)
	}
	stored, err := service.StoreUpload(multipartFileHeader(t, "试卷.pdf", buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	paper := models.ExamPaper{
		Status: models.ExamPaperStatusPending, Source: models.ExamPaperSourceUser,
		SubmitterID: user.ID, CourseName: "高数", AcademicYear: "2025-2026",
		Semester: models.ExamPaperSemesterFirst, ExamType: models.ExamPaperTypeFinal,
		Title: "高数 · 2025-2026 · 第一学期 · 期末", FileKey: stored.FileKey,
		FileSize: stored.Size, SHA256: stored.SHA256,
	}
	if err := db.Create(&paper).Error; err != nil {
		t.Fatalf("创建试卷记录失败: %v", err)
	}

	move, err := service.StageDelete(stored.FileKey)
	if err != nil {
		t.Fatalf("暂存删除失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, stored.FileKey)); !os.IsNotExist(err) {
		t.Fatalf("源文件应已原子移动到垃圾目录: %v", err)
	}
	if err := service.RecoverTrash(db); err != nil {
		t.Fatalf("恢复垃圾目录失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, stored.FileKey)); err != nil {
		t.Fatalf("仍被引用的文件应恢复: %v", err)
	}
	if _, err := os.Stat(move.TrashPath); !os.IsNotExist(err) {
		t.Fatalf("恢复后垃圾文件应消失: %v", err)
	}

	move, err = service.StageDelete(stored.FileKey)
	if err != nil {
		t.Fatalf("再次暂存删除失败: %v", err)
	}
	if err := db.Model(&paper).Updates(map[string]any{
		"status":   models.ExamPaperStatusUnpublished,
		"file_key": "",
	}).Error; err != nil {
		t.Fatalf("更新试卷状态失败: %v", err)
	}
	if err := service.RecoverTrash(db); err != nil {
		t.Fatalf("清理垃圾目录失败: %v", err)
	}
	if _, err := os.Stat(move.TrashPath); !os.IsNotExist(err) {
		t.Fatalf("无引用垃圾文件应被清理: %v", err)
	}
}

func TestExamPaperFileServiceRejectsPathTraversal(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	if _, err := service.Open("../secret.pdf"); err == nil {
		t.Fatal("文件服务不得允许路径穿越")
	}
}

func TestPaperStoragePendingClaimAndTrashAreIdempotent(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	if err := service.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建待认领标记失败: %v", err)
	}
	if err := service.Claim(stored.FileKey); err != nil {
		t.Fatalf("认领文件失败: %v", err)
	}
	if err := service.Claim(stored.FileKey); err != nil {
		t.Fatalf("重复认领应成功: %v", err)
	}
	if err := service.Trash(stored.FileKey); err != nil {
		t.Fatalf("移入回收站失败: %v", err)
	}
	if err := service.Trash(stored.FileKey); err != nil {
		t.Fatalf("重复移入回收站应成功: %v", err)
	}
	if _, err := service.Metadata(stored.FileKey); !os.IsNotExist(err) {
		t.Fatalf("移入回收站后元数据应不存在: %v", err)
	}
}

func TestPaperStorageTrashDoesNotMoveFileWhenPendingMarkerCannotBeRemoved(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	markerPath := filepath.Join(service.RootDir(), ".pending", stored.FileKey)
	if err := os.Mkdir(markerPath, 0o700); err != nil {
		t.Fatalf("创建异常标记目录失败: %v", err)
	}
	if err := os.WriteFile(filepath.Join(markerPath, "child"), []byte("x"), 0o600); err != nil {
		t.Fatalf("创建异常标记内容失败: %v", err)
	}
	if err := service.Trash(stored.FileKey); err == nil {
		t.Fatal("标记无法清理时 Trash 应返回错误")
	}
	if _, err := service.Stat(stored.FileKey); !os.IsNotExist(err) {
		t.Fatalf("移动成功后原文件应不存在: %v", err)
	}
	trashEntries, err := os.ReadDir(filepath.Join(service.RootDir(), ".trash"))
	if err != nil || len(trashEntries) != 1 {
		t.Fatalf("移动成功后回收站应保留文件: entries=%v err=%v", trashEntries, err)
	}
}

func TestPaperStorageMetadataUsesOnDiskContentAndRejectsTraversal(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	metadata, err := service.Metadata(stored.FileKey)
	if err != nil {
		t.Fatalf("读取元数据失败: %v", err)
	}
	if metadata.FileKey != stored.FileKey || metadata.Size != stored.Size || metadata.SHA256 != stored.SHA256 {
		t.Fatalf("元数据不匹配: got=%+v want=%+v", metadata, stored)
	}
	if _, err := service.Metadata("../secret.pdf"); !errors.Is(err, ErrInvalidExamPaperFileKey) {
		t.Fatalf("路径穿越应被拒绝: %v", err)
	}
}

func TestPaperStorageMaintenanceOnlyRemovesItemsOlderThanSevenDays(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	oldFile, err := service.StoreUploadReader("old.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存旧 PDF 失败: %v", err)
	}
	newFile, err := service.StoreUploadReader("new.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存新 PDF 失败: %v", err)
	}
	for _, item := range []*StoredExamPaperFile{oldFile, newFile} {
		if err := service.MarkPending(item.FileKey); err != nil {
			t.Fatalf("创建待认领标记失败: %v", err)
		}
	}
	oldTime := now.Add(-7*24*time.Hour - time.Second)
	newTime := now.Add(-7*24*time.Hour + time.Second)
	if err := os.Chtimes(filepath.Join(service.RootDir(), ".pending", oldFile.FileKey), oldTime, oldTime); err != nil {
		t.Fatalf("设置旧标记时间失败: %v", err)
	}
	if err := os.Chtimes(filepath.Join(service.RootDir(), ".pending", newFile.FileKey), newTime, newTime); err != nil {
		t.Fatalf("设置新标记时间失败: %v", err)
	}

	trashOld, err := service.StoreUploadReader("trash-old.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存旧回收站 PDF 失败: %v", err)
	}
	trashNew, err := service.StoreUploadReader("trash-new.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存新回收站 PDF 失败: %v", err)
	}
	if err := service.Trash(trashOld.FileKey); err != nil {
		t.Fatalf("移入旧回收站失败: %v", err)
	}
	if err := service.Trash(trashNew.FileKey); err != nil {
		t.Fatalf("移入新回收站失败: %v", err)
	}
	trashEntries, err := os.ReadDir(filepath.Join(service.RootDir(), ".trash"))
	if err != nil {
		t.Fatalf("读取回收站失败: %v", err)
	}
	for _, entry := range trashEntries {
		modTime := newTime
		if strings.HasSuffix(entry.Name(), "--"+trashOld.FileKey) {
			modTime = oldTime
		}
		if err := os.Chtimes(filepath.Join(service.RootDir(), ".trash", entry.Name()), modTime, modTime); err != nil {
			t.Fatalf("设置回收站时间失败: %v", err)
		}
	}

	result, err := service.Maintenance(now)
	if err != nil {
		t.Fatalf("执行维护失败: %v", err)
	}
	if result.UnclaimedFilesRemoved != 1 || result.PendingMarkersRemoved != 1 || result.TrashFilesRemoved != 1 {
		t.Fatalf("维护计数错误: %+v", result)
	}
	if _, err := service.Metadata(oldFile.FileKey); !os.IsNotExist(err) {
		t.Fatalf("旧待认领文件应删除: %v", err)
	}
	if _, err := service.Metadata(newFile.FileKey); err != nil {
		t.Fatalf("新待认领文件不应删除: %v", err)
	}
}

func TestPaperStorageDiskUsagePercentReturnsValidRange(t *testing.T) {
	usage, err := ExamPaperDiskUsagePercent(t.TempDir())
	if err != nil {
		t.Fatalf("读取磁盘使用率失败: %v", err)
	}
	if usage < 0 || usage > 100 {
		t.Fatalf("磁盘使用率超出范围: %v", usage)
	}
}

func TestPaperStorageMaintenanceAndClaimDoNotLoseClaimedFile(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	if err := service.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建待认领标记失败: %v", err)
	}
	old := now.Add(-7*24*time.Hour - time.Second)
	if err := os.Chtimes(filepath.Join(service.RootDir(), ".pending", stored.FileKey), old, old); err != nil {
		t.Fatalf("设置标记时间失败: %v", err)
	}
	snapshotReady := make(chan struct{})
	release := make(chan struct{})
	service.maintenanceAfterSnapshot = func() {
		close(snapshotReady)
		<-release
	}
	maintenanceDone := make(chan error, 1)
	go func() {
		_, maintenanceErr := service.Maintenance(now)
		maintenanceDone <- maintenanceErr
	}()
	<-snapshotReady
	claimDone := make(chan error, 1)
	go func() { claimDone <- service.Claim(stored.FileKey) }()
	select {
	case err := <-claimDone:
		t.Fatalf("维护持锁时 Claim 不应提前完成: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	if err := <-maintenanceDone; err != nil {
		t.Fatalf("维护失败: %v", err)
	}
	if err := <-claimDone; err != nil {
		t.Fatalf("释放维护锁后 Claim 失败: %v", err)
	}
	if _, err := service.Stat(stored.FileKey); err != nil {
		t.Fatalf("Claim 后文件不应被维护删除: %v", err)
	}
}

func TestPaperStorageStorePendingUploadAndDiscardAreAtomic(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StorePendingUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("原子保存待认领文件失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(service.RootDir(), ".pending", stored.FileKey)); err != nil {
		t.Fatalf("原子保存后待认领标记不存在: %v", err)
	}
	if _, err := service.Stat(stored.FileKey); err != nil {
		t.Fatalf("原子保存后文件不存在: %v", err)
	}
	if err := service.DiscardPending(stored.FileKey); err != nil {
		t.Fatalf("丢弃待认领文件失败: %v", err)
	}
	if _, err := service.Stat(stored.FileKey); !os.IsNotExist(err) {
		t.Fatalf("丢弃后文件应不存在: %v", err)
	}
	if _, err := os.Stat(filepath.Join(service.RootDir(), ".pending", stored.FileKey)); !os.IsNotExist(err) {
		t.Fatalf("丢弃后标记应不存在: %v", err)
	}
}

func TestPaperStorageMaintenanceRemovesStaleUploadTemps(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	oldPath := filepath.Join(service.RootDir(), ".upload-old")
	newPath := filepath.Join(service.RootDir(), ".upload-new")
	if err := os.WriteFile(oldPath, []byte("old"), 0o600); err != nil {
		t.Fatalf("创建旧临时文件失败: %v", err)
	}
	if err := os.WriteFile(newPath, []byte("new"), 0o600); err != nil {
		t.Fatalf("创建新临时文件失败: %v", err)
	}
	oldTime := now.Add(-time.Hour - time.Second)
	if err := os.Chtimes(oldPath, oldTime, oldTime); err != nil {
		t.Fatalf("设置旧临时文件时间失败: %v", err)
	}
	result, err := service.Maintenance(now)
	if err != nil {
		t.Fatalf("维护失败: %v", err)
	}
	if result.TemporaryFilesRemoved != 1 {
		t.Fatalf("临时文件清理计数错误: %+v", result)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("旧临时文件应被清理: %v", err)
	}
	if _, err := os.Stat(newPath); err != nil {
		t.Fatalf("新临时文件不应被清理: %v", err)
	}
}

func TestPaperStorageTrashKeepsMarkerWhenMoveFails(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	if err := service.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建待认领标记失败: %v", err)
	}
	service.trashRename = func(string, string) error { return errors.New("模拟移动失败") }
	if err := service.Trash(stored.FileKey); err == nil {
		t.Fatal("移动失败时 Trash 应返回错误")
	}
	if _, err := os.Stat(filepath.Join(service.RootDir(), ".pending", stored.FileKey)); err != nil {
		t.Fatalf("移动失败时标记必须保留: %v", err)
	}
	if _, err := service.Stat(stored.FileKey); err != nil {
		t.Fatalf("移动失败时原文件必须保留: %v", err)
	}
}

func TestPaperStorageServiceRejectsSymlinkDirectoriesAndFiles(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 创建 symlink 需要额外权限")
	}
	t.Run("root", func(t *testing.T) {
		target := t.TempDir()
		link := filepath.Join(t.TempDir(), "root-link")
		if err := os.Symlink(target, link); err != nil {
			t.Skipf("无法创建 symlink: %v", err)
		}
		if _, err := NewExamPaperFileService(link); err == nil {
			t.Fatal("root symlink 应被拒绝")
		}
	})
	t.Run("pending", func(t *testing.T) {
		root := t.TempDir()
		if err := os.Symlink(t.TempDir(), filepath.Join(root, ".pending")); err != nil {
			t.Skipf("无法创建 symlink: %v", err)
		}
		if _, err := NewExamPaperFileService(root); err == nil {
			t.Fatal("pending symlink 应被拒绝")
		}
	})
	t.Run("file", func(t *testing.T) {
		root := t.TempDir()
		service, err := NewExamPaperFileService(root)
		if err != nil {
			t.Fatalf("初始化文件服务失败: %v", err)
		}
		if err := os.Symlink(filepath.Join(root, "target.pdf"), filepath.Join(root, "link.pdf")); err != nil {
			t.Skipf("无法创建 symlink: %v", err)
		}
		if _, err := service.Stat("link.pdf"); err == nil {
			t.Fatal("symlink 文件应被拒绝")
		}
		if err := os.Mkdir(filepath.Join(root, "directory.pdf"), 0o700); err != nil {
			t.Fatalf("创建目录文件失败: %v", err)
		}
		if _, err := service.Stat("directory.pdf"); err == nil {
			t.Fatal("非普通文件应被拒绝")
		}
	})
}

func TestExamPaperDiskUsagePercentUsesAvailableQuota(t *testing.T) {
	if got := diskUsagePercent(100, 20); got != 80 {
		t.Fatalf("磁盘使用率计算错误: got=%v want=80", got)
	}
}
