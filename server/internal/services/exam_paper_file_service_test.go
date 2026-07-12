package services

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
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

type examPaperCountingReader struct {
	reader io.Reader
	read   int64
}

func (r *examPaperCountingReader) Read(buffer []byte) (int, error) {
	count, err := r.reader.Read(buffer)
	r.read += int64(count)
	return count, err
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

func TestPaperStoragePendingUploadStopsAtExpectedSizeBeforePDFValidation(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	validated := false
	service.validateUpload = func(string) error {
		validated = true
		return nil
	}
	const expectedSize int64 = 8
	source := &examPaperCountingReader{reader: io.MultiReader(strings.NewReader("%PDF-1234"), bytes.NewReader(bytes.Repeat([]byte("x"), 1024*1024)))}
	stored, err := service.StorePendingUploadReaderExpected("paper.pdf", source, expectedSize)
	if !errors.Is(err, ErrExamPaperUploadSizeMismatch) || stored != nil {
		t.Fatalf("大小不符错误类型错误: stored=%+v err=%v", stored, err)
	}
	if source.read != expectedSize+1 {
		t.Fatalf("应在 expectedSize+1 字节停止读取: read=%d", source.read)
	}
	if validated {
		t.Fatal("大小不符不应进入 PDF 结构验证")
	}
	entries, err := os.ReadDir(service.RootDir())
	if err != nil {
		t.Fatalf("读取存储目录失败: %v", err)
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) == ".pdf" {
			t.Fatalf("大小不符后遗留 PDF: %s", entry.Name())
		}
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

func TestExamPaperFileServiceStageDeleteRefreshesTrashAgeBeforeCrossInstanceMaintenance(t *testing.T) {
	root := t.TempDir()
	stageService, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化暂存删除服务失败: %v", err)
	}
	maintenanceService, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化维护服务失败: %v", err)
	}
	stored, err := stageService.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	stageService.now = func() time.Time { return now }
	old := now.Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(filepath.Join(root, stored.FileKey), old, old); err != nil {
		t.Fatalf("设置旧文件时间失败: %v", err)
	}

	renameDone := make(chan struct{})
	continueStage := make(chan struct{})
	maintenanceReady := make(chan struct{})
	stageService.stageDeleteAfterRename = func() {
		close(renameDone)
		<-continueStage
	}
	maintenanceService.maintenanceBeforeTrashDelete = func(string) { close(maintenanceReady) }
	type stageResult struct {
		move ExamPaperTrashMove
		err  error
	}
	stageDone := make(chan stageResult, 1)
	go func() {
		move, err := stageService.StageDelete(stored.FileKey)
		stageDone <- stageResult{move: move, err: err}
	}()
	<-renameDone
	maintenanceDone := make(chan struct {
		result ExamPaperMaintenanceResult
		err    error
	}, 1)
	go func() {
		result, err := maintenanceService.Maintenance(now)
		maintenanceDone <- struct {
			result ExamPaperMaintenanceResult
			err    error
		}{result: result, err: err}
	}()
	<-maintenanceReady
	close(continueStage)
	staged := <-stageDone
	if staged.err != nil {
		t.Fatalf("暂存删除失败: %v", staged.err)
	}
	maintained := <-maintenanceDone
	if maintained.err != nil {
		t.Fatalf("跨实例维护失败: %v", maintained.err)
	}
	result := maintained.result
	if result.TrashFilesRemoved != 0 {
		t.Fatalf("刚暂存的旧文件不得被维护删除: %+v", result)
	}
	if err := stageService.RestoreDelete(staged.move); err != nil {
		t.Fatalf("维护后回滚暂存删除失败: %v", err)
	}
	if _, err := stageService.Stat(stored.FileKey); err != nil {
		t.Fatalf("回滚后原文件应存在: %v", err)
	}
}

