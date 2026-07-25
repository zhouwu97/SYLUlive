package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
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
	SchemaVersion    int             `json:"schema_version"`
	FetchedAt        time.Time       `json:"fetched_at"`
	Graduation       json.RawMessage `json:"graduation"`
	Yearly           json.RawMessage `json:"yearly"`
	RecentActivities json.RawMessage `json:"recent_activities"`
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
	if upload.SchemaVersion != 2 || upload.FetchedAt.IsZero() || !validJSONObject(upload.Graduation) || !validJSONObject(upload.Yearly) || !validJSONArray(upload.RecentActivities) {
		return nil, false, ErrInvalidPersonalSnapshot
	}
	payload, err := json.Marshal(struct {
		Graduation       json.RawMessage `json:"graduation"`
		Yearly           json.RawMessage `json:"yearly"`
		RecentActivities json.RawMessage `json:"recent_activities"`
	}{
		Graduation: upload.Graduation, Yearly: upload.Yearly, RecentActivities: upload.RecentActivities,
	})
	if err != nil || len(payload) > maxErkeSnapshotBytes || containsSnapshotSecret(payload) {
		return nil, false, ErrInvalidPersonalSnapshot
	}
	var decoded map[string]interface{}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, false, ErrInvalidPersonalSnapshot
	}
	activities, _ := decoded["recent_activities"].([]interface{})
	partial := len(activities) == 0 || len(decoded["graduation"].(map[string]interface{})) == 0 || len(decoded["yearly"].(map[string]interface{})) == 0
	return payload, partial, nil
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
