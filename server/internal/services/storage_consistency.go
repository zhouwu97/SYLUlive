package services

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// StorageConsistencyReport 描述 DB 记录、物理文件和业务引用之间的不一致。
type StorageConsistencyReport struct {
	DBFiles             int
	PhysicalFiles       int
	MissingPhysical     int
	OrphanPhysical      int
	TemporaryReferenced int
	TemporaryClaimed    int
}

// StorageConsistencyScanner 只报告异常，不自动修复或删除文件。
type StorageConsistencyScanner struct {
	db        *gorm.DB
	uploadDir string
}

// NewStorageConsistencyScanner 创建存储一致性巡检器。
func NewStorageConsistencyScanner(db *gorm.DB, uploadDir string) *StorageConsistencyScanner {
	root := strings.TrimSpace(uploadDir)
	if root == "" {
		root = strings.TrimSpace(os.Getenv("UPLOAD_DIR"))
		if root == "" {
			root = "uploads"
		}
	}
	if absolute, err := filepath.Abs(filepath.Clean(root)); err == nil {
		root = absolute
	}
	return &StorageConsistencyScanner{db: db, uploadDir: root}
}

// Run 扫描 files 表和 uploads 目录。派生图片变体、表情缩略图也加入已知路径，
// 避免把合法派生文件误报为孤儿；扫描不改变任何业务数据。
func (s *StorageConsistencyScanner) Run(ctx context.Context) (StorageConsistencyReport, error) {
	var report StorageConsistencyReport
	if s == nil || s.db == nil {
		return report, fmt.Errorf("存储一致性巡检器未初始化")
	}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	known := make(map[string]struct{})
	var files []models.File
	if err := s.db.WithContext(ctx).Find(&files).Error; err != nil {
		return report, err
	}
	report.DBFiles = len(files)
	for _, file := range files {
		path, err := ResolveUploadPath(s.uploadDir, file.Path)
		if err != nil {
			continue
		}
		known[s.relativePath(path)] = struct{}{}
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				report.MissingPhysical++
			}
		}
		if file.Status == models.FileStatusTemporary {
			if file.ClaimedAt != nil {
				report.TemporaryClaimed++
			}
			referenced, refErr := hasBusinessFileReference(s.db, file.ID, func(table string) bool {
				return s.db.Migrator().HasTable(table)
			})
			if refErr != nil {
				return report, refErr
			}
			if referenced {
				report.TemporaryReferenced++
			}
		}
	}
	s.collectDerivedPaths(known)

	err := filepath.WalkDir(s.uploadDir, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == ".trash" {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			// 巡检不跟随符号链接，避免把 uploads 之外的文件纳入统计。
			return nil
		}
		report.PhysicalFiles++
		if _, ok := known[s.relativePath(path)]; !ok {
			report.OrphanPhysical++
		}
		return nil
	})
	if err != nil {
		return report, err
	}
	return report, nil
}

func (s *StorageConsistencyScanner) relativePath(path string) string {
	relative, err := filepath.Rel(s.uploadDir, path)
	if err != nil {
		return ""
	}
	return filepath.ToSlash(filepath.Clean(relative))
}

func (s *StorageConsistencyScanner) collectDerivedPaths(known map[string]struct{}) {
	if s.db.Migrator().HasTable("image_variants") {
		var rows []struct{ Path string }
		if err := s.db.Table("image_variants").Select("path").Find(&rows).Error; err == nil {
			for _, row := range rows {
				if path, err := ResolveUploadPath(s.uploadDir, row.Path); err == nil {
					known[s.relativePath(path)] = struct{}{}
				}
			}
		}
	}
	if s.db.Migrator().HasTable("user_emoji_assets") {
		var rows []struct{ ThumbnailPath string }
		if err := s.db.Table("user_emoji_assets").Select("thumbnail_path").Where("thumbnail_path <> ''").Find(&rows).Error; err == nil {
			for _, row := range rows {
				if path, err := ResolveUploadPath(s.uploadDir, row.ThumbnailPath); err == nil && strings.TrimSpace(row.ThumbnailPath) != "" {
					known[s.relativePath(path)] = struct{}{}
				}
			}
		}
	}
}