func TestExamPaperFileServiceStageDeleteRollsBackWhenTrashAgeRefreshFails(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	service.chtimes = func(string, time.Time, time.Time) error { return errors.New("模拟刷新时间失败") }

	if _, err := service.StageDelete(stored.FileKey); err == nil {
		t.Fatal("刷新回收站文件时间失败时暂存删除应失败")
	}
	if _, err := service.Stat(stored.FileKey); err != nil {
		t.Fatalf("暂存删除失败后原文件应恢复: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(service.RootDir(), ".trash"))
	if err != nil {
		t.Fatalf("读取回收站失败: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("暂存删除失败后不得遗留回收站文件: %v", entries)
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

func TestPaperStorageMaintenanceAndClaimAreAtomicAcrossServiceInstances(t *testing.T) {
	root := t.TempDir()
	claimService, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化 Claim 文件服务失败: %v", err)
	}
	maintenanceService, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化 Maintenance 文件服务失败: %v", err)
	}
	stored, err := claimService.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	if err := claimService.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建 pending 标记失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	old := now.Add(-7*24*time.Hour - time.Second)
	if err := os.Chtimes(filepath.Join(root, ".pending", stored.FileKey), old, old); err != nil {
		t.Fatalf("设置旧标记时间失败: %v", err)
	}
	deleteReady := make(chan struct{})
	continueDelete := make(chan struct{})
	maintenanceService.maintenanceBeforePendingDelete = func(string) {
		close(deleteReady)
		<-continueDelete
	}
	maintenanceDone := make(chan error, 1)
	go func() {
		_, err := maintenanceService.Maintenance(now)
		maintenanceDone <- err
	}()
	<-deleteReady
	if err := claimService.Claim(stored.FileKey); err != nil {
		t.Fatalf("跨实例 Claim 失败: %v", err)
	}
	close(continueDelete)
	if err := <-maintenanceDone; err != nil {
		t.Fatalf("跨实例维护失败: %v", err)
	}
	if _, err := claimService.Stat(stored.FileKey); err != nil {
		t.Fatalf("成功 Claim 后文件不得被其他实例维护删除: %v", err)
	}
}

func TestPaperStorageMaintenanceAndTrashDoNotReportFalseSuccessAcrossServiceInstances(t *testing.T) {
	root := t.TempDir()
	trashService, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化 Trash 文件服务失败: %v", err)
	}
	maintenanceService, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化 Maintenance 文件服务失败: %v", err)
	}
	stored, err := trashService.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	if err := trashService.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建 pending 标记失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	old := now.Add(-7*24*time.Hour - time.Second)
	if err := os.Chtimes(filepath.Join(root, ".pending", stored.FileKey), old, old); err != nil {
		t.Fatalf("设置旧标记时间失败: %v", err)
	}
	fileDeleted := make(chan struct{})
	continueMaintenance := make(chan struct{})
	maintenanceService.maintenanceAfterPendingDelete = func(string) {
		close(fileDeleted)
		<-continueMaintenance
	}
	maintenanceDone := make(chan error, 1)
	go func() {
		_, err := maintenanceService.Maintenance(now)
		maintenanceDone <- err
	}()
	<-fileDeleted
	trashStarted := make(chan struct{})
	trashDone := make(chan error, 1)
	go func() {
		close(trashStarted)
		trashDone <- trashService.Trash(stored.FileKey)
	}()
	<-trashStarted
	close(continueMaintenance)
	if err := <-maintenanceDone; err != nil {
		t.Fatalf("跨实例维护失败: %v", err)
	}
	if err := <-trashDone; err == nil {
		t.Fatal("文件已被维护删除且未进入 trash 时，Trash 不得报告成功")
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

func TestPaperStoragePendingCommitKeepsMarkerWhenChmodCleanupFails(t *testing.T) {
	tests := []struct {
		name       string
		removeErr  error
		markerKeep bool
	}{
		{name: "remove failure", removeErr: errors.New("模拟最终文件删除失败"), markerKeep: true},
		{name: "remove success", markerKeep: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service, err := NewExamPaperFileService(t.TempDir())
			if err != nil {
				t.Fatalf("初始化文件服务失败: %v", err)
			}
			service.chmod = func(path string, mode os.FileMode) error {
				if strings.HasSuffix(path, ".pdf") {
					return errors.New("模拟 chmod 失败")
				}
				return os.Chmod(path, mode)
			}
			service.remove = func(path string) error {
				if strings.HasSuffix(path, ".pdf") && tt.removeErr != nil {
					return tt.removeErr
				}
				return os.Remove(path)
			}
			stored, err := service.StorePendingUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
			if err == nil || stored != nil {
				t.Fatalf("chmod 失败时应返回错误且不返回文件: stored=%v err=%v", stored, err)
			}
			entries, readErr := os.ReadDir(filepath.Join(service.RootDir(), ".pending"))
			if readErr != nil {
				t.Fatalf("读取 pending 目录失败: %v", readErr)
			}
			if (len(entries) != 0) == tt.markerKeep {
				return
			}
			t.Fatalf("marker 保留状态错误: keep=%v entries=%d", tt.markerKeep, len(entries))
		})
	}
}

func TestPaperStorageClaimIntentReferenceCountProtectsConcurrentClaims(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存 PDF 失败: %v", err)
	}
	if err := service.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建 pending marker 失败: %v", err)
	}
	old := time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(filepath.Join(service.RootDir(), ".pending", stored.FileKey), old, old); err != nil {
		t.Fatalf("设置 marker 时间失败: %v", err)
	}
	firstRegistered := make(chan struct{})
	secondRegistered := make(chan struct{})
	releaseSecond := make(chan struct{})
	var registrations int32
	service.claimAfterIntent = func() {
		count := atomic.AddInt32(&registrations, 1)
		if count == 1 {
			close(firstRegistered)
			return
		}
		if count == 2 {
			close(secondRegistered)
			<-releaseSecond
		}
	}
	service.claimRemove = func(string) error {
		return errors.New("模拟第一个 Claim 失败")
	}
	firstDone := make(chan error, 1)
	secondDone := make(chan error, 1)
	go func() { firstDone <- service.Claim(stored.FileKey) }()
	select {
	case <-firstRegistered:
	case <-time.After(time.Second):
		t.Fatal("第一个 Claim 未完成 intent 登记")
	}
	go func() { secondDone <- service.Claim(stored.FileKey) }()
	select {
	case <-secondRegistered:
	case <-time.After(time.Second):
		t.Fatal("两个 Claim 未完成 intent 登记")
	}
	if err := <-firstDone; err == nil {
		t.Fatal("第一个 Claim 应返回模拟错误")
	}
	result, err := service.Maintenance(time.Now())
	if err != nil {
		t.Fatalf("维护失败: %v", err)
	}
	if result.UnclaimedFilesRemoved != 0 || result.PendingMarkersRemoved != 0 {
		t.Fatalf("第二个 Claim 等待时维护不应清理: %+v", result)
	}
	close(releaseSecond)
	if err := <-secondDone; err == nil {
		t.Fatal("第二个 Claim 应返回模拟错误")
	}
	if _, err := service.Stat(stored.FileKey); err != nil {
		t.Fatalf("Claim 失败后文件应保留: %v", err)
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

func TestPaperStorageUploadSessionPersistsCompletedReplayAcrossRestart(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "11111111-1111-4111-8111-111111111111"
	const jti = "upload-jti-1"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	begin, err := service.BeginUploadSession(sessionID, jti, 123, now.Add(time.Minute), now)
	if err != nil || begin.Completed {
		t.Fatalf("首次占用上传会话失败: result=%+v err=%v", begin, err)
	}
	stored := StoredExamPaperFile{FileKey: "22222222-2222-4222-8222-222222222222.pdf", Size: 123, SHA256: strings.Repeat("a", 64)}
	if err := service.CompleteUploadSession(sessionID, jti, "signed-receipt", stored, now); err != nil {
		t.Fatalf("完成上传会话失败: %v", err)
	}

	restarted, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	replay, err := restarted.BeginUploadSession(sessionID, jti, 123, now.Add(time.Minute), now.Add(time.Second))
	if err != nil || !replay.Completed || replay.Receipt != "signed-receipt" {
		t.Fatalf("重启后幂等重放错误: result=%+v err=%v", replay, err)
	}
	entries, err := os.ReadDir(filepath.Join(root, ".sessions"))
	var sessionEntries []os.DirEntry
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			sessionEntries = append(sessionEntries, entry)
		}
	}
	if err != nil || len(sessionEntries) != 1 {
		t.Fatalf("完成后应仅保留一个会话记录: entries=%d err=%v", len(sessionEntries), err)
	}
	info, err := sessionEntries[0].Info()
	if err != nil {
		t.Fatalf("读取会话记录权限失败: %v", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("会话记录权限错误: %o", info.Mode().Perm())
	}
}

func TestExamPaperUploadSessionStatePublicationIsAtomic(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "11999999-9999-4999-8999-999999999999"
	receipt := strings.Repeat("r", 8*1024*1024)
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	record := examPaperUploadSessionRecord{
		SessionID: sessionID, JTI: "atomic-state-jti", ExpectedSize: 123,
		Status: "completed", Receipt: receipt, FileKey: sessionID + ".pdf",
		FileSize: 123, SHA256: strings.Repeat("a", 64), CompletedAt: now,
	}
	path := service.uploadSessionPath(sessionID, "completed")
	done := make(chan error, 1)
	go func() { done <- writeExamPaperUploadSessionRecordExclusive(path, record) }()
	for {
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("原子发布会话状态失败: %v", err)
			}
			published, readErr := readExamPaperUploadSessionRecord(path)
			if readErr != nil {
				t.Fatalf("原子发布成功后读取状态失败: %v", readErr)
			}
			if published.Receipt != receipt {
				t.Fatalf("会话状态不得暴露部分内容: got=%d want=%d", len(published.Receipt), len(receipt))
			}
			return
		default:
		}
		published, readErr := readExamPaperUploadSessionRecord(path)
		if readErr == nil {
			if published.Receipt != receipt {
				t.Fatalf("会话状态不得暴露部分内容: got=%d want=%d", len(published.Receipt), len(receipt))
			}
			break
		}
		if !os.IsNotExist(readErr) {
			t.Fatalf("目标状态发布前只能表现为不存在，不得暴露半写文件: %v", readErr)
		}
	}
	if err := <-done; err != nil {
		t.Fatalf("原子发布会话状态失败: %v", err)
	}
}

