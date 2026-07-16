package services

import (
	"context"
	"errors"
	"fmt"
	"log"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const (
	examPaperStorageMaintenancePageSize = 100
	examPaperStorageMaintenanceIssueCap = 100
)

// ExamPaperStorageMaintenanceRemote 定义完整性核对所需的远端查询与维护操作。
type ExamPaperStorageMaintenanceRemote interface {
	Metadata(context.Context, string) (StoredExamPaperFile, error)
	Maintenance(context.Context) (ExamPaperRemoteMaintenanceResult, error)
}

// ExamPaperStorageMaintenanceIssue 描述单个业务引用的完整性异常。
type ExamPaperStorageMaintenanceIssue struct {
	PaperID uint   `json:"paper_id"`
	FileKey string `json:"file_key"`
	Kind    string `json:"kind"`
	Detail  string `json:"detail"`
}

// ExamPaperStorageMaintenanceReport 汇总业务引用核对和远端清理结果。
type ExamPaperStorageMaintenanceReport struct {
	Referenced         int                                `json:"referenced"`
	Missing            int                                `json:"missing"`
	Mismatched         int                                `json:"mismatched"`
	MetadataErrors     int                                `json:"metadata_errors"`
	OrphanFilesRemoved int                                `json:"orphan_files_removed"`
	TrashFilesRemoved  int                                `json:"trash_files_removed"`
	DiskUsagePercent   float64                            `json:"disk_usage_percent"`
	Remote             ExamPaperRemoteMaintenanceResult   `json:"remote"`
	Issues             []ExamPaperStorageMaintenanceIssue `json:"issues,omitempty"`
	DroppedIssues      int                                `json:"dropped_issues"`
}

// ExamPaperStorageMaintenanceLogger 接收结构化维护异常。
type ExamPaperStorageMaintenanceLogger func(ExamPaperStorageMaintenanceIssue)

// ExamPaperStorageMaintenance 执行远端有效引用的每日完整性核对。
type ExamPaperStorageMaintenance struct {
	db     *gorm.DB
	remote ExamPaperStorageMaintenanceRemote
	log    ExamPaperStorageMaintenanceLogger
}

// NewExamPaperStorageMaintenance 创建每日维护服务。
func NewExamPaperStorageMaintenance(db *gorm.DB, remote ExamPaperStorageMaintenanceRemote, logger ExamPaperStorageMaintenanceLogger) *ExamPaperStorageMaintenance {
	if logger == nil {
		logger = func(issue ExamPaperStorageMaintenanceIssue) {
			log.Printf("exam_paper_storage_issue paper_id=%d file_key=%q kind=%s detail=%q", issue.PaperID, issue.FileKey, issue.Kind, issue.Detail)
		}
	}
	return &ExamPaperStorageMaintenance{db: db, remote: remote, log: logger}
}

// Run 核对所有仍有效的远端试卷；单文件异常记录后继续，不修改业务记录。
func (s *ExamPaperStorageMaintenance) Run(ctx context.Context) (ExamPaperStorageMaintenanceReport, error) {
	var report ExamPaperStorageMaintenanceReport
	if err := ctx.Err(); err != nil {
		return report, err
	}
	if s.remote == nil {
		return report, errors.New("试卷远端维护客户端未配置")
	}
	var lastID uint
	for {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		var papers []models.ExamPaper
		if err := s.db.WithContext(ctx).Model(&models.ExamPaper{}).
			Select("id", "file_key", "file_size", "sha256").
			Where("storage_backend = ? AND status IN ? AND id > ?", models.ExamPaperStorageRemote, []models.ExamPaperStatus{models.ExamPaperStatusPending, models.ExamPaperStatusPublished}, lastID).
			Order("id ASC").Limit(examPaperStorageMaintenancePageSize).Find(&papers).Error; err != nil {
			return report, err
		}
		if len(papers) == 0 {
			break
		}
		for _, paper := range papers {
			if err := ctx.Err(); err != nil {
				return report, err
			}
			report.Referenced++
			metadata, err := s.remote.Metadata(ctx, paper.FileKey)
			if err != nil {
				if contextErr := ctx.Err(); contextErr != nil {
					return report, contextErr
				}
				kind := "metadata_error"
				if errors.Is(err, ErrExamPaperRemoteNotFound) {
					kind = "missing"
					report.Missing++
				} else {
					report.MetadataErrors++
				}
				s.recordIssue(&report, paper, kind, err.Error())
				continue
			}
			if metadata.FileKey != paper.FileKey || metadata.Size != paper.FileSize || metadata.SHA256 != paper.SHA256 {
				report.Mismatched++
				detail := fmt.Sprintf("expected_size=%d actual_size=%d expected_sha256=%s actual_sha256=%s", paper.FileSize, metadata.Size, paper.SHA256, metadata.SHA256)
				s.recordIssue(&report, paper, "mismatch", detail)
			}
		}
		lastID = papers[len(papers)-1].ID
		if len(papers) < examPaperStorageMaintenancePageSize {
			break
		}
	}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	remoteReport, err := s.remote.Maintenance(ctx)
	if err != nil {
		return report, err
	}
	report.Remote = remoteReport
	report.OrphanFilesRemoved = remoteReport.UnclaimedFilesRemoved
	report.TrashFilesRemoved = remoteReport.TrashFilesRemoved
	report.DiskUsagePercent = remoteReport.DiskUsagePercent
	return report, nil
}

func (s *ExamPaperStorageMaintenance) recordIssue(report *ExamPaperStorageMaintenanceReport, paper models.ExamPaper, kind, detail string) {
	issue := ExamPaperStorageMaintenanceIssue{PaperID: paper.ID, FileKey: paper.FileKey, Kind: kind, Detail: detail}
	if len(report.Issues) < examPaperStorageMaintenanceIssueCap {
		report.Issues = append(report.Issues, issue)
	} else {
		report.DroppedIssues++
	}
	s.log(issue)
}
