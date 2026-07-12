package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const defaultMigrationPageSize = 100

type migrationRemote interface {
	Metadata(context.Context, string) (services.StoredExamPaperFile, error)
}

type migrationOptions struct {
	Apply        bool
	ID           uint
	PageSize     int
	BeforeUpdate func(models.ExamPaper)
}

type migrationSummary struct {
	Scanned           int
	Verified          int
	Updated           int
	Failed            int
	ConcurrentChanges int
}

type explicitBool struct {
	value bool
	set   bool
}

func (b *explicitBool) String() string   { return fmt.Sprint(b.value) }
func (b *explicitBool) IsBoolFlag() bool { return true }
func (b *explicitBool) Set(value string) error {
	parsed, err := parseBool(value)
	if err != nil {
		return err
	}
	b.value, b.set = parsed, true
	return nil
}

func parseBool(value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true", "1":
		return true, nil
	case "false", "0":
		return false, nil
	default:
		return false, fmt.Errorf("布尔参数值无效: %q", value)
	}
}

func main() {
	options, err := parseMigrationFlags(os.Args[1:])
	if err != nil {
		log.Printf("参数错误: %v", err)
		os.Exit(2)
	}
	cfg := config.Load()
	db, err := openMigrationDB(cfg.DSN)
	if err != nil {
		log.Printf("连接数据库失败: %v", err)
		os.Exit(1)
	}
	grantSigner, err := services.NewExamPaperStorageSigner(cfg.ExamPaperStorageSigningSecret, time.Now)
	if err != nil {
		log.Printf("初始化试卷存储授权失败: %v", err)
		os.Exit(1)
	}
	remote, err := services.NewExamPaperRemoteClient(cfg.ExamPaperStorageBaseURL, grantSigner, nil, time.Now)
	if err != nil {
		log.Printf("初始化试卷远端客户端失败: %v", err)
		os.Exit(1)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if _, err := runMigration(ctx, db, remote, cfg.ExamPaperDir, options, os.Stdout); err != nil {
		log.Printf("迁移未全部成功: %v", err)
		os.Exit(1)
	}
}

func parseMigrationFlags(args []string) (migrationOptions, error) {
	set := flag.NewFlagSet("migrate_exam_papers_remote", flag.ContinueOnError)
	set.SetOutput(io.Discard)
	var apply, dryRun explicitBool
	var id uint
	var pageSize int
	set.Var(&apply, "apply", "校验一致后更新数据库")
	set.Var(&dryRun, "dry-run", "只校验，不更新数据库（默认）")
	set.UintVar(&id, "id", 0, "只迁移指定试卷 ID")
	set.IntVar(&pageSize, "page-size", defaultMigrationPageSize, "批量查询分页大小")
	if err := set.Parse(args); err != nil {
		return migrationOptions{}, err
	}
	if set.NArg() != 0 {
		return migrationOptions{}, fmt.Errorf("不支持位置参数")
	}
	if apply.set && dryRun.set {
		return migrationOptions{}, fmt.Errorf("--apply 与 --dry-run 不能同时使用")
	}
	if id == 0 && flagProvided(args, "id") {
		return migrationOptions{}, fmt.Errorf("--id 必须大于 0")
	}
	if pageSize < 1 || pageSize > 1000 {
		return migrationOptions{}, fmt.Errorf("--page-size 必须在 1 到 1000 之间")
	}
	return migrationOptions{Apply: apply.value && !(dryRun.set && dryRun.value), ID: id, PageSize: pageSize}, nil
}

func flagProvided(args []string, name string) bool {
	prefix := "--" + name
	for _, arg := range args {
		if arg == prefix || strings.HasPrefix(arg, prefix+"=") {
			return true
		}
	}
	return false
}

func openMigrationDB(dsn string) (*gorm.DB, error) {
	var dialector gorm.Dialector = sqlite.Open(dsn)
	if strings.Contains(dsn, "host=") || strings.Contains(dsn, "port=") {
		dialector = postgres.Open(dsn)
	}
	return gorm.Open(dialector, &gorm.Config{})
}

func runMigration(ctx context.Context, db *gorm.DB, remote migrationRemote, root string, options migrationOptions, output io.Writer) (migrationSummary, error) {
	var summary migrationSummary
	if db == nil || remote == nil || strings.TrimSpace(root) == "" || options.PageSize < 1 {
		return summary, fmt.Errorf("迁移参数不完整")
	}
	if output == nil {
		output = io.Discard
	}
	root, err := secureMigrationRoot(root)
	if err != nil {
		return summary, err
	}
	var lastID uint
	for {
		if err := ctx.Err(); err != nil {
			writeSummary(output, summary, options.Apply)
			return summary, err
		}
		papers, err := loadMigrationPage(ctx, db, options, lastID)
		if err != nil {
			writeSummary(output, summary, options.Apply)
			return summary, err
		}
		if len(papers) == 0 {
			break
		}
		for _, paper := range papers {
			if err := ctx.Err(); err != nil {
				writeSummary(output, summary, options.Apply)
				return summary, err
			}
			summary.Scanned++
			if err := migrateExamPaper(ctx, db, remote, root, paper, options, &summary); err != nil {
				summary.Failed++
				fmt.Fprintf(output, "试卷 id=%d 校验失败: %v\n", paper.ID, err)
				continue
			}
			summary.Verified++
		}
		lastID = papers[len(papers)-1].ID
		if options.ID != 0 || len(papers) < options.PageSize {
			break
		}
	}
	writeSummary(output, summary, options.Apply)
	if options.ID != 0 && summary.Scanned == 0 {
		return summary, fmt.Errorf("未找到符合迁移条件的试卷 id=%d", options.ID)
	}
	if summary.Failed > 0 {
		return summary, fmt.Errorf("%d 份试卷迁移失败", summary.Failed)
	}
	return summary, nil
}

func loadMigrationPage(ctx context.Context, db *gorm.DB, options migrationOptions, lastID uint) ([]models.ExamPaper, error) {
	query := db.WithContext(ctx).
		Where("storage_backend = ? AND status IN ? AND file_key <> '' AND id > ?",
			models.ExamPaperStorageLocal,
			[]models.ExamPaperStatus{models.ExamPaperStatusPending, models.ExamPaperStatusPublished},
			lastID).
		Order("id ASC").Limit(options.PageSize)
	if options.ID != 0 {
		query = query.Where("id = ?", options.ID)
	}
	var papers []models.ExamPaper
	if err := query.Find(&papers).Error; err != nil {
		return nil, fmt.Errorf("读取待迁移试卷失败: %w", err)
	}
	return papers, nil
}

func migrateExamPaper(ctx context.Context, db *gorm.DB, remote migrationRemote, root string, paper models.ExamPaper, options migrationOptions, summary *migrationSummary) error {
	local, err := localMetadata(root, paper.FileKey)
	if err != nil {
		return fmt.Errorf("读取本地文件失败: %w", err)
	}
	remoteMetadata, err := remote.Metadata(ctx, paper.FileKey)
	if err != nil {
		return fmt.Errorf("读取远端元数据失败: %w", err)
	}
	if local.Size != paper.FileSize || !strings.EqualFold(local.SHA256, paper.SHA256) {
		return fmt.Errorf("数据库记录的大小或 SHA-256 与本地文件不一致")
	}
	if local.FileKey != remoteMetadata.FileKey || local.Size != remoteMetadata.Size || !strings.EqualFold(local.SHA256, remoteMetadata.SHA256) {
		return fmt.Errorf("远端文件 key、大小或 SHA-256 与本地不一致")
	}
	if !options.Apply {
		return nil
	}
	if options.BeforeUpdate != nil {
		options.BeforeUpdate(paper)
	}
	result := db.WithContext(ctx).Model(&models.ExamPaper{}).
		Where("id = ? AND storage_backend = ? AND status IN ? AND file_key = ? AND file_size = ? AND LOWER(sha256) = ?",
			paper.ID, models.ExamPaperStorageLocal,
			[]models.ExamPaperStatus{models.ExamPaperStatusPending, models.ExamPaperStatusPublished},
			paper.FileKey, paper.FileSize, strings.ToLower(paper.SHA256)).
		Update("storage_backend", models.ExamPaperStorageRemote)
	if result.Error != nil {
		return fmt.Errorf("更新存储后端失败: %w", result.Error)
	}
	if result.RowsAffected != 1 {
		summary.ConcurrentChanges++
		return fmt.Errorf("记录状态已并发变化，未更新")
	}
	summary.Updated++
	return nil
}

func secureMigrationRoot(root string) (string, error) {
	absolute, err := filepath.Abs(filepath.Clean(root))
	if err != nil {
		return "", fmt.Errorf("解析试卷目录失败: %w", err)
	}
	for current := absolute; ; current = filepath.Dir(current) {
		info, statErr := os.Lstat(current)
		if statErr != nil {
			return "", fmt.Errorf("检查试卷目录失败: %w", statErr)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("试卷目录及其父目录不能包含符号链接")
		}
		if current == absolute && !info.IsDir() {
			return "", fmt.Errorf("试卷目录必须是目录")
		}
		if parent := filepath.Dir(current); parent == current {
			break
		}
	}
	return absolute, nil
}

func localMetadata(root, fileKey string) (services.StoredExamPaperFile, error) {
	if fileKey == "" || fileKey == "." || fileKey == ".." || filepath.Base(fileKey) != fileKey || strings.ContainsAny(fileKey, `/\`) {
		return services.StoredExamPaperFile{}, fmt.Errorf("文件 key 无效")
	}
	root, err := secureMigrationRoot(root)
	if err != nil {
		return services.StoredExamPaperFile{}, err
	}
	path := filepath.Join(root, fileKey)
	info, err := os.Lstat(path)
	if err != nil {
		return services.StoredExamPaperFile{}, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return services.StoredExamPaperFile{}, fmt.Errorf("试卷文件必须是非符号链接普通文件")
	}
	file, err := os.Open(path)
	if err != nil {
		return services.StoredExamPaperFile{}, err
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil {
		return services.StoredExamPaperFile{}, err
	}
	if !os.SameFile(info, openedInfo) || !openedInfo.Mode().IsRegular() {
		return services.StoredExamPaperFile{}, errors.New("试卷文件在打开期间发生变化")
	}
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return services.StoredExamPaperFile{}, err
	}
	return services.StoredExamPaperFile{FileKey: fileKey, Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}

func writeSummary(output io.Writer, summary migrationSummary, apply bool) {
	mode := "dry-run"
	if apply {
		mode = "apply"
	}
	fmt.Fprintf(output, "summary mode=%s scanned=%d verified=%d updated=%d failed=%d concurrent_changes=%d\n",
		mode, summary.Scanned, summary.Verified, summary.Updated, summary.Failed, summary.ConcurrentChanges)
}