func TestPaperStorageUploadSessionReplaysLegacyCompletedStateWithoutUserID(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "12111111-1111-4111-8111-111111111111"
	const jti = "legacy-upload-jti"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	legacy, err := json.Marshal(map[string]any{
		"session_id": sessionID, "jti": jti, "expected_size": 123, "expires_at": now.Add(time.Minute),
		"status": "completed", "receipt": "legacy-receipt", "file_key": sessionID + ".pdf",
		"file_size": 123, "sha256": strings.Repeat("a", 64), "created_at": now,
		"updated_at": now, "completed_at": now,
	})
	if err != nil {
		t.Fatalf("编码旧 completed 状态失败: %v", err)
	}
	if err := os.WriteFile(service.uploadSessionPath(sessionID, "completed"), legacy, 0o600); err != nil {
		t.Fatalf("写入旧 completed 状态失败: %v", err)
	}
	replay, err := service.BeginUploadSessionForUser(sessionID, jti, 42, 123, now.Add(time.Minute), now)
	if err != nil || !replay.Completed || replay.Receipt != "legacy-receipt" {
		t.Fatalf("旧 completed 状态应支持原 token 幂等重放: result=%+v err=%v", replay, err)
	}
	if _, err := service.BeginUploadSessionForUser(sessionID, "other-user-jti", 43, 123, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadSessionConsumed) {
		t.Fatalf("旧 completed 状态不得被其他 token 跨用户重放: %v", err)
	}
}

func TestPaperStorageUploadSessionRejectsCrossUserReplayForUserBoundCompletedState(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "12222222-2222-4222-8222-222222222222"
	const jti = "user-bound-jti"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	if _, err := service.BeginUploadSessionForUser(sessionID, jti, 42, 123, now.Add(time.Minute), now); err != nil {
		t.Fatalf("占用用户绑定会话失败: %v", err)
	}
	stored := StoredExamPaperFile{FileKey: "12333333-3333-4333-8333-333333333333.pdf", Size: 123, SHA256: strings.Repeat("a", 64)}
	if err := service.CompleteUploadSession(sessionID, jti, "user-bound-receipt", stored, now); err != nil {
		t.Fatalf("完成用户绑定会话失败: %v", err)
	}
	if _, err := service.BeginUploadSessionForUser(sessionID, jti, 43, 123, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadSessionConsumed) {
		t.Fatalf("新 completed 状态不得被其他用户重放: %v", err)
	}
}

func TestPaperStorageUploadSessionRejectsConcurrentOrMismatchedUse(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "33333333-3333-4333-8333-333333333333"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	if _, err := service.BeginUploadSession(sessionID, "jti-a", 100, now.Add(time.Minute), now); err != nil {
		t.Fatalf("首次占用上传会话失败: %v", err)
	}
	if _, err := service.BeginUploadSession(sessionID, "jti-a", 100, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadInProgress) {
		t.Fatalf("并发重入错误类型不符: %v", err)
	}
	if _, err := service.BeginUploadSession(sessionID, "jti-b", 100, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadSessionConsumed) {
		t.Fatalf("不同 token 重用错误类型不符: %v", err)
	}
	if err := service.AbortUploadSession(sessionID, "jti-a"); err != nil {
		t.Fatalf("取消上传占用失败: %v", err)
	}
	if _, err := service.BeginUploadSession(sessionID, "jti-a", 100, now.Add(time.Minute), now); err != nil {
		t.Fatalf("取消后同 token 应可重试: %v", err)
	}
}

func TestPaperStorageUploadSessionFailureLimitPersistsAcrossRestart(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "88888888-8888-4888-8888-888888888888"
	const jti = "failure-limit-jti"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	for attempt := 0; attempt < ExamPaperMaxUploadFailuresPerSession; attempt++ {
		if _, err := service.BeginUploadSessionForUser(sessionID, jti, 42, 100, now.Add(time.Minute), now); err != nil {
			t.Fatalf("第 %d 次占用失败: %v", attempt+1, err)
		}
		if err := service.FailUploadSession(sessionID, jti, now); err != nil {
			t.Fatalf("第 %d 次记录失败次数失败: %v", attempt+1, err)
		}
	}
	restarted, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	if _, err := restarted.BeginUploadSessionForUser(sessionID, jti, 42, 100, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadRetryExhausted) {
		t.Fatalf("跨重启后第 4 次应被锁定: %v", err)
	}
}

func TestPaperStorageMaintenanceExpiresOrphanedUploadFailureRecordsAcrossRestart(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "89000000-0000-4000-8000-000000000001"
	const jti = "failure-maintenance-jti"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	expiresAt := now.Add(10 * time.Minute)
	for attempt := 0; attempt < ExamPaperMaxUploadFailuresPerSession; attempt++ {
		if _, err := service.BeginUploadSessionForUser(sessionID, jti, 42, 100, expiresAt, now); err != nil {
			t.Fatalf("第 %d 次占用失败: %v", attempt+1, err)
		}
		if err := service.FailUploadSession(sessionID, jti, now); err != nil {
			t.Fatalf("第 %d 次记录失败次数失败: %v", attempt+1, err)
		}
	}

	restarted, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	retained, err := restarted.Maintenance(expiresAt.Add(24*time.Hour - time.Second))
	if err != nil {
		t.Fatalf("保留期内维护失败: %v", err)
	}
	if retained.UploadFailureRecordsRemoved != 0 {
		t.Fatalf("保留期内不得清理失败记录: %+v", retained)
	}
	if _, err := restarted.BeginUploadSessionForUser(sessionID, jti, 42, 100, expiresAt.Add(48*time.Hour), expiresAt.Add(24*time.Hour)); !errors.Is(err, ErrExamPaperUploadRetryExhausted) {
		t.Fatalf("保留期内不得重置失败次数: %v", err)
	}
	removed, err := restarted.Maintenance(expiresAt.Add(24*time.Hour + time.Second))
	if err != nil {
		t.Fatalf("保留期后维护失败: %v", err)
	}
	if removed.UploadFailureRecordsRemoved != ExamPaperMaxUploadFailuresPerSession {
		t.Fatalf("孤立失败记录清理计数错误: %+v", removed)
	}
	if _, err := restarted.BeginUploadSessionForUser(sessionID, jti, 42, 100, expiresAt.Add(48*time.Hour), expiresAt.Add(24*time.Hour+time.Second)); err != nil {
		t.Fatalf("孤立失败记录过期清理后应允许新 reservation: %v", err)
	}
}

