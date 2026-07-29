package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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

const (
	PersonalSnapshotTypeErke = "erke"
	maxErkeSnapshotBytes     = 512 * 1024
	erkeSnapshotTTL          = 5 * 24 * time.Hour
)

var (
	ErrPersonalSnapshotNotFound = errors.New("个人快照不存在")
	ErrInvalidPersonalSnapshot  = errors.New("个人快照无效")
)

// ErkeSnapshotUpload 是客户端允许上传的最小二课结构。所有字段都是解析后的 JSON，
// 不接收密码、Cookie、会话或原始 HTML。
type ErkeSnapshotUpload struct {
	SchemaVersion    int                   `json:"schema_version"`
	FetchedAt        time.Time             `json:"fetched_at"`
	Graduation       ErkeGraduationSummary `json:"graduation"`
	Yearly           ErkeYearlySummary     `json:"yearly"`
	RecentActivities []ErkeActivitySummary `json:"recent_activities"`
}
type ErkeCategorySummary struct {
	Name string  `json:"name"`
	Gap  float64 `json:"gap"`
}
type ErkeGraduationSummary struct {
	EarnedTotal        *float64              `json:"earned_total,omitempty"`
	RequiredTotal      *float64              `json:"required_total,omitempty"`
	GraduationGap      *float64              `json:"graduation_gap,omitempty"`
	UnmetCategories    []ErkeCategorySummary `json:"unmet_categories"`
	OfficialConclusion string                `json:"official_conclusion,omitempty"`
}
type ErkeYearlySummary struct {
	Year               string   `json:"year,omitempty"`
	EarnedTotal        *float64 `json:"earned_total,omitempty"`
	RequiredTotal      *float64 `json:"required_total,omitempty"`
	YearlyGap          *float64 `json:"yearly_gap,omitempty"`
	OfficialConclusion string   `json:"official_conclusion,omitempty"`
}
type ErkeActivitySummary struct {
	Category string   `json:"category"`
	Score    *float64 `json:"score,omitempty"`
	Date     string   `json:"date,omitempty"`
}

// PersonalSnapshotService 管理用户明确授权上传的二课快照。
type PersonalSnapshotService struct {
	db  *gorm.DB
	now func() time.Time
}

func NewPersonalSnapshotService(db *gorm.DB, now func() time.Time) *PersonalSnapshotService {
	if now == nil {
		now = time.Now
	}
	return &PersonalSnapshotService{db: db, now: now}
}

// StoreErke 用计算后的哈希原子写入二课快照。客户端传来的哈希不会被信任。
func (service *PersonalSnapshotService) StoreErke(ctx context.Context, userID uint, upload ErkeSnapshotUpload) (academic.ContextResult, error) {
	if service == nil || service.db == nil || userID == 0 {
		return academic.ContextResult{}, ErrInvalidPersonalSnapshot
	}
	payload, partial, err := normalizeErkeSnapshotUpload(upload)
	if err != nil {
		return academic.ContextResult{}, err
	}
	expiresAt := upload.FetchedAt.Add(erkeSnapshotTTL)
	now := service.now()
	if upload.FetchedAt.After(now.Add(5*time.Minute)) || !expiresAt.After(upload.FetchedAt) {
		return academic.ContextResult{}, ErrInvalidPersonalSnapshot
	}
	hash := hashPersonalSnapshot(payload)
	snapshot := models.PersonalUploadedSnapshot{
		UserID: userID, SnapshotType: PersonalSnapshotTypeErke, SchemaVersion: upload.SchemaVersion,
		PayloadJSON: datatypes.JSON(payload), PayloadHash: hash, FetchedAt: upload.FetchedAt,
		ExpiresAt: expiresAt, IsPartial: partial,
	}
	if err := service.db.WithContext(ctx).Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "user_id"}, {Name: "snapshot_type"}},
		DoUpdates: clause.AssignmentColumns([]string{
			"schema_version", "payload_json", "payload_hash", "fetched_at", "expires_at", "is_partial", "updated_at",
		}),
	}).Create(&snapshot).Error; err != nil {
		return academic.ContextResult{}, err
	}
	lookup, err := service.LookupErke(ctx, userID)
	if err != nil || !lookup.Found {
		return academic.ContextResult{}, err
	}
	return lookup.Result, nil
}

