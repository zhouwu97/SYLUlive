package services

import (
	"context"
	"encoding/json"
	"errors"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// AcademicSnapshotBackfillReport 是一次哈希回填的审计摘要。
type AcademicSnapshotBackfillReport struct {
	Total   int
	Updated int
	Skipped int
}

// BackfillAcademicSnapshotHashes 对历史学业快照按 JSON 语义重新计算哈希。
// apply=false 时只检查，不写入；调用方应在数据库备份并验证后才允许 apply=true。
func BackfillAcademicSnapshotHashes(ctx context.Context, db *gorm.DB, apply bool) (AcademicSnapshotBackfillReport, error) {
	if db == nil {
		return AcademicSnapshotBackfillReport{}, errors.New("数据库未配置")
	}
	var report AcademicSnapshotBackfillReport
	var snapshots []models.AcademicSnapshot
	if err := db.WithContext(ctx).FindInBatches(&snapshots, 200, func(batch *gorm.DB, _ int) error {
		for index := range snapshots {
			report.Total++
			payload := []byte(snapshots[index].PayloadJSON)
			if !json.Valid(payload) {
				report.Skipped++
				continue
			}
			canonical, err := canonicalAcademicPayload(payload)
			if err != nil {
				report.Skipped++
				continue
			}
			hash := academicPayloadHash(canonical)
			if snapshots[index].PayloadHash == hash {
				continue
			}
			if apply {
				if err := batch.Model(&models.AcademicSnapshot{}).
					Where("id = ?", snapshots[index].ID).
					Update("payload_hash", hash).Error; err != nil {
					return err
				}
			}
			report.Updated++
		}
		return nil
	}).Error; err != nil {
		return report, err
	}
	return report, nil
}