func TestPaperStorageUploadSessionEnforcesPerUserUnclaimedQuota(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	sessionIDs := []string{
		"10000000-0000-4000-8000-000000000001",
		"10000000-0000-4000-8000-000000000002",
		"10000000-0000-4000-8000-000000000003",
		"10000000-0000-4000-8000-000000000004",
		"10000000-0000-4000-8000-000000000005",
	}
	for index, sessionID := range sessionIDs {
		jti := fmt.Sprintf("quota-jti-%d", index)
		if _, err := service.BeginUploadSessionForUser(sessionID, jti, 42, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
			t.Fatalf("创建配额内会话失败: %v", err)
		}
		stored := StoredExamPaperFile{FileKey: sessionID + ".pdf", Size: ExamPaperMaxFileSize, SHA256: strings.Repeat("c", 64)}
		if err := service.CompleteUploadSession(sessionID, jti, "receipt-"+sessionID, stored, now); err != nil {
			t.Fatalf("完成配额内会话失败: %v", err)
		}
	}
	if _, err := service.BeginUploadSessionForUser("10000000-0000-4000-8000-000000000006", "quota-over", 42, 1, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUnclaimedQuotaExceeded) {
		t.Fatalf("超过用户未认领配额应被拒绝: %v", err)
	}
	if _, err := service.BeginUploadSessionForUser("20000000-0000-4000-8000-000000000001", "other-user", 43, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
		t.Fatalf("其他用户不应受影响: %v", err)
	}
}

func TestPaperStorageUploadSessionPrioritizesInProgressAtFullQuota(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	for index := 0; index < 5; index++ {
		sessionID := fmt.Sprintf("13000000-0000-4000-8000-%012d", index+1)
		if _, err := service.BeginUploadSessionForUser(sessionID, fmt.Sprintf("full-quota-%d", index), 51, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
			t.Fatalf("填充配额失败: %v", err)
		}
	}
	if _, err := service.BeginUploadSessionForUser("13000000-0000-4000-8000-000000000001", "full-quota-0", 51, ExamPaperMaxFileSize, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadInProgress) {
		t.Fatalf("满配额时同 token 重放应优先返回上传中: %v", err)
	}
}

func TestPaperStorageUploadSessionSerializesConcurrentPerUserReservations(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	ids := []string{
		"30000000-0000-4000-8000-000000000001", "30000000-0000-4000-8000-000000000002",
		"30000000-0000-4000-8000-000000000003", "30000000-0000-4000-8000-000000000004",
		"30000000-0000-4000-8000-000000000005", "30000000-0000-4000-8000-000000000006",
	}
	var acquired, rejected atomic.Int32
	var wait sync.WaitGroup
	for index, sessionID := range ids {
		wait.Add(1)
		go func(index int, sessionID string) {
			defer wait.Done()
			_, err := service.BeginUploadSessionForUser(sessionID, fmt.Sprintf("concurrent-%d", index), 99, ExamPaperMaxFileSize, now.Add(time.Minute), now)
			switch {
			case err == nil:
				acquired.Add(1)
			case errors.Is(err, ErrExamPaperUnclaimedQuotaExceeded):
				rejected.Add(1)
			default:
				t.Errorf("并发占用返回意外错误: %v", err)
			}
		}(index, sessionID)
	}
	wait.Wait()
	if acquired.Load() != 5 || rejected.Load() != 1 {
		t.Fatalf("并发配额结果错误: acquired=%d rejected=%d", acquired.Load(), rejected.Load())
	}
}

func TestPaperStorageUploadSessionSerializesReservationsAcrossServiceInstances(t *testing.T) {
	root := t.TempDir()
	seed, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	for index := 0; index < 4; index++ {
		sessionID := fmt.Sprintf("14000000-0000-4000-8000-%012d", index+1)
		jti := fmt.Sprintf("shared-quota-seed-%d", index)
		if _, err := seed.BeginUploadSessionForUser(sessionID, jti, 52, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
			t.Fatalf("创建初始配额占用失败: %v", err)
		}
		stored := StoredExamPaperFile{FileKey: sessionID + ".pdf", Size: ExamPaperMaxFileSize, SHA256: strings.Repeat("f", 64)}
		if err := seed.CompleteUploadSession(sessionID, jti, "receipt-"+sessionID, stored, now); err != nil {
			t.Fatalf("完成初始配额占用失败: %v", err)
		}
	}

	const contenders = 8
	instances := make([]*ExamPaperFileService, contenders)
	for index := range instances {
		instances[index], err = NewExamPaperFileService(root)
		if err != nil {
			t.Fatalf("创建第 %d 个文件服务实例失败: %v", index+1, err)
		}
	}
	start := make(chan struct{})
	results := make(chan error, contenders)
	for index, instance := range instances {
		go func(index int, instance *ExamPaperFileService) {
			<-start
			sessionID := fmt.Sprintf("15000000-0000-4000-8000-%012d", index+1)
			_, err := instance.BeginUploadSessionForUser(sessionID, fmt.Sprintf("shared-quota-%d", index), 52, ExamPaperMaxFileSize, now.Add(time.Minute), now)
			results <- err
		}(index, instance)
	}
	close(start)
	var acquired, rejected int
	for range contenders {
		switch err := <-results; {
		case err == nil:
			acquired++
		case errors.Is(err, ErrExamPaperUnclaimedQuotaExceeded):
			rejected++
		default:
			t.Fatalf("跨实例占用返回意外错误: %v", err)
		}
	}
	if acquired != 1 || rejected != contenders-1 {
		t.Fatalf("跨实例配额预留不原子: acquired=%d rejected=%d", acquired, rejected)
	}
}

func TestPaperStorageClaimReleasesPerUserUnclaimedQuota(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	var firstFileKey string
	for index := 0; index < 5; index++ {
		sessionID := fmt.Sprintf("40000000-0000-4000-8000-%012d", index+1)
		jti := fmt.Sprintf("claim-quota-%d", index)
		if _, err := service.BeginUploadSessionForUser(sessionID, jti, 77, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
			t.Fatalf("创建占用失败: %v", err)
		}
		fileKey := sessionID + ".pdf"
		if index == 0 {
			firstFileKey = fileKey
			if err := os.WriteFile(filepath.Join(service.RootDir(), fileKey), buildMinimalPDF(), 0o600); err != nil {
				t.Fatalf("创建认领文件失败: %v", err)
			}
			if err := service.MarkPending(fileKey); err != nil {
				t.Fatalf("创建 pending 标记失败: %v", err)
			}
		}
		stored := StoredExamPaperFile{FileKey: fileKey, Size: ExamPaperMaxFileSize, SHA256: strings.Repeat("d", 64)}
		if err := service.CompleteUploadSession(sessionID, jti, "receipt-"+sessionID, stored, now); err != nil {
			t.Fatalf("完成会话失败: %v", err)
		}
	}
	if err := service.Claim(firstFileKey); err != nil {
		t.Fatalf("认领文件并释放配额失败: %v", err)
	}
	if _, err := service.BeginUploadSessionForUser("40000000-0000-4000-8000-000000000006", "after-claim", 77, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
		t.Fatalf("认领后应释放一份配额: %v", err)
	}
}

