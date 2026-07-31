package services

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

const maxAcademicSnapshotBytes = 512 * 1024

var (
	// ErrSnapshotCredentialGenerationChanged 表示远程抓取期间用户已重新绑定或撤销教务授权。
	ErrSnapshotCredentialGenerationChanged = errors.New("教务授权代次已变化")
	// ErrAcademicSnapshotCorrupted 表示持久化载荷与写入时哈希不一致，不能作为回答依据。
	ErrAcademicSnapshotCorrupted = errors.New("学业快照校验失败")
)

// AcademicSnapshotInput 是写入服务端学业快照所需的最小信息。
type AcademicSnapshotInput struct {
	UserID               uint
	Dataset              academic.DatasetType
	ScopeKey             string
	SchemaVersion        int
	Source               academic.DataSource
	Payload              json.RawMessage
	FetchedAt            time.Time
	ExpiresAt            time.Time
	IsPartial            bool
	CredentialGeneration uint
}

// AcademicSnapshotLookup 保留服务层兼容名称；跨层契约由 academic.SnapshotLookup 定义。
type AcademicSnapshotLookup = academic.SnapshotLookup

// AcademicSnapshotService 管理学业快照的完整性、过期状态和授权代次隔离。
type AcademicSnapshotService struct {
	db  *gorm.DB
	now func() time.Time
}

func NewAcademicSnapshotService(db *gorm.DB, now func() time.Time) *AcademicSnapshotService {
	if now == nil {
		now = time.Now
	}
	return &AcademicSnapshotService{db: db, now: now}
}

// CurrentCredentialGeneration 返回当前允许拉取和读取快照的教务授权代次。
func (service *AcademicSnapshotService) CurrentCredentialGeneration(ctx context.Context, userID uint) (uint, error) {
	if service == nil || service.db == nil || userID == 0 {
		return 0, errors.New("学业快照服务未配置")
	}
	var user models.User
	if err := service.db.WithContext(ctx).
		Select("id", "edu_authorized", "edu_authorization_generation", "edu_session_state", "edu_cleanup_pending").
		First(&user, userID).Error; err != nil {
		return 0, err
	}
	if !user.EduAuthorized || user.EduCleanupPending || user.EduSessionState == "revoked" {
		return 0, ErrSnapshotCredentialGenerationChanged
	}
	return user.EduAuthorizationGeneration, nil
}

// Lookup 读取与当前授权代次匹配的快照，并把过期状态显式带到统一结果信封。
func (service *AcademicSnapshotService) Lookup(ctx context.Context, userID uint, dataset academic.DatasetType, scopeKey string, generation uint) (AcademicSnapshotLookup, error) {
	if service == nil || service.db == nil {
		return AcademicSnapshotLookup{}, errors.New("学业快照服务未配置")
	}
	if !dataset.Valid() || strings.TrimSpace(scopeKey) == "" || userID == 0 {
		return AcademicSnapshotLookup{}, errors.New("学业快照查询参数无效")
	}
	var snapshot models.AcademicSnapshot
	err := service.db.WithContext(ctx).
		Where("user_id = ? AND dataset_type = ? AND scope_key = ? AND credential_generation = ?", userID, dataset, scopeKey, generation).
		First(&snapshot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return AcademicSnapshotLookup{}, nil
	}
	if err != nil {
		return AcademicSnapshotLookup{}, err
	}
	payload := json.RawMessage(snapshot.PayloadJSON)
	if !json.Valid(payload) || snapshot.PayloadHash != academicPayloadHash(payload) {
		return AcademicSnapshotLookup{Found: true, Corrupted: true}, ErrAcademicSnapshotCorrupted
	}
	isStale := !snapshot.ExpiresAt.After(service.now())
	status := academic.DataStatusAvailable
	if isStale {
		status = academic.DataStatusStale
	} else if snapshot.IsPartial {
		status = academic.DataStatusPartial
	}
	warnings := make([]string, 0, 1)
	if snapshot.IsPartial {
		warnings = append(warnings, "该学业快照仅包含部分数据")
	}
	if isStale {
		warnings = append(warnings, "该学业快照已过期")
	}
	fetchedAt := snapshot.FetchedAt
	expiresAt := snapshot.ExpiresAt
	return AcademicSnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data:      payload,
			Status:    status,
			Source:    academic.DataSourceServerSnapshot,
			FetchedAt: &fetchedAt,
			ExpiresAt: &expiresAt,
			IsStale:   isStale,
			IsPartial: snapshot.IsPartial,
			Warnings:  warnings,
			Evidence: []academic.Evidence{{
				Source:    academic.DataSourceServerSnapshot,
				Dataset:   dataset,
				ScopeKey:  snapshot.ScopeKey,
				FetchedAt: &fetchedAt,
				ExpiresAt: &expiresAt,
				IsStale:   isStale,
			}},
		},
	}, nil
}