// LookupErke 读取当前用户的已上传二课快照，并显式返回过期与部分数据状态。
func (service *PersonalSnapshotService) LookupErke(ctx context.Context, userID uint) (academic.SnapshotLookup, error) {
	if service == nil || service.db == nil || userID == 0 {
		return academic.SnapshotLookup{}, ErrInvalidPersonalSnapshot
	}
	var snapshot models.PersonalUploadedSnapshot
	err := service.db.WithContext(ctx).Where("user_id = ? AND snapshot_type = ?", userID, PersonalSnapshotTypeErke).First(&snapshot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return academic.SnapshotLookup{}, nil
	}
	if err != nil {
		return academic.SnapshotLookup{}, err
	}
	payload := json.RawMessage(snapshot.PayloadJSON)
	if !json.Valid(payload) || hashPersonalSnapshot(payload) != snapshot.PayloadHash || containsSnapshotSecret(payload) {
		return academic.SnapshotLookup{Found: true, Corrupted: true}, ErrInvalidPersonalSnapshot
	}
	isStale := !snapshot.ExpiresAt.After(service.now())
	status := academic.DataStatusAvailable
	if isStale {
		status = academic.DataStatusStale
	} else if snapshot.IsPartial {
		status = academic.DataStatusPartial
	}
	warnings := make([]string, 0, 2)
	if snapshot.IsPartial {
		warnings = append(warnings, "该二课快照仅包含部分数据")
	}
	if isStale {
		warnings = append(warnings, "该二课快照已过期")
	}
	fetchedAt, expiresAt := snapshot.FetchedAt, snapshot.ExpiresAt
	return academic.SnapshotLookup{Found: true, Result: academic.ContextResult{
		Data: payload, Status: status, Source: academic.DataSourceUserUploadedSnapshot,
		FetchedAt: &fetchedAt, ExpiresAt: &expiresAt, IsStale: isStale, IsPartial: snapshot.IsPartial,
		Warnings: warnings,
		Evidence: []academic.Evidence{{
			Source: academic.DataSourceUserUploadedSnapshot, Dataset: academic.DatasetErke,
			FetchedAt: &fetchedAt, ExpiresAt: &expiresAt, IsStale: isStale,
		}},
	}}, nil
}

func (service *PersonalSnapshotService) DeleteErke(ctx context.Context, userID uint) error {
	if service == nil || service.db == nil || userID == 0 {
		return ErrInvalidPersonalSnapshot
	}
	result := service.db.WithContext(ctx).Where("user_id = ? AND snapshot_type = ?", userID, PersonalSnapshotTypeErke).Delete(&models.PersonalUploadedSnapshot{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return ErrPersonalSnapshotNotFound
	}
	return nil
}

func normalizeErkeSnapshotUpload(upload ErkeSnapshotUpload) (json.RawMessage, bool, error) {
	if upload.SchemaVersion != 2 || upload.FetchedAt.IsZero() || !validErkeUpload(upload) {
		return nil, false, ErrInvalidPersonalSnapshot
	}
	payload, err := json.Marshal(struct {
		Graduation       ErkeGraduationSummary `json:"graduation"`
		Yearly           ErkeYearlySummary     `json:"yearly"`
		RecentActivities []ErkeActivitySummary `json:"recent_activities"`
	}{
		Graduation: upload.Graduation, Yearly: upload.Yearly, RecentActivities: upload.RecentActivities,
	})
	if err != nil || len(payload) > maxErkeSnapshotBytes || containsSnapshotSecret(payload) {
		return nil, false, ErrInvalidPersonalSnapshot
	}
	partial := len(upload.RecentActivities) == 0
	return payload, partial, nil
}

func validErkeUpload(upload ErkeSnapshotUpload) bool {
	if len(upload.Graduation.UnmetCategories) > 16 || len(upload.RecentActivities) > 20 || len(upload.Graduation.OfficialConclusion) > 200 || len(upload.Yearly.OfficialConclusion) > 200 {
		return false
	}
	validNumber := func(value *float64) bool {
		return value == nil || (!math.IsNaN(*value) && !math.IsInf(*value, 0) && *value >= 0 && *value <= 100000)
	}
	for _, value := range []*float64{upload.Graduation.EarnedTotal, upload.Graduation.RequiredTotal, upload.Graduation.GraduationGap, upload.Yearly.EarnedTotal, upload.Yearly.RequiredTotal, upload.Yearly.YearlyGap} {
		if !validNumber(value) {
			return false
		}
	}
	for _, category := range upload.Graduation.UnmetCategories {
		if strings.TrimSpace(category.Name) == "" || len(category.Name) > 80 || category.Gap < 0 || math.IsNaN(category.Gap) || math.IsInf(category.Gap, 0) {
			return false
		}
	}
	for _, activity := range upload.RecentActivities {
		if strings.TrimSpace(activity.Category) == "" || len(activity.Category) > 80 || !validNumber(activity.Score) {
			return false
		}
		if activity.Date != "" {
			if _, err := time.Parse("2006-01-02", activity.Date); err != nil {
				return false
			}
		}
	}
	return true
}

func validJSONObject(raw json.RawMessage) bool {
	var value map[string]interface{}
	return len(raw) > 0 && json.Unmarshal(raw, &value) == nil && value != nil
}

func validJSONArray(raw json.RawMessage) bool {
	var value []interface{}
	return len(raw) > 0 && json.Unmarshal(raw, &value) == nil && value != nil
}

func containsSnapshotSecret(raw json.RawMessage) bool {
	var value interface{}
	if json.Unmarshal(raw, &value) != nil {
		return true
	}
	return containsSnapshotSecretValue(value)
}

func containsSnapshotSecretValue(value interface{}) bool {
	switch typed := value.(type) {
	case map[string]interface{}:
		for key, child := range typed {
			switch strings.ToLower(strings.TrimSpace(key)) {
			case "password", "cookie", "token", "session", "authorization", "credential", "html", "raw_html", "device_key":
				return true
			}
			if containsSnapshotSecretValue(child) {
				return true
			}
		}
	case []interface{}:
		for _, child := range typed {
			if containsSnapshotSecretValue(child) {
				return true
			}
		}
	}
	return false
}

func hashPersonalSnapshot(payload []byte) string {
	digest := sha256.Sum256(payload)
	return hex.EncodeToString(digest[:])
}