func TestPaperStorageTrashReleasesPerUserUnclaimedQuota(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	var firstFileKey string
	for index := 0; index < 5; index++ {
		sessionID := fmt.Sprintf("41000000-0000-4000-8000-%012d", index+1)
		jti := fmt.Sprintf("trash-quota-%d", index)
		if _, err := service.BeginUploadSessionForUser(sessionID, jti, 78, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
			t.Fatalf("创建占用失败: %v", err)
		}
		fileKey := sessionID + ".pdf"
		if index == 0 {
			firstFileKey = fileKey
			if err := os.WriteFile(filepath.Join(service.RootDir(), fileKey), buildMinimalPDF(), 0o600); err != nil {
				t.Fatalf("创建待删除文件失败: %v", err)
			}
			if err := service.MarkPending(fileKey); err != nil {
				t.Fatalf("创建 pending 标记失败: %v", err)
			}
		}
		stored := StoredExamPaperFile{FileKey: fileKey, Size: ExamPaperMaxFileSize, SHA256: strings.Repeat("e", 64)}
		if err := service.CompleteUploadSession(sessionID, jti, "receipt-"+sessionID, stored, now); err != nil {
			t.Fatalf("完成会话失败: %v", err)
		}
	}
	if err := service.Trash(firstFileKey); err != nil {
		t.Fatalf("移入回收站并释放配额失败: %v", err)
	}
	if _, err := service.BeginUploadSessionForUser("41000000-0000-4000-8000-000000000006", "after-trash", 78, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
		t.Fatalf("移入回收站后应释放一份配额: %v", err)
	}
}

func TestPaperStorageFailedLifecycleTransitionDoesNotReleaseQuota(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	prepare := func(t *testing.T, prefix string, userID uint) (*ExamPaperFileService, string) {
		t.Helper()
		service, err := NewExamPaperFileService(t.TempDir())
		if err != nil {
			t.Fatalf("初始化文件服务失败: %v", err)
		}
		var firstFileKey string
		for index := 0; index < 5; index++ {
			sessionID := fmt.Sprintf("%s-0000-4000-8000-%012d", prefix, index+1)
			jti := fmt.Sprintf("failed-lifecycle-%s-%d", prefix, index)
			if _, err := service.BeginUploadSessionForUser(sessionID, jti, userID, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
				t.Fatalf("创建占用失败: %v", err)
			}
			fileKey := sessionID + ".pdf"
			if index == 0 {
				firstFileKey = fileKey
				if err := os.WriteFile(filepath.Join(service.RootDir(), fileKey), buildMinimalPDF(), 0o600); err != nil {
					t.Fatalf("创建生命周期文件失败: %v", err)
				}
				if err := service.MarkPending(fileKey); err != nil {
					t.Fatalf("创建 pending 标记失败: %v", err)
				}
			}
			stored := StoredExamPaperFile{FileKey: fileKey, Size: ExamPaperMaxFileSize, SHA256: strings.Repeat("f", 64)}
			if err := service.CompleteUploadSession(sessionID, jti, "receipt-"+sessionID, stored, now); err != nil {
				t.Fatalf("完成会话失败: %v", err)
			}
		}
		return service, firstFileKey
	}
	tests := []struct {
		name   string
		prefix string
		userID uint
		fail   func(*ExamPaperFileService, string) error
	}{
		{
			name: "Claim", prefix: "71000000", userID: 110,
			fail: func(service *ExamPaperFileService, fileKey string) error {
				service.claimRemove = func(string) error { return errors.New("模拟 Claim 失败") }
				return service.Claim(fileKey)
			},
		},
		{
			name: "Trash", prefix: "72000000", userID: 111,
			fail: func(service *ExamPaperFileService, fileKey string) error {
				service.trashRename = func(string, string) error { return errors.New("模拟 Trash 失败") }
				return service.Trash(fileKey)
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service, fileKey := prepare(t, tt.prefix, tt.userID)
			if err := tt.fail(service, fileKey); err == nil {
				t.Fatalf("%s 应返回模拟生命周期错误", tt.name)
			}
			sessionID := fmt.Sprintf("%s-0000-4000-8000-000000000006", tt.prefix)
			if _, err := service.BeginUploadSessionForUser(sessionID, "after-failed-"+tt.name, tt.userID, 1, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUnclaimedQuotaExceeded) {
				t.Fatalf("%s 失败后不得释放配额: %v", tt.name, err)
			}
		})
	}
}

func TestPaperStorageUploadSessionRejectsInvalidSessionID(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	for _, sessionID := range []string{"session-1", "../escape", "11111111-1111-4111-8111-111111111111/extra"} {
		if _, err := service.BeginUploadSession(sessionID, "jti", 100, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUploadSessionInvalid) {
			t.Fatalf("非法会话 ID 应被拒绝: id=%q err=%v", sessionID, err)
		}
	}
}

func TestPaperStorageMaintenanceRemovesExpiredUploadSessionRecords(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const staleUploading = "44444444-4444-4444-8444-444444444444"
	const freshUploading = "55555555-5555-4555-8555-555555555555"
	const staleCompleted = "66666666-6666-4666-8666-666666666666"
	const freshCompleted = "77777777-7777-4777-8777-777777777777"
	const staleUnclaimed = "99999999-9999-4999-8999-999999999999"
	if _, err := service.BeginUploadSession(staleUploading, "stale-uploading", 100, now.Add(time.Minute), now.Add(-time.Hour-time.Second)); err != nil {
		t.Fatalf("创建旧 uploading 记录失败: %v", err)
	}
	if _, err := service.BeginUploadSession(freshUploading, "fresh-uploading", 100, now.Add(time.Minute), now); err != nil {
		t.Fatalf("创建新 uploading 记录失败: %v", err)
	}
	for _, item := range []struct {
		id, jti     string
		completedAt time.Time
	}{
		{staleCompleted, "stale-completed", now.Add(-24*time.Hour - time.Second)},
		{freshCompleted, "fresh-completed", now},
		{staleUnclaimed, "stale-unclaimed", now.Add(-24*time.Hour - time.Second)},
	} {
		if _, err := service.BeginUploadSessionForUser(item.id, item.jti, 42, 100, now.Add(time.Minute), item.completedAt); err != nil {
			t.Fatalf("创建 completed 会话失败: %v", err)
		}
		stored := StoredExamPaperFile{FileKey: item.id + ".pdf", Size: 100, SHA256: strings.Repeat("b", 64)}
		if err := service.CompleteUploadSession(item.id, item.jti, "receipt-"+item.id, stored, item.completedAt); err != nil {
			t.Fatalf("完成会话失败: %v", err)
		}
	}
	if err := service.ReleaseUploadSessionByFileKey(staleCompleted+".pdf", now.Add(-24*time.Hour-time.Second)); err != nil {
		t.Fatalf("标记旧 completed 已释放失败: %v", err)
	}
	result, err := service.Maintenance(now)
	if err != nil {
		t.Fatalf("维护失败: %v", err)
	}
	if result.StaleUploadSessionsRemoved != 1 || result.CompletedUploadSessionsRemoved != 1 {
		t.Fatalf("上传会话清理计数错误: %+v", result)
	}
	entries, err := os.ReadDir(filepath.Join(service.RootDir(), ".sessions"))
	remainingStates := 0
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			remainingStates++
		}
	}
	if err != nil || remainingStates != 3 {
		t.Fatalf("维护后应保留新记录和未认领 completed: entries=%d err=%v", remainingStates, err)
	}
	if _, err := os.Stat(filepath.Join(service.RootDir(), ".sessions", staleUnclaimed+".completed.json")); err != nil {
		t.Fatalf("超过 24 小时但未认领的 completed 不应清理: %v", err)
	}
}

