package services

import (
	"context"
	"encoding/json"
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

// ReadPersonal 只读令牌本人已有的获准快照；不接受目标用户、密码或学校Cookie。
// 与撤权共用用户→绑定锁顺序，读取和无正文审计必须同时成功。
func (s *IntegrationAuthService) ReadPersonal(ctx context.Context, expected models.IntegrationBinding, dataset string, offset, limit int) (map[string]interface{}, error) {
	var result map[string]interface{}
	scope := IntegrationGradesScope
	if dataset == "erke" {
		scope = IntegrationErkeScope
	} else if dataset != "grades" {
		return nil, integrationError("invalid_request", 422)
	}
	if offset < 0 || limit < 1 || limit > 50 || (dataset == "erke" && offset != 0) {
		return nil, integrationError("invalid_request", 422)
	}
	err := s.ownerTx(ctx, expected.OwnerID, func(tx *gorm.DB, user models.User) error {
		var binding models.IntegrationBinding
		if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Where("id = ? AND owner_id = ?", expected.ID, user.ID).Take(&binding).Error; err != nil {
			return integrationError("invalid_token", 401)
		}
		if binding.Epoch != expected.Epoch {
			return integrationError("authorization_changed", 403)
		}
		if err := s.bindingValid(tx, binding, user); err != nil {
			return err
		}
		if !IntegrationHasScope(binding, scope) {
			return integrationError("insufficient_scope", 403)
		}
		privacyScope := models.AIUserPermissionAcademicCloudStorage
		if dataset == "erke" {
			privacyScope = models.AIUserPermissionErkeSnapshotUpload
		}
		policy, err := NewAIUserPermissionService(tx).Policy(ctx, user.ID, privacyScope)
		if err != nil {
			return err
		}
		if policy == models.AIUserPermissionNever {
			return integrationError("personal_data_disabled", 403)
		}
		var lookup academic.SnapshotLookup
		if dataset == "grades" {
			uploaded, err := s.uploadedGrades(ctx, tx, binding)
			if err != nil {
				return integrationError("personal_data_unavailable", 503)
			}
			snapshots := NewAcademicSnapshotService(tx, s.Now)
			generation, err := snapshots.CurrentCredentialGeneration(ctx, user.ID)
			if err != nil && !errors.Is(err, ErrSnapshotCredentialGenerationChanged) {
				return err
			}
			if err == nil {
				lookup, err = snapshots.LookupLatest(ctx, user.ID, academic.DatasetGrades, generation)
				if err != nil {
					return integrationError("personal_data_unavailable", 503)
				}
			}
			if uploaded.Found && (!lookup.Found || uploaded.Result.FetchedAt.After(*lookup.Result.FetchedAt)) {
				lookup = uploaded
			}
		} else {
			lookup, err = NewPersonalSnapshotService(tx, s.Now).LookupErke(ctx, user.ID)
			if err != nil {
				return integrationError("personal_data_unavailable", 503)
			}
		}
		if !lookup.Found {
			return integrationError("academic_sync_required", 409)
		}
		if lookup.Corrupted {
			return integrationError("personal_data_unavailable", 503)
		}
		result = map[string]interface{}{"dataset": dataset, "status": lookup.Result.Status, "source": lookup.Result.Source, "fetched_at": lookup.Result.FetchedAt, "expires_at": lookup.Result.ExpiresAt, "is_stale": lookup.Result.IsStale, "is_partial": lookup.Result.IsPartial, "warnings": lookup.Result.Warnings, "live_query": false}
		if dataset == "grades" {
			var payload struct {
				Grades       []map[string]interface{} `json:"grades"`
				CoveredTerms []map[string]interface{} `json:"covered_terms"`
			}
			if err := json.Unmarshal(lookup.Result.Data, &payload); err != nil {
				return integrationError("personal_data_unavailable", 503)
			}
			total := len(payload.Grades)
			if offset > total {
				offset = total
			}
			end := total
			if limit < total-offset {
				end = offset + limit
			}
			rows := make([]map[string]interface{}, 0, end-offset)
			for _, row := range payload.Grades[offset:end] {
				clean := map[string]interface{}{}
				for _, key := range []string{"course_name", "fraction", "grade", "score", "credits", "gpa", "course_type", "course_nature", "exam_type", "year", "semester"} {
					if value, ok := row[key]; ok {
						switch value.(type) {
						case string, float64, bool:
							clean[key] = value
						}
					}
				}
				rows = append(rows, clean)
			}
			result["grades"] = rows
			terms := make([]map[string]interface{}, 0, len(payload.CoveredTerms))
			for _, term := range payload.CoveredTerms {
				terms = append(terms, map[string]interface{}{"year": term["year"], "semester": term["semester"], "course_count": term["course_count"]})
			}
			result["covered_terms"] = terms
			result["total"] = total
			result["next_offset"] = nil
			if end < total {
				result["next_offset"] = end
			}
			result["note"] = "仅含已同步学期的成绩，不代表全部学期或学校实时成绩；缺项请先在App或官网同步。"
		} else {
			var payload struct {
				Graduation       ErkeGraduationSummary `json:"graduation"`
				Yearly           ErkeYearlySummary     `json:"yearly"`
				RecentActivities []ErkeActivitySummary `json:"recent_activities"`
			}
			if err := json.Unmarshal(lookup.Result.Data, &payload); err != nil {
				return integrationError("personal_data_unavailable", 503)
			}
			result["summary"] = payload
			result["note"] = "本人主动同步的二课摘要，不是学校实时查询；未上传、删除或过期需在App或官网重新同步。"
		}
		return tx.Create(&models.IntegrationAudit{OwnerID: user.ID, ActorID: user.ID, BindingID: binding.ID, Event: dataset + "_read", CreatedAt: s.Now()}).Error
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}