// LookupLatest 读取当前授权代次下最近一次可用快照。
// MCP 只能使用快照服务提供的完整性校验结果，不能自行读取原始载荷。
func (service *AcademicSnapshotService) LookupLatest(ctx context.Context, userID uint, dataset academic.DatasetType, generation uint) (AcademicSnapshotLookup, error) {
	if service == nil || service.db == nil {
		return AcademicSnapshotLookup{}, errors.New("学业快照服务未配置")
	}
	if !dataset.Valid() || userID == 0 {
		return AcademicSnapshotLookup{}, errors.New("学业快照查询参数无效")
	}
	var snapshot models.AcademicSnapshot
	err := service.db.WithContext(ctx).
		Where("user_id = ? AND dataset_type = ? AND credential_generation = ?", userID, dataset, generation).
		Order("fetched_at DESC, id DESC").
		First(&snapshot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return AcademicSnapshotLookup{}, nil
	}
	if err != nil {
		return AcademicSnapshotLookup{}, err
	}
	payload := json.RawMessage(snapshot.PayloadJSON)
	if !json.Valid(payload) || snapshot.PayloadHash != academicPayloadHash(payload) {
		return AcademicSnapshotLookup{Found: true, Corrupted: true}, ErrAcademicSnapshotCorrupted
	}
	isStale := !snapshot.ExpiresAt.After(service.now())
	status := academic.DataStatusAvailable
	if isStale {
		status = academic.DataStatusStale
	} else if snapshot.IsPartial {
		status = academic.DataStatusPartial
	}
	warnings := make([]string, 0, 1)
	if snapshot.IsPartial {
		warnings = append(warnings, "该学业快照仅包含部分数据")
	}
	if isStale {
		warnings = append(warnings, "该学业快照已过期")
	}
	fetchedAt := snapshot.FetchedAt
	expiresAt := snapshot.ExpiresAt
	return AcademicSnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data:      payload,
			Status:    status,
			Source:    academic.DataSourceServerSnapshot,
			FetchedAt: &fetchedAt,
			ExpiresAt: &expiresAt,
			IsStale:   isStale,
			IsPartial: snapshot.IsPartial,
			Warnings:  warnings,
			Evidence: []academic.Evidence{{
				Source:    academic.DataSourceServerSnapshot,
				Dataset:   dataset,
				ScopeKey:  snapshot.ScopeKey,
				FetchedAt: &fetchedAt,
				ExpiresAt: &expiresAt,
				IsStale:   isStale,
			}},
		},
	}, nil
}

// StoreRemote 在同一事务内复核当前教务授权代次，再写入或更新快照。
// 这样旧抓取任务无法覆盖用户重新绑定后的新快照。
func (service *AcademicSnapshotService) StoreRemote(ctx context.Context, input AcademicSnapshotInput) error {
	if service == nil || service.db == nil {
		return errors.New("学业快照服务未配置")
	}
	if err := validateAcademicSnapshotInput(input); err != nil {
		return err
	}
	payload, err := canonicalAcademicPayload(input.Payload)
	if err != nil {
		return errors.New("学业快照载荷无效")
	}
	payloadHash := academicPayloadHash(payload)
	return service.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Select("id", "edu_authorized", "edu_authorization_generation", "edu_session_state", "edu_cleanup_pending").
			First(&user, input.UserID).Error; err != nil {
			return err
		}
		if !user.EduAuthorized || user.EduCleanupPending || user.EduSessionState == "revoked" || user.EduAuthorizationGeneration != input.CredentialGeneration {
			return ErrSnapshotCredentialGenerationChanged
		}
		snapshot := models.AcademicSnapshot{
			UserID:               input.UserID,
			DatasetType:          string(input.Dataset),
			ScopeKey:             input.ScopeKey,
			SchemaVersion:        input.SchemaVersion,
			Source:               string(input.Source),
			PayloadJSON:          datatypes.JSON(payload),
			PayloadHash:          payloadHash,
			FetchedAt:            input.FetchedAt,
			ExpiresAt:            input.ExpiresAt,
			IsPartial:            input.IsPartial,
			CredentialGeneration: input.CredentialGeneration,
		}
		return tx.Clauses(clause.OnConflict{
			Columns: []clause.Column{{Name: "user_id"}, {Name: "dataset_type"}, {Name: "scope_key"}},
			DoUpdates: clause.AssignmentColumns([]string{
				"schema_version", "source", "payload_json", "payload_hash", "fetched_at", "expires_at", "is_partial", "credential_generation", "updated_at",
			}),
		}).Create(&snapshot).Error
	})
}

func validateAcademicSnapshotInput(input AcademicSnapshotInput) error {
	if input.UserID == 0 || !input.Dataset.Valid() || strings.TrimSpace(input.ScopeKey) == "" {
		return errors.New("学业快照写入参数无效")
	}
	if input.Source != academic.DataSourceRemoteEduFetch && input.Source != academic.DataSourceUserUploadedSnapshot {
		return fmt.Errorf("学业快照来源不允许写入: %s", input.Source)
	}
	if input.SchemaVersion <= 0 || input.CredentialGeneration == 0 || len(input.Payload) == 0 || len(input.Payload) > maxAcademicSnapshotBytes || !json.Valid(input.Payload) {
		return errors.New("学业快照载荷无效")
	}
	if input.FetchedAt.IsZero() || input.ExpiresAt.IsZero() || !input.ExpiresAt.After(input.FetchedAt) {
		return errors.New("学业快照时间范围无效")
	}
	return nil
}

// canonicalAcademicPayload 将 JSON 解析为语义值后重新编码。
// PostgreSQL jsonb 会丢弃空白并排序对象键，哈希必须基于同一语义表示，
// 否则写入前计算的原始字节哈希会在读取时把正常快照误判为损坏。
func canonicalAcademicPayload(payload []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var value interface{}
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	var extra interface{}
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, errors.New("学业快照包含多个 JSON 值")
		}
		return nil, err
	}
	return json.Marshal(value)
}

func academicPayloadHash(payload []byte) string {
	canonical, err := canonicalAcademicPayload(payload)
	if err != nil {
		canonical = payload
	}
	digest := sha256.Sum256(canonical)
	return hex.EncodeToString(digest[:])
}