func TestPaperStorageCorruptCompletedStateDoesNotBlockQuotaOrOtherFileLifecycle(t *testing.T) {
	root := t.TempDir()
	service, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	const goodSessionID = "67000000-0000-4000-8000-000000000001"
	const goodJTI = "good-state-jti"
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存正常文件失败: %v", err)
	}
	if err := service.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建正常文件 pending 标记失败: %v", err)
	}
	if _, err := service.BeginUploadSessionForUser(goodSessionID, goodJTI, 99, stored.Size, now.Add(time.Minute), now); err != nil {
		t.Fatalf("创建正常 completed 状态失败: %v", err)
	}
	if err := service.CompleteUploadSession(goodSessionID, goodJTI, "good-state-receipt", *stored, now); err != nil {
		t.Fatalf("完成正常 completed 状态失败: %v", err)
	}
	const corruptSessionID = "00000000-0000-4000-8000-000000000001"
	corruptPath := service.uploadSessionPath(corruptSessionID, "completed")
	if err := os.WriteFile(corruptPath, []byte(`{"session_id":`), 0o600); err != nil {
		t.Fatalf("写入损坏 completed 状态失败: %v", err)
	}

	restarted, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	for index := 0; index < 4; index++ {
		sessionID := fmt.Sprintf("68000000-0000-4000-8000-%012d", index+1)
		if _, err := restarted.BeginUploadSessionForUser(sessionID, fmt.Sprintf("corrupt-quota-%d", index), 100, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
			t.Fatalf("损坏状态按 20 MiB 保守计额后，第 %d 份 reservation 应成功: %v", index+1, err)
		}
	}
	if _, err := restarted.BeginUploadSessionForUser("68000000-0000-4000-8000-000000000005", "corrupt-quota-4", 100, ExamPaperMaxFileSize, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUnclaimedQuotaExceeded) {
		t.Fatalf("损坏状态必须保守占用一份最大文件配额: %v", err)
	}
	if err := restarted.Claim(stored.FileKey); err != nil {
		t.Fatalf("损坏状态不得阻断其他文件 Claim: %v", err)
	}

	quarantined, err := restarted.Maintenance(now)
	if err != nil {
		t.Fatalf("隔离损坏状态失败: %v", err)
	}
	if quarantined.CorruptUploadSessionRecordsQuarantined != 1 {
		t.Fatalf("损坏状态隔离计数错误: %+v", quarantined)
	}
	quarantinePath := corruptPath + ".corrupt"
	if _, err := os.Stat(corruptPath); !os.IsNotExist(err) {
		t.Fatalf("损坏 completed 原路径应被隔离: %v", err)
	}
	if _, err := os.Stat(quarantinePath); err != nil {
		t.Fatalf("损坏 completed 隔离文件不存在: %v", err)
	}
	restartedAgain, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("再次重建文件服务失败: %v", err)
	}
	if _, err := restartedAgain.BeginUploadSessionForUser("69000000-0000-4000-8000-000000000001", "after-quarantine", 101, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
		t.Fatalf("隔离状态跨重启后不得全局阻断其他用户: %v", err)
	}
	old := now.Add(-7*24*time.Hour - time.Second)
	if err := os.Chtimes(quarantinePath, old, old); err != nil {
		t.Fatalf("设置隔离状态过期时间失败: %v", err)
	}
	removed, err := restartedAgain.Maintenance(now)
	if err != nil {
		t.Fatalf("清理过期隔离状态失败: %v", err)
	}
	if removed.CorruptUploadSessionRecordsRemoved != 1 {
		t.Fatalf("过期隔离状态清理计数错误: %+v", removed)
	}
	if _, err := os.Stat(quarantinePath); !os.IsNotExist(err) {
		t.Fatalf("过期隔离状态应被清理: %v", err)
	}
}

func TestPaperStorageSemanticCorruptActiveStatesReserveConservativeQuota(t *testing.T) {
	tests := []struct {
		name   string
		stage  string
		mutate func(map[string]any)
	}{
		{name: "completed空对象", stage: "completed", mutate: func(state map[string]any) { clear(state) }},
		{name: "completed错误状态", stage: "completed", mutate: func(state map[string]any) { state["status"] = "uploading" }},
		{name: "completed缺少回执", stage: "completed", mutate: func(state map[string]any) { delete(state, "receipt") }},
		{name: "completed大小越界", stage: "completed", mutate: func(state map[string]any) { state["expected_size"] = ExamPaperMaxFileSize + 1 }},
		{name: "uploading空对象", stage: "uploading", mutate: func(state map[string]any) { clear(state) }},
		{name: "uploading错误状态", stage: "uploading", mutate: func(state map[string]any) { state["status"] = "completed" }},
		{name: "uploading缺少JTI", stage: "uploading", mutate: func(state map[string]any) { delete(state, "jti") }},
		{name: "uploading大小越界", stage: "uploading", mutate: func(state map[string]any) { state["expected_size"] = ExamPaperMaxFileSize + 1 }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service, err := NewExamPaperFileService(t.TempDir())
			if err != nil {
				t.Fatalf("初始化文件服务失败: %v", err)
			}
			const corruptSessionID = "61000000-0000-4000-8000-000000000001"
			path := semanticSessionStatePath(service, corruptSessionID, tt.stage)
			payload := semanticSessionStatePayload(t, corruptSessionID, tt.stage, tt.mutate)
			if err := os.WriteFile(path, payload, 0o600); err != nil {
				t.Fatalf("写入语义损坏状态失败: %v", err)
			}
			now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
			for index := 0; index < 4; index++ {
				sessionID := fmt.Sprintf("62000000-0000-4000-8000-%012d", index+1)
				if _, err := service.BeginUploadSessionForUser(sessionID, fmt.Sprintf("semantic-quota-%d", index), 200, ExamPaperMaxFileSize, now.Add(time.Minute), now); err != nil {
					t.Fatalf("语义损坏状态保守计额后，第 %d 份 reservation 应成功: %v", index+1, err)
				}
			}
			if _, err := service.BeginUploadSessionForUser("62000000-0000-4000-8000-000000000005", "semantic-quota-5", 200, ExamPaperMaxFileSize, now.Add(time.Minute), now); !errors.Is(err, ErrExamPaperUnclaimedQuotaExceeded) {
				t.Fatalf("语义损坏状态必须为所有用户保守占用一份最大文件配额: %v", err)
			}
		})
	}
}

