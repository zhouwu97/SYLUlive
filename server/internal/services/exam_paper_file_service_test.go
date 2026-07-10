package services

import (
	"bytes"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

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
