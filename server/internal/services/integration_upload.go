package services

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

type IntegrationGrade struct {
	CourseName   string   `json:"course_name"`
	Score        string   `json:"score"`
	Credits      float64  `json:"credits"`
	GPA          *float64 `json:"gpa,omitempty"`
	CourseNature string   `json:"course_nature,omitempty"`
}
type IntegrationGradesUpload struct {
	Consent   bool               `json:"consent"`
	FetchedAt time.Time          `json:"fetched_at"`
	Year      string             `json:"year"`
	Semester  int                `json:"semester"`
	Grades    []IntegrationGrade `json:"grades"`
}
type integrationUploadedGrades struct {
	AcademicID      uint                     `json:"academic_binding_id"`
	AcademicVersion uint                     `json:"academic_version"`
	Grades          []map[string]interface{} `json:"grades"`
	CoveredTerms    []map[string]interface{} `json:"covered_terms"`
}

// StoreUploadedGrades 不收学校凭据，且不能把用户上传的资料标成学校实时来源。
func (s *IntegrationAuthService) StoreUploadedGrades(ctx context.Context, owner uint, input IntegrationGradesUpload) error {
	if !input.Consent || input.FetchedAt.IsZero() || input.FetchedAt.After(s.Now().Add(5*time.Minute)) || len(input.Year) < 4 || len(input.Year) > 16 || (input.Semester != 3 && input.Semester != 12 && input.Semester != 16) || len(input.Grades) > 1000 {
		return integrationError("invalid_personal_upload", 422)
	}
	for _, grade := range input.Grades {
		if strings.TrimSpace(grade.CourseName) == "" || len(grade.CourseName) > 200 || len(grade.Score) > 40 || len(grade.CourseNature) > 80 || math.IsNaN(grade.Credits) || math.IsInf(grade.Credits, 0) || grade.Credits < 0 || grade.Credits > 100 || (grade.GPA != nil && (math.IsNaN(*grade.GPA) || math.IsInf(*grade.GPA, 0) || *grade.GPA < 0 || *grade.GPA > 10)) {
			return integrationError("invalid_personal_upload", 422)
		}
	}
	return s.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		identity, err := s.eligible(tx, user, nil)
		if err != nil {
			return err
		}
		policy, err := NewAIUserPermissionService(tx).Policy(ctx, owner, models.AIUserPermissionAcademicCloudStorage)
		if err != nil {
			return err
		}
		if policy == models.AIUserPermissionNever {
			return integrationError("personal_data_disabled", 403)
		}
		rows := make([]map[string]interface{}, 0, len(input.Grades))
		for _, grade := range input.Grades {
			row := map[string]interface{}{"course_name": grade.CourseName, "score": grade.Score, "credits": grade.Credits, "course_nature": grade.CourseNature, "year": input.Year, "semester": input.Semester}
			if grade.GPA != nil {
				row["gpa"] = *grade.GPA
			}
			rows = append(rows, row)
		}
		payload, err := json.Marshal(integrationUploadedGrades{identity.ID, identity.BindingVersion, rows, []map[string]interface{}{{"year": input.Year, "semester": input.Semester, "course_count": len(rows)}}})
		if err != nil {
			return err
		}
		snapshot := models.PersonalUploadedSnapshot{UserID: owner, SnapshotType: "integration_grades", SchemaVersion: 1, PayloadJSON: datatypes.JSON(payload), PayloadHash: hashPersonalSnapshot(payload), FetchedAt: input.FetchedAt, ExpiresAt: input.FetchedAt.Add(5 * 24 * time.Hour), IsPartial: true}
		var previous models.PersonalUploadedSnapshot
		if err := tx.Where("user_id = ? AND snapshot_type = ?", owner, snapshot.SnapshotType).Take(&previous).Error; err == nil {
			if previous.FetchedAt.After(snapshot.FetchedAt) {
				return integrationError("older_snapshot_rejected", 409)
			}
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if err := tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "user_id"}, {Name: "snapshot_type"}}, DoUpdates: clause.AssignmentColumns([]string{"schema_version", "payload_json", "payload_hash", "fetched_at", "expires_at", "is_partial", "updated_at"})}).Create(&snapshot).Error; err != nil {
			return err
		}
		return tx.Create(&models.IntegrationAudit{OwnerID: owner, ActorID: owner, Event: "grades_synced", CreatedAt: s.Now()}).Error
	})
}

func (s *IntegrationAuthService) uploadedGrades(ctx context.Context, tx *gorm.DB, b models.IntegrationBinding) (academic.SnapshotLookup, error) {
	var row models.PersonalUploadedSnapshot
	err := tx.WithContext(ctx).Where("user_id = ? AND snapshot_type = ?", b.OwnerID, "integration_grades").Take(&row).Error
	if err == gorm.ErrRecordNotFound {
		return academic.SnapshotLookup{}, nil
	}
	if err != nil {
		return academic.SnapshotLookup{}, err
	}
	if hashPersonalSnapshot(row.PayloadJSON) != row.PayloadHash {
		return academic.SnapshotLookup{}, ErrAcademicSnapshotCorrupted
	}
	var payload integrationUploadedGrades
	if json.Unmarshal(row.PayloadJSON, &payload) != nil {
		return academic.SnapshotLookup{}, ErrAcademicSnapshotCorrupted
	}
	if payload.AcademicID != b.AcademicBindingID || payload.AcademicVersion != b.AcademicVersion {
		return academic.SnapshotLookup{}, nil
	}
	result, err := academic.NewContextResult(payload, academic.DataStatusPartial, academic.DataSourceUserUploadedSnapshot)
	if err != nil {
		return academic.SnapshotLookup{}, err
	}
	result.FetchedAt = &row.FetchedAt
	result.ExpiresAt = &row.ExpiresAt
	result.IsStale = !row.ExpiresAt.After(s.Now())
	result.IsPartial = true
	if result.IsStale {
		result.Status = academic.DataStatusStale
	}
	return academic.SnapshotLookup{Found: true, Result: result}, nil
}

func (s *IntegrationAuthService) DeleteUploadedGrades(ctx context.Context, owner uint) error {
	return s.ownerTx(ctx, owner, func(tx *gorm.DB, _ models.User) error {
		if err := tx.Where("user_id = ? AND snapshot_type = ?", owner, "integration_grades").Delete(&models.PersonalUploadedSnapshot{}).Error; err != nil {
			return err
		}
		return tx.Create(&models.IntegrationAudit{OwnerID: owner, ActorID: owner, Event: "grades_sync_deleted", CreatedAt: s.Now()}).Error
	})
}