func TestPaperStorageMaintenanceQuarantinesSemanticCorruptStatesAcrossRestart(t *testing.T) {
	tests := []struct {
		name   string
		stage  string
		mutate func(map[string]any)
	}{
		{name: "completed空对象", stage: "completed", mutate: func(state map[string]any) { clear(state) }},
		{name: "completed错误状态", stage: "completed", mutate: func(state map[string]any) { state["status"] = "uploading" }},
		{name: "completed缺少session_id", stage: "completed", mutate: func(state map[string]any) { delete(state, "session_id") }},
		{name: "completed缺少JTI", stage: "completed", mutate: func(state map[string]any) { delete(state, "jti") }},
		{name: "completed缺少expected_size", stage: "completed", mutate: func(state map[string]any) { delete(state, "expected_size") }},
		{name: "completed缺少receipt", stage: "completed", mutate: func(state map[string]any) { delete(state, "receipt") }},
		{name: "completed非法大小", stage: "completed", mutate: func(state map[string]any) { state["expected_size"] = -1 }},
		{name: "completed文件名ID不匹配", stage: "completed", mutate: func(state map[string]any) { state["session_id"] = "61000000-0000-4000-8000-000000000099" }},
		{name: "completed缺少file_key", stage: "completed", mutate: func(state map[string]any) { delete(state, "file_key") }},
		{name: "completed缺少file_size", stage: "completed", mutate: func(state map[string]any) { delete(state, "file_size") }},
		{name: "completed文件大小不匹配", stage: "completed", mutate: func(state map[string]any) { state["file_size"] = 99 }},
		{name: "completed缺少sha256", stage: "completed", mutate: func(state map[string]any) { delete(state, "sha256") }},
		{name: "completed缺少completed_at", stage: "completed", mutate: func(state map[string]any) { delete(state, "completed_at") }},
		{name: "completed文件路径穿越", stage: "completed", mutate: func(state map[string]any) { state["file_key"] = "../paper.pdf" }},
		{name: "completed哈希长度错误", stage: "completed", mutate: func(state map[string]any) { state["sha256"] = strings.Repeat("a", 63) }},
		{name: "completed哈希非十六进制", stage: "completed", mutate: func(state map[string]any) { state["sha256"] = strings.Repeat("z", 64) }},
		{name: "uploading空对象", stage: "uploading", mutate: func(state map[string]any) { clear(state) }},
		{name: "uploading错误状态", stage: "uploading", mutate: func(state map[string]any) { state["status"] = "completed" }},
		{name: "uploading缺少JTI", stage: "uploading", mutate: func(state map[string]any) { delete(state, "jti") }},
		{name: "uploading缺少过期时间", stage: "uploading", mutate: func(state map[string]any) { delete(state, "expires_at") }},
		{name: "failure错误状态", stage: "failure", mutate: func(state map[string]any) { state["status"] = "uploading" }},
		{name: "failure缺少JTI", stage: "failure", mutate: func(state map[string]any) { delete(state, "jti") }},
		{name: "failure缺少expected_size", stage: "failure", mutate: func(state map[string]any) { delete(state, "expected_size") }},
		{name: "failure文件名ID不匹配", stage: "failure", mutate: func(state map[string]any) { state["session_id"] = "61000000-0000-4000-8000-000000000099" }},
		{name: "released缺少receipt", stage: "released", mutate: func(state map[string]any) { delete(state, "receipt") }},
		{name: "released缺少file_key", stage: "released", mutate: func(state map[string]any) { delete(state, "file_key") }},
		{name: "released缺少file_size", stage: "released", mutate: func(state map[string]any) { delete(state, "file_size") }},
		{name: "released文件大小不匹配", stage: "released", mutate: func(state map[string]any) { state["file_size"] = 99 }},
		{name: "released缺少sha256", stage: "released", mutate: func(state map[string]any) { delete(state, "sha256") }},
		{name: "released缺少completed_at", stage: "released", mutate: func(state map[string]any) { delete(state, "completed_at") }},
		{name: "released缺少released_at", stage: "released", mutate: func(state map[string]any) { delete(state, "released_at") }},
		{name: "released缺少user_id", stage: "released", mutate: func(state map[string]any) { delete(state, "user_id") }},
		{name: "released文件路径穿越", stage: "released", mutate: func(state map[string]any) { state["file_key"] = `..\paper.pdf` }},
		{name: "released哈希非十六进制", stage: "released", mutate: func(state map[string]any) { state["sha256"] = strings.Repeat("g", 64) }},
		{name: "released时间早于完成", stage: "released", mutate: func(state map[string]any) { state["released_at"] = time.Date(2026, 7, 12, 11, 59, 59, 0, time.UTC) }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			service, err := NewExamPaperFileService(root)
			if err != nil {
				t.Fatalf("初始化文件服务失败: %v", err)
			}
			const sessionID = "61000000-0000-4000-8000-000000000001"
			path := semanticSessionStatePath(service, sessionID, tt.stage)
			payload := semanticSessionStatePayload(t, sessionID, tt.stage, tt.mutate)
			if err := os.WriteFile(path, payload, 0o600); err != nil {
				t.Fatalf("写入语义损坏状态失败: %v", err)
			}

			restarted, err := NewExamPaperFileService(root)
			if err != nil {
				t.Fatalf("重建文件服务失败: %v", err)
			}
			now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
			result, err := restarted.Maintenance(now)
			if err != nil {
				t.Fatalf("隔离语义损坏状态失败: %v", err)
			}
			if result.CorruptUploadSessionRecordsQuarantined != 1 {
				t.Fatalf("语义损坏状态隔离计数错误: %+v", result)
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("语义损坏状态原路径应被隔离: %v", err)
			}
			if _, err := os.Stat(path + ".corrupt"); err != nil {
				t.Fatalf("语义损坏状态隔离文件不存在: %v", err)
			}

			restartedAgain, err := NewExamPaperFileService(root)
			if err != nil {
				t.Fatalf("再次重建文件服务失败: %v", err)
			}
			if _, err := restartedAgain.BeginUploadSessionForUser(sessionID, "after-semantic-quarantine", 42, 100, now.Add(time.Minute), now); err != nil {
				t.Fatalf("隔离后对应 session 不得永久处于 consumed 状态: %v", err)
			}
		})
	}
}

func TestPaperStorageMaintenanceQuarantinesCorruptReleasedStateBesideCompleted(t *testing.T) {
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	const sessionID = "63000000-0000-4000-8000-000000000001"
	const jti = "paired-corrupt-released-jti"
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	if _, err := service.BeginUploadSessionForUser(sessionID, jti, 42, 100, now.Add(time.Minute), now); err != nil {
		t.Fatalf("创建上传会话失败: %v", err)
	}
	stored := StoredExamPaperFile{FileKey: sessionID + ".pdf", Size: 100, SHA256: strings.Repeat("a", 64)}
	if err := service.CompleteUploadSession(sessionID, jti, "paired-released-receipt", stored, now); err != nil {
		t.Fatalf("完成上传会话失败: %v", err)
	}
	if err := service.ReleaseUploadSessionByFileKey(stored.FileKey, now.Add(time.Minute)); err != nil {
		t.Fatalf("释放上传会话失败: %v", err)
	}
	releasedPath := service.uploadSessionPath(sessionID, "released")
	payload := semanticSessionStatePayload(t, sessionID, "released", func(state map[string]any) {
		state["released_at"] = now.Add(-time.Second)
	})
	if err := os.WriteFile(releasedPath, payload, 0o600); err != nil {
		t.Fatalf("写入损坏 released 状态失败: %v", err)
	}

	result, err := service.Maintenance(now.Add(2 * time.Minute))
	if err != nil {
		t.Fatalf("维护与 completed 并存的损坏 released 状态失败: %v", err)
	}
	if result.CorruptUploadSessionRecordsQuarantined != 1 {
		t.Fatalf("损坏 released 状态隔离计数错误: %+v", result)
	}
	if _, err := os.Stat(releasedPath + ".corrupt"); err != nil {
		t.Fatalf("损坏 released 状态未被隔离: %v", err)
	}
	if _, err := os.Stat(service.uploadSessionPath(sessionID, "completed")); err != nil {
		t.Fatalf("隔离 released 时不得删除 completed: %v", err)
	}
}

func semanticSessionStatePath(service *ExamPaperFileService, sessionID, stage string) string {
	if stage == "failure" {
		return service.uploadSessionFailurePath(sessionID, 1)
	}
	return service.uploadSessionPath(sessionID, stage)
}

func semanticSessionStatePayload(t *testing.T, sessionID, stage string, mutate func(map[string]any)) []byte {
	t.Helper()
	status := stage
	if stage == "failure" {
		status = "failed"
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	state := map[string]any{
		"session_id": sessionID, "jti": "semantic-state-jti", "user_id": 1,
		"expected_size": 100, "expires_at": now.Add(time.Hour), "status": status,
		"created_at": now, "updated_at": now,
	}
	if stage == "completed" || stage == "released" {
		state["receipt"] = "semantic-state-receipt"
		state["file_key"] = sessionID + ".pdf"
		state["file_size"] = 100
		state["sha256"] = strings.Repeat("a", 64)
		state["completed_at"] = now
	}
	if stage == "released" {
		state["released_at"] = now.Add(time.Minute)
	}
	mutate(state)
	payload, err := json.Marshal(state)
	if err != nil {
		t.Fatalf("编码测试会话状态失败: %v", err)
	}
	return payload
}

func TestPaperStorageMaintenanceRemovesCrashedSessionStateTempAcrossRestart(t *testing.T) {
	root := t.TempDir()
	_, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	tempPath := filepath.Join(root, ".sessions", ".session-state-crash.tmp")
	if err := os.WriteFile(tempPath, []byte(`{"partial":`), 0o600); err != nil {
		t.Fatalf("写入崩溃临时状态失败: %v", err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	old := now.Add(-time.Hour - time.Second)
	if err := os.Chtimes(tempPath, old, old); err != nil {
		t.Fatalf("设置临时状态过期时间失败: %v", err)
	}
	restarted, err := NewExamPaperFileService(root)
	if err != nil {
		t.Fatalf("重建文件服务失败: %v", err)
	}
	result, err := restarted.Maintenance(now)
	if err != nil {
		t.Fatalf("维护崩溃临时状态失败: %v", err)
	}
	if result.UploadSessionTempFilesRemoved != 1 {
		t.Fatalf("崩溃临时状态清理计数错误: %+v", result)
	}
	if _, err := os.Stat(tempPath); !os.IsNotExist(err) {
		t.Fatalf("过期崩溃临时状态应被清理: %v", err)
	}
}

func TestPaperStorageMaintenanceRemovesCompletedStateWithExpiredUnclaimedFile(t *testing.T) {
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	service, err := NewExamPaperFileService(t.TempDir())
	if err != nil {
		t.Fatalf("初始化文件服务失败: %v", err)
	}
	stored, err := service.StoreUploadReader("paper.pdf", bytes.NewReader(buildMinimalPDF()))
	if err != nil {
		t.Fatalf("保存待认领文件失败: %v", err)
	}
	if err := service.MarkPending(stored.FileKey); err != nil {
		t.Fatalf("创建 pending 标记失败: %v", err)
	}
	const sessionID = "42000000-0000-4000-8000-000000000001"
	const jti = "maintenance-state"
	if _, err := service.BeginUploadSessionForUser(sessionID, jti, 79, stored.Size, now.Add(time.Minute), now); err != nil {
		t.Fatalf("创建上传会话失败: %v", err)
	}
	if err := service.CompleteUploadSession(sessionID, jti, "receipt-maintenance", *stored, now); err != nil {
		t.Fatalf("完成上传会话失败: %v", err)
	}
	old := now.Add(-7*24*time.Hour - time.Second)
	if err := os.Chtimes(filepath.Join(service.RootDir(), ".pending", stored.FileKey), old, old); err != nil {
		t.Fatalf("设置旧 pending 标记时间失败: %v", err)
	}

	result, err := service.Maintenance(now)
	if err != nil {
		t.Fatalf("执行维护失败: %v", err)
	}
	if result.UnclaimedFilesRemoved != 1 || result.CompletedUploadSessionsRemoved != 1 {
		t.Fatalf("维护计数错误: %+v", result)
	}
	completedPath := filepath.Join(service.RootDir(), ".sessions", sessionID+".completed.json")
	if _, err := os.Stat(completedPath); !os.IsNotExist(err) {
		t.Fatalf("过期未认领文件的 completed 状态应同步删除: %v", err)
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
	t.Run("sessions", func(t *testing.T) {
		root := t.TempDir()
		if err := os.Symlink(t.TempDir(), filepath.Join(root, ".sessions")); err != nil {
			t.Skipf("无法创建 symlink: %v", err)
		}
		if _, err := NewExamPaperFileService(root); err == nil {
			t.Fatal("sessions symlink 应被拒绝")
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
