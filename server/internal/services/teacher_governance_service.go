package services

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// 教师与课程数据治理的稳定业务错误码（符合完整实施计划 §22 规范）。
const (
	CodeTeacherNotFound                          = "TEACHER_NOT_FOUND"
	CodeTeacherAlreadyMerged                     = "TEACHER_ALREADY_MERGED"
	CodeCrossSubjectMergeRequiresSubjectDecision = "CROSS_SUBJECT_MERGE_REQUIRES_SUBJECT_DECISION"
	CodeSubjectNotEmpty                          = "SUBJECT_NOT_EMPTY"
	CodeAliasTargetConflict                      = "ALIAS_TARGET_CONFLICT"
	CodeCanonicalNameConflict                    = "CANONICAL_NAME_CONFLICT"
	CodeGovernanceSnapshotRequired               = "GOVERNANCE_SNAPSHOT_REQUIRED"
	CodeGovernanceSnapshotStale                  = "GOVERNANCE_SNAPSHOT_STALE"
	CodeMergeRatingConflict                      = "MERGE_RATING_CONFLICT"
	CodeInvalidGovernanceDecision                = "INVALID_GOVERNANCE_DECISION"
	CodeUseGovernanceMerge                       = "USE_GOVERNANCE_MERGE"
	CodeTeacherGovernanceForbidden               = "TEACHER_GOVERNANCE_FORBIDDEN"
	CodeTeacherGovernanceInvalidInput            = "INVALID_TEACHER_GOVERNANCE_INPUT"
	CodeTeacherGovernanceStateConflict           = "TEACHER_GOVERNANCE_STATE_CONFLICT"
	CodeTeacherGovernanceInternalError           = "TEACHER_GOVERNANCE_INTERNAL_ERROR"
)

// TeacherGovernanceError 承载治理业务的稳定错误码。
type TeacherGovernanceError struct {
	Code    string                 `json:"code"`
	Message string                 `json:"error"`
	Err     error                  `json:"-"`
	Details map[string]interface{} `json:"details,omitempty"`
}

func (e *TeacherGovernanceError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("%s: %v", e.Message, e.Err)
	}
	return e.Message
}

func (e *TeacherGovernanceError) Unwrap() error { return e.Err }

// TeacherGovernanceHTTPStatus 把业务码映射为 HTTP 状态码。
func TeacherGovernanceHTTPStatus(code string) int {
	switch code {
	case CodeTeacherGovernanceInvalidInput, CodeInvalidGovernanceDecision, CodeGovernanceSnapshotRequired:
		return 400
	case CodeTeacherGovernanceForbidden:
		return 403
	case CodeTeacherNotFound:
		return 404
	case CodeTeacherAlreadyMerged, CodeCrossSubjectMergeRequiresSubjectDecision, CodeSubjectNotEmpty,
		CodeAliasTargetConflict, CodeCanonicalNameConflict, CodeGovernanceSnapshotStale,
		CodeMergeRatingConflict, CodeUseGovernanceMerge, CodeTeacherGovernanceStateConflict:
		return 409
	default:
		return 500
	}
}

func governanceErr(code, message string, err error) *TeacherGovernanceError {
	return &TeacherGovernanceError{Code: code, Message: message, Err: err}
}

func governanceErrWithDetails(code, message string, details map[string]interface{}) *TeacherGovernanceError {
	return &TeacherGovernanceError{Code: code, Message: message, Details: details}
}

// TeacherGovernanceService 教师与课程数据治理服务。
type TeacherGovernanceService struct {
	db *gorm.DB
}

func NewTeacherGovernanceService(db *gorm.DB) *TeacherGovernanceService {
	return &TeacherGovernanceService{db: db}
}

// ---------------- 视图与输入 ----------------

// GovernanceTeacherView 治理视角的教师行。
type GovernanceTeacherView struct {
	ID                     uint      `json:"id"`
	Name                   string    `json:"name"`
	Course                 string    `json:"course"`
	SubjectID              *uint     `json:"course_subject_id,omitempty"`
	SubjectName            string    `json:"course_subject_name,omitempty"`
	SubjectNameCompat      string    `json:"subject_name,omitempty"`
	SubjectVerified        bool      `json:"course_subject_verified"`
	SubjectVerifiedCompat  bool      `json:"subject_verified"`
	AliasCount             int       `json:"alias_count"`
	Verified               bool      `json:"verified"`
	CanonicalSource        string    `json:"canonical_source"`
	RatingCount            int       `json:"rating_count"`
	PendingSubmissionCount int       `json:"pending_submission_count"`
	PendingCount           int       `json:"pending_count"`
	CreatedAt              time.Time `json:"created_at"`
	MergedIntoID           *uint     `json:"merged_into_id,omitempty"`
	IsMerged               bool      `json:"is_merged"`
}

// 疑似重复分组的种类。
const (
	DuplicateGroupNameVariant = "name_variant"           // 张三 / 张三老师（高置信）
	DuplicateGroupSimilarName = "similar_name"           // 张三 / 张山（同姓氏一字之差，仅疑似提示）
	DuplicateGroupCrossCourse = "cross_course_same_name" // 跨课程同名（仅提示，不可直接合并）
)

// TeacherAliasSuggestion 建议登记的教师别名。
type TeacherAliasSuggestion struct {
	Alias            string `json:"alias"`
	TargetID         uint   `json:"target_teacher_id"`
	TargetIDCompat   uint   `json:"target_id,omitempty"`
	TargetName       string `json:"target_teacher_name"`
	TargetNameCompat string `json:"target_name,omitempty"`
}

// CourseAliasSuggestion 建议登记的课程别名。
type CourseAliasSuggestion struct {
	Alias            string `json:"alias"`
	TargetID         uint   `json:"target_subject_id"`
	TargetIDCompat   uint   `json:"target_id,omitempty"`
	TargetName       string `json:"target_subject_name"`
	TargetNameCompat string `json:"target_name,omitempty"`
}

// DuplicateTeacherGroup 一组疑似重复教师。
type DuplicateTeacherGroup struct {
	Key             string                   `json:"key"`
	ID              string                   `json:"id"`
	Kind            string                   `json:"kind"`
	Confidence      string                   `json:"confidence"` // high | suspected | hint
	Mergeable       bool                     `json:"mergeable"`
	MergeAllowed    bool                     `json:"merge_allowed"`
	Note            string                   `json:"note,omitempty"`
	Reasons         []string                 `json:"reasons,omitempty"`
	SuggestedKeeper *uint                    `json:"suggested_keeper_id,omitempty"`
	TeacherAliases  []TeacherAliasSuggestion `json:"teacher_aliases,omitempty"`
	CourseAliases   []CourseAliasSuggestion  `json:"course_aliases,omitempty"`
	Teachers        []GovernanceTeacherView  `json:"teachers"`
}

type governanceTeacherRow struct {
	ID              uint      `gorm:"column:id"`
	Name            string    `gorm:"column:name"`
	Course          string    `gorm:"column:course"`
	Verified        bool      `gorm:"column:verified"`
	SubjectID       *uint     `gorm:"column:course_subject_id"`
	SubjectName     string    `gorm:"column:course_subject_name"`
	SubjectVerified bool      `gorm:"column:course_subject_verified"`
	CanonicalSource string    `gorm:"column:canonical_source"`
	RatingCount     int       `gorm:"column:rating_count"`
	CreatedAt       time.Time `gorm:"column:created_at"`
	MergedIntoID    *uint     `gorm:"column:merged_into_id"`
}

type teacherCountMaps struct {
	ratings  map[uint]int
	pendings map[uint]int
	aliases  map[uint]int
}

func loadTeacherCountMapsForIDs(db *gorm.DB, teacherIDs []uint) (*teacherCountMaps, error) {
	maps := &teacherCountMaps{ratings: map[uint]int{}, pendings: map[uint]int{}, aliases: map[uint]int{}}
	if teacherIDs != nil && len(teacherIDs) == 0 {
		return maps, nil
	}

	var ratingRows []struct {
		TeacherID uint
		Total     int64
	}
	rq := db.Model(&models.TeacherRating{}).
		Select("teacher_id, COUNT(*) AS total").
		Where("deleted_at IS NULL AND status = ?", "normal")
	if len(teacherIDs) > 0 {
		rq = rq.Where("teacher_id IN (?)", teacherIDs)
	}
	if err := rq.Group("teacher_id").Scan(&ratingRows).Error; err == nil {
		for _, row := range ratingRows {
			maps.ratings[row.TeacherID] = int(row.Total)
		}
	} else {
		return nil, err
	}

	var pendingRows []struct {
		TeacherID uint
		Total     int64
	}
	pq := db.Model(&models.CourseEvaluationSubmission{}).
		Select("teacher_id, COUNT(*) AS total").
		Where("status = ? AND teacher_id IS NOT NULL", models.CourseEvaluationStatusPending)
	if len(teacherIDs) > 0 {
		pq = pq.Where("teacher_id IN (?)", teacherIDs)
	}
	if err := pq.Group("teacher_id").Scan(&pendingRows).Error; err == nil {
		for _, row := range pendingRows {
			maps.pendings[row.TeacherID] = int(row.Total)
		}
	} else {
		return nil, err
	}

	var aliasRows []struct {
		TeacherID uint
		Total     int64
	}
	aq := db.Model(&models.TeacherAlias{}).
		Select("teacher_id, COUNT(*) AS total")
	if len(teacherIDs) > 0 {
		aq = aq.Where("teacher_id IN (?)", teacherIDs)
	}
	if err := aq.Group("teacher_id").Scan(&aliasRows).Error; err == nil {
		for _, row := range aliasRows {
			maps.aliases[row.TeacherID] = int(row.Total)
		}
	} else {
		return nil, err
	}
	return maps, nil
}

func loadTeacherCountMaps(db *gorm.DB) (*teacherCountMaps, error) {
	return loadTeacherCountMapsForIDs(db, nil)
}

func (m *teacherCountMaps) view(row governanceTeacherRow) GovernanceTeacherView {
	return GovernanceTeacherView{
		ID:                     row.ID,
		Name:                   row.Name,
		Course:                 row.Course,
		SubjectID:              row.SubjectID,
		SubjectName:            row.SubjectName,
		SubjectNameCompat:      row.SubjectName,
		SubjectVerified:        row.SubjectVerified,
		SubjectVerifiedCompat:  row.SubjectVerified,
		AliasCount:             m.aliases[row.ID],
		Verified:               row.Verified,
		CanonicalSource:        row.CanonicalSource,
		RatingCount:            m.ratings[row.ID],
		PendingSubmissionCount: m.pendings[row.ID],
		PendingCount:           m.pendings[row.ID],
		CreatedAt:              row.CreatedAt,
		MergedIntoID:           row.MergedIntoID,
		IsMerged:               row.MergedIntoID != nil,
	}
}

func loadGovernanceTeacherRows(db *gorm.DB, q string, cursor uint, limit int, includeMerged bool, subjectID *uint) ([]governanceTeacherRow, bool, uint, *teacherCountMaps, error) {
	query := db.Table("teachers t").
		Select("t.id AS id, t.name AS name, t.course AS course, t.verified AS verified, " +
			"t.course_subject_id AS course_subject_id, t.canonical_source AS canonical_source, " +
			"t.created_at AS created_at, t.merged_into_id AS merged_into_id, " +
			"COALESCE(cs.name, '') AS course_subject_name, COALESCE(cs.verified, false) AS course_subject_verified, " +
			"0 AS rating_count").
		Joins("LEFT JOIN course_subjects cs ON cs.id = t.course_subject_id")
	if !includeMerged {
		query = query.Where("t.merged_into_id IS NULL")
	}
	if subjectID != nil && *subjectID != 0 {
		query = query.Where("t.course_subject_id = ?", *subjectID)
	}
	if cursor > 0 {
		query = query.Where("t.id > ?", cursor)
	}
	if strings.TrimSpace(q) != "" {
		like := "%" + escapeLike(strings.TrimSpace(q)) + "%"
		query = query.Where("t.name LIKE ? OR t.course LIKE ?", like, like)
	}
	if limit > 0 {
		query = query.Limit(limit + 1)
	}
	var rows []governanceTeacherRow
	if err := query.Order("t.id ASC").Scan(&rows).Error; err != nil {
		return nil, false, 0, nil, err
	}

	hasMore := false
	var nextCursor uint
	if limit > 0 && len(rows) > limit {
		hasMore = true
		rows = rows[:limit]
		nextCursor = rows[limit-1].ID
	} else if len(rows) > 0 {
		nextCursor = rows[len(rows)-1].ID
	}

	teacherIDs := make([]uint, 0, len(rows))
	for _, row := range rows {
		teacherIDs = append(teacherIDs, row.ID)
	}

	maps, err := loadTeacherCountMapsForIDs(db, teacherIDs)
	if err != nil {
		return nil, false, 0, nil, err
	}
	for i := range rows {
		rows[i].RatingCount = maps.ratings[rows[i].ID]
	}
	return rows, hasMore, nextCursor, maps, nil
}

// teacherVariantKey 去掉常见称谓后缀后的变体键。
func teacherVariantKey(name string) string {
	normalized := models.NormalizeTeacherName(name)
	for _, suffix := range []string{"副教授", "教授", "讲师", "助教", "老师", "教师", "博士"} {
		if strings.HasSuffix(normalized, suffix) {
			trimmed := strings.TrimSuffix(normalized, suffix)
			if utf8.RuneCountInString(trimmed) >= 2 {
				return trimmed
			}
		}
	}
	return normalized
}

func runeLevenshtein(a, b []rune) int {
	la, lb := len(a), len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}
	dp := make([][]int, la+1)
	for i := range dp {
		dp[i] = make([]int, lb+1)
		dp[i][0] = i
	}
	for j := 0; j <= lb; j++ {
		dp[0][j] = j
	}
	for i := 1; i <= la; i++ {
		for j := 1; j <= lb; j++ {
			cost := 0
			if a[i-1] != b[j-1] {
				cost = 1
			}
			c1 := dp[i-1][j] + 1
			c2 := dp[i][j-1] + 1
			c3 := dp[i-1][j-1] + cost
			m := c1
			if c2 < m {
				m = c2
			}
			if c3 < m {
				m = c3
			}
			dp[i][j] = m
		}
	}
	return dp[la][lb]
}

// similarTeacherNames 判断两个规范化教师名是否同姓氏且 Levenshtein 距离 <= 1。
func similarTeacherNames(a, b string) bool {
	ra := []rune(models.NormalizeTeacherName(a))
	rb := []rune(models.NormalizeTeacherName(b))
	if len(ra) < 2 || len(rb) < 2 {
		return false
	}
	if ra[0] != rb[0] {
		return false
	}
	return runeLevenshtein(ra, rb) <= 1
}

// ListDuplicateGroups 构建疑似重复教师分组。
func (s *TeacherGovernanceService) ListDuplicateGroups() ([]DuplicateTeacherGroup, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	rows, _, _, maps, err := loadGovernanceTeacherRows(s.db, "", 0, 0, false, nil)
	if err != nil {
		return nil, governanceErr(CodeTeacherNotFound, "读取教师列表失败", err)
	}

	// 1. 同学科按称谓变体分组（高置信）
	type subjectVariantKey struct {
		subjectID  uint
		variantKey string
	}
	byVariant := map[subjectVariantKey][]governanceTeacherRow{}
	for _, row := range rows {
		if row.SubjectID == nil || *row.SubjectID == 0 {
			continue
		}
		key := subjectVariantKey{
			subjectID:  *row.SubjectID,
			variantKey: teacherVariantKey(row.Name),
		}
		byVariant[key] = append(byVariant[key], row)
	}

	usedInVariant := map[uint]bool{}
	groups := []DuplicateTeacherGroup{}

	for key, groupRows := range byVariant {
		if len(groupRows) < 2 {
			continue
		}
		distinctNames := map[string]bool{}
		for _, r := range groupRows {
			distinctNames[models.NormalizeTeacherName(r.Name)] = true
		}
		if len(distinctNames) < 2 {
			continue
		}
		for _, r := range groupRows {
			usedInVariant[r.ID] = true
		}
		keeper := pickSuggestedKeeper(groupRows)
		teacherViews := make([]GovernanceTeacherView, 0, len(groupRows))
		aliasSuggestions := []TeacherAliasSuggestion{}
		for _, r := range groupRows {
			teacherViews = append(teacherViews, maps.view(r))
			if r.ID != keeper.ID && models.NormalizeTeacherName(r.Name) != models.NormalizeTeacherName(keeper.Name) {
				aliasSuggestions = append(aliasSuggestions, TeacherAliasSuggestion{
					Alias:            r.Name,
					TargetID:         keeper.ID,
					TargetIDCompat:   keeper.ID,
					TargetName:       keeper.Name,
					TargetNameCompat: keeper.Name,
				})
			}
		}
		note := "称谓变体，高置信重复"
		keyStr := fmt.Sprintf("variant-%d-%s", key.subjectID, key.variantKey)
		groups = append(groups, DuplicateTeacherGroup{
			Key:             keyStr,
			ID:              keyStr,
			Kind:            DuplicateGroupNameVariant,
			Confidence:      "high",
			Mergeable:       true,
			MergeAllowed:    true,
			Note:            note,
			Reasons:         []string{note},
			SuggestedKeeper: &keeper.ID,
			TeacherAliases:  aliasSuggestions,
			Teachers:        teacherViews,
		})
	}

	// 2. 同学科同姓氏近似名（疑似提示，Levenshtein <= 1）
	bySubject := map[uint][]governanceTeacherRow{}
	for _, row := range rows {
		if row.SubjectID != nil && *row.SubjectID != 0 && !usedInVariant[row.ID] {
			bySubject[*row.SubjectID] = append(bySubject[*row.SubjectID], row)
		}
	}
	for subjID, subjRows := range bySubject {
		if len(subjRows) < 2 {
			continue
		}
		matchedInSubject := map[uint]bool{}
		for i := 0; i < len(subjRows); i++ {
			if matchedInSubject[subjRows[i].ID] {
				continue
			}
			cluster := []governanceTeacherRow{subjRows[i]}
			for j := i + 1; j < len(subjRows); j++ {
				if matchedInSubject[subjRows[j].ID] {
					continue
				}
				if similarTeacherNames(subjRows[i].Name, subjRows[j].Name) {
					cluster = append(cluster, subjRows[j])
					matchedInSubject[subjRows[j].ID] = true
				}
			}
			if len(cluster) >= 2 {
				matchedInSubject[subjRows[i].ID] = true
				keeper := pickSuggestedKeeper(cluster)
				tViews := make([]GovernanceTeacherView, 0, len(cluster))
				for _, r := range cluster {
					tViews = append(tViews, maps.view(r))
				}
				note := "名称相近，请人工确认是否为同一教师"
				keyStr := fmt.Sprintf("similar-%d-%d", subjID, cluster[0].ID)
				groups = append(groups, DuplicateTeacherGroup{
					Key:             keyStr,
					ID:              keyStr,
					Kind:            DuplicateGroupSimilarName,
					Confidence:      "suspected",
					Mergeable:       true,
					MergeAllowed:    true,
					Note:            note,
					Reasons:         []string{note},
					SuggestedKeeper: &keeper.ID,
					Teachers:        tViews,
				})
			}
		}
	}

	// 3. 跨课程同名（仅提示，不可直接合并）
	byNormalizedName := map[string][]governanceTeacherRow{}
	for _, row := range rows {
		normalized := models.NormalizeTeacherName(row.Name)
		if normalized == "" {
			continue
		}
		byNormalizedName[normalized] = append(byNormalizedName[normalized], row)
	}
	for normName, normRows := range byNormalizedName {
		if len(normRows) < 2 {
			continue
		}
		distinctSubjects := map[uint]bool{}
		for _, r := range normRows {
			if r.SubjectID != nil && *r.SubjectID != 0 {
				distinctSubjects[*r.SubjectID] = true
			}
		}
		if len(distinctSubjects) < 2 {
			continue
		}
		tViews := make([]GovernanceTeacherView, 0, len(normRows))
		for _, r := range normRows {
			tViews = append(tViews, maps.view(r))
		}
		note := "跨课程同名教师。当前教师属于“课程下教师”实体，默认视为不同教师，不支持直接合并。"
		keyStr := fmt.Sprintf("cross-%s", normName)
		groups = append(groups, DuplicateTeacherGroup{
			Key:          keyStr,
			ID:           keyStr,
			Kind:         DuplicateGroupCrossCourse,
			Confidence:   "hint",
			Mergeable:    false,
			MergeAllowed: false,
			Note:         note,
			Reasons:      []string{note},
			Teachers:     tViews,
		})
	}

	return groups, nil
}

func pickSuggestedKeeper(rows []governanceTeacherRow) governanceTeacherRow {
	if len(rows) == 0 {
		return governanceTeacherRow{}
	}
	sorted := make([]governanceTeacherRow, len(rows))
	copy(sorted, rows)
	sort.Slice(sorted, func(i, j int) bool {
		a, b := sorted[i], sorted[j]
		if a.Verified != b.Verified {
			return a.Verified
		}
		sourceRank := func(s string) int {
			switch s {
			case models.TeacherSourceEduSchedule:
				return 3
			case models.TeacherSourceAdmin:
				return 2
			case models.TeacherSourceLegacy:
				return 1
			default:
				return 0
			}
		}
		if sourceRank(a.CanonicalSource) != sourceRank(b.CanonicalSource) {
			return sourceRank(a.CanonicalSource) > sourceRank(b.CanonicalSource)
		}
		if a.RatingCount != b.RatingCount {
			return a.RatingCount > b.RatingCount
		}
		if !a.CreatedAt.Equal(b.CreatedAt) {
			return a.CreatedAt.Before(b.CreatedAt)
		}
		return a.ID < b.ID
	})
	return sorted[0]
}

// ---------------- 合并规划与执行 ----------------

// CourseMergeDecision 伴随教师合并执行的课程归并决策。
type CourseMergeDecision struct {
	LoserSubjectID     uint `json:"loser_subject_id"`
	KeeperSubjectID    uint `json:"keeper_subject_id"`
	MergeSubjectEntity bool `json:"merge_subject_entity"`
}

// GovernanceDecisions 结构化治理决策。
type GovernanceDecisions struct {
	TeacherAliases []string              `json:"teacher_aliases,omitempty"`
	CourseAliases  []string              `json:"course_aliases,omitempty"`
	SubjectMerges  []CourseMergeDecision `json:"subject_merges,omitempty"`
}

// MergeInput 合并请求体。
type MergeInput struct {
	KeeperID               uint                  `json:"keeper_id"`
	LoserIDs               []uint                `json:"loser_ids"`
	SnapshotToken          string                `json:"snapshot_token,omitempty"`
	CourseMerges           []CourseMergeDecision `json:"course_merges,omitempty"`
	RegisterTeacherAliases *bool                 `json:"register_teacher_aliases,omitempty"`
	RegisterAliasesCompat  *bool                 `json:"register_aliases,omitempty"`
	Decisions              *GovernanceDecisions  `json:"decisions,omitempty"`
	FinalTeacherName       string                `json:"final_teacher_name,omitempty"`
	Reason                 string                `json:"reason,omitempty"`
}

type aliasPlanItem struct {
	Alias      string `json:"alias"`
	Normalized string `json:"normalized_alias"`
	TargetID   uint   `json:"target_id"`
	TargetName string `json:"target_name"`
	Status     string `json:"status"` // to_create | existing_same_target | conflict
	Conflict   string `json:"conflict,omitempty"`
}

type loserPlan struct {
	Teacher               GovernanceTeacherView `json:"teacher"`
	ActiveRatings         int                   `json:"active_ratings"`
	MigratedRatings       int                   `json:"migrated_ratings"`
	SoftDeletedRatings    int                   `json:"soft_deleted_ratings"`
	MovedVotes            int                   `json:"moved_votes"`
	RelinkedSubmissions   int                   `json:"relinked_submissions"`
	SupersededSubmissions int                   `json:"superseded_submissions"`
	DuplicateUsers        []uint                `json:"duplicate_users"`
	AlreadyMerged         bool                  `json:"already_merged"`
}

type courseMergePlan struct {
	LoserSubjectID      uint   `json:"loser_subject_id"`
	LoserSubjectName    string `json:"loser_subject_name"`
	KeeperSubjectID     uint   `json:"keeper_subject_id"`
	KeeperSubjectName   string `json:"keeper_subject_name"`
	MergeSubjectEntity  bool   `json:"merge_subject_entity"`
	RehungTeachers      int    `json:"rehung_teachers"`
	CollisionTeachers   int    `json:"collision_teachers"`
	RelinkedSubmissions int    `json:"relinked_submissions"`
	CourseAlias         string `json:"course_alias,omitempty"`
	CourseAliasStatus   string `json:"course_alias_status,omitempty"`
}

// RatingConflictDetail 评价冲突明细（详尽展示给管理员）。
// RatingConflictLoserItem 冲突中被淘汰的评价明细（供治理工作台展示）。
type RatingConflictLoserItem struct {
	RatingID  uint   `json:"rating_id"`
	TeacherID uint   `json:"teacher_id"`
	Star      int    `json:"star"`
	Comment   string `json:"comment"`
}

type RatingConflictDetail struct {
	UserID              uint                      `json:"user_id"`
	Nickname            string                    `json:"nickname"`
	UserNickname        string                    `json:"user_nickname,omitempty"`
	KeeperRatingID      uint                      `json:"keeper_rating_id"`
	KeeperRatingStar    int                       `json:"keeper_rating_star"`
	KeeperRatingComment string                    `json:"keeper_rating_comment"`
	LoserRatingID       uint                      `json:"loser_rating_id"`
	LoserRatingStar     int                       `json:"loser_rating_star"`
	LoserRatingComment  string                    `json:"loser_rating_comment"`
	WinnerRatingID      uint                      `json:"winner_rating_id"`
	WinnerRatingStar    int                       `json:"winner_rating_star"`
	WinnerCreatedAt     *time.Time                `json:"winner_created_at,omitempty"`
	LoserRatings        []RatingConflictLoserItem `json:"loser_ratings"`
	WinnerSubmissionID  *uint                     `json:"winner_submission_id,omitempty"`
}

// MergePlan 合并影响预览：完全基于只读计算，绝不写数据库。
type MergePlan struct {
	SnapshotToken    string                `json:"snapshot_token"`
	MergeAllowed     bool                  `json:"merge_allowed"`
	BlockReason      string                `json:"block_reason,omitempty"`
	Keeper           GovernanceTeacherView `json:"keeper"`
	Losers           []loserPlan           `json:"losers"`
	LoserIDs         []uint                `json:"loser_ids,omitempty"`
	IdempotentLosers []uint                `json:"idempotent_losers"`
	CourseMerges     []courseMergePlan     `json:"course_merges"`
	SubjectMerges    []courseMergePlan     `json:"subject_merges,omitempty"`
	TeacherAliases   []aliasPlanItem       `json:"teacher_aliases"`
	CourseAliases    []aliasPlanItem       `json:"course_aliases"`
	Conflicts        []string              `json:"conflicts,omitempty"`
	HasConflicts     bool                  `json:"has_conflicts"`

	TotalRatingsMigrated       int                    `json:"ratings_migrated"`
	TotalRatingsSoftDeleted    int                    `json:"ratings_soft_deleted"`
	TotalRatingsPreserved      int                    `json:"ratings_preserved"`
	RatingConflictsCount       int                    `json:"rating_conflicts_count"`
	RatingConflicts            []RatingConflictDetail `json:"rating_conflicts,omitempty"`
	RatingConflictDetails      []RatingConflictDetail `json:"rating_conflict_details,omitempty"`
	TotalVotesMigrated         int                    `json:"votes_migrated"`
	TotalVoteConflictsDeduped  int                    `json:"vote_conflicts_deduped"`
	VotesDeduped               int                    `json:"votes_deduped"`
	TotalSubmissionsMigrated   int                    `json:"submissions_migrated"`
	TotalSubmissionsSuperseded int                    `json:"submissions_superseded"`

	TotalTeachersBefore int `json:"total_teachers_before"`
	TotalTeachersAfter  int `json:"total_teachers_after"`
	TotalSubjectsBefore int `json:"total_subjects_before"`
	TotalSubjectsAfter  int `json:"total_subjects_after"`
}

// CourseMergeTeacherPair 课程合并中配对的教师
type CourseMergeTeacherPair struct {
	LoserTeacherID   uint   `json:"loser_teacher_id"`
	KeeperTeacherID  uint   `json:"keeper_teacher_id"`
	FinalTeacherName string `json:"final_teacher_name"`
}

// CourseMergeInput 独立课程合并输入
type CourseMergeInput struct {
	KeeperSubjectID uint                     `json:"keeper_subject_id"`
	LoserSubjectIDs []uint                   `json:"loser_subject_ids"`
	FinalCourseName string                   `json:"final_course_name"`
	TeacherPairs    []CourseMergeTeacherPair `json:"teacher_pairs"`
	Reason          string                   `json:"reason"`
	SnapshotToken   string                   `json:"snapshot_token,omitempty"`
}

type CourseSubjectSummary struct {
	ID           uint    `json:"id"`
	Name         string  `json:"name"`
	Verified     bool    `json:"verified"`
	TeacherCount int     `json:"teacher_count"`
	RatingCount  int     `json:"rating_count"`
	AverageStar  float64 `json:"average_star"`
}

type MigratingTeacherSummary struct {
	TeacherID   uint   `json:"teacher_id"`
	TeacherName string `json:"teacher_name"`
	FromSubject string `json:"from_subject"`
	ToSubject   string `json:"to_subject"`
	RatingCount int    `json:"rating_count"`
}

type PairedTeacherMergeSummary struct {
	LoserTeacherID     uint   `json:"loser_teacher_id"`
	LoserTeacherName   string `json:"loser_teacher_name"`
	KeeperTeacherID    uint   `json:"keeper_teacher_id"`
	KeeperTeacherName  string `json:"keeper_teacher_name"`
	FinalTeacherName   string `json:"final_teacher_name"`
	MigratedRatings    int    `json:"migrated_ratings"`
	SoftDeletedRatings int    `json:"soft_deleted_ratings"`
	MigratedVotes      int    `json:"migrated_votes"`
}

// CourseMergePreviewResult 独立课程合并预览结果
type CourseMergePreviewResult struct {
	SnapshotToken            string                      `json:"snapshot_token"`
	MergeAllowed             bool                        `json:"merge_allowed"`
	BlockReason              string                      `json:"block_reason,omitempty"`
	Conflicts                []string                    `json:"conflicts,omitempty"`
	KeeperSubject            CourseSubjectSummary        `json:"keeper_subject"`
	LoserSubjects            []CourseSubjectSummary      `json:"loser_subjects"`
	FinalCourseName          string                      `json:"final_course_name"`
	MigratingTeachers        []MigratingTeacherSummary   `json:"migrating_teachers"`
	PairedTeacherMerges      []PairedTeacherMergeSummary `json:"paired_teacher_merges"`
	TotalRatingsMigrating    int                         `json:"total_ratings_migrating"`
	TotalRatingsDeduped      int                         `json:"total_ratings_deduped"`
	TotalVotesMigrating      int                         `json:"total_votes_migrating"`
	TotalSubmissionsRelinked int                         `json:"total_submissions_relinked"`
	CourseAliasesToCreate    []string                    `json:"course_aliases_to_create"`
}

type GovernanceCourseItem struct {
	ID           uint    `json:"id"`
	Name         string  `json:"name"`
	Verified     bool    `json:"verified"`
	TeacherCount int     `json:"teacher_count"`
	RatingCount  int     `json:"rating_count"`
	AverageStar  float64 `json:"average_star"`
}

// computeSnapshotToken 计算涉及实体的状态快照 Token。
func computeSnapshotToken(db *gorm.DB, keeperID uint, loserIDs []uint, finalTeacherName string) string {
	allIDs := append([]uint{keeperID}, loserIDs...)
	sort.Slice(allIDs, func(i, j int) bool { return allIDs[i] < allIDs[j] })

	h := sha256.New()
	if strings.TrimSpace(finalTeacherName) != "" {
		fmt.Fprintf(h, "FN:%s;", strings.TrimSpace(finalTeacherName))
	}

	type teacherSnap struct {
		ID              uint
		UpdatedAt       time.Time
		MergedIntoID    *uint
		Verified        bool
		CourseSubjectID *uint
	}
	var teachers []teacherSnap
	db.Table("teachers").Where("id IN ?", allIDs).Order("id ASC").Scan(&teachers)

	for _, t := range teachers {
		merged := uint(0)
		if t.MergedIntoID != nil {
			merged = *t.MergedIntoID
		}
		subj := uint(0)
		if t.CourseSubjectID != nil {
			subj = *t.CourseSubjectID
		}
		fmt.Fprintf(h, "T:%d:%d:%d:%v:%d;", t.ID, t.UpdatedAt.UnixNano(), merged, t.Verified, subj)
	}

	// 活动评价明细：id/user_id/teacher_id/created_at/updated_at/status。
	// 管理员的 Preview 展示与执行结果都依赖这些字段，必须进入快照。
	var ratings []models.TeacherRating
	db.Where("teacher_id IN ? AND deleted_at IS NULL", allIDs).
		Order("id ASC").Find(&ratings)
	for _, r := range ratings {
		fmt.Fprintf(h, "R:%d:%d:%d:%d:%d:%s;", r.ID, r.UserID, r.TeacherID, r.CreatedAt.UnixNano(), r.UpdatedAt.UnixNano(), r.Status)
	}

	// 投票明细：id/rating_id/user_id/vote_type/updated_at。
	ratingIDs := make([]uint, 0, len(ratings))
	for _, r := range ratings {
		ratingIDs = append(ratingIDs, r.ID)
	}
	if len(ratingIDs) > 0 {
		var votes []models.TeacherRatingVote
		db.Where("rating_id IN ?", ratingIDs).Order("id ASC").Find(&votes)
		for _, v := range votes {
			fmt.Fprintf(h, "V:%d:%d:%d:%s:%d;", v.ID, v.RatingID, v.UserID, v.VoteType, v.UpdatedAt.UnixNano())
		}
	}

	// 提交明细：id/teacher_id/teacher_rating_id/status/revision/updated_at。
	var subs []models.CourseEvaluationSubmission
	db.Where("teacher_id IN ?", allIDs).Order("id ASC").Find(&subs)
	for _, s := range subs {
		ratingRef := uint(0)
		if s.TeacherRatingID != nil {
			ratingRef = *s.TeacherRatingID
		}
		fmt.Fprintf(h, "S:%d:%d:%d:%s:%d:%d;", s.ID, derefUint(s.TeacherID), ratingRef, s.Status, s.Revision, s.UpdatedAt.UnixNano())
	}

	var aliases []models.TeacherAlias
	db.Where("teacher_id IN ?", allIDs).Order("id ASC").Find(&aliases)
	for _, a := range aliases {
		fmt.Fprintf(h, "A:%d:%d:%s;", a.ID, a.CourseSubjectID, a.NormalizedAlias)
	}

	// 学科实体状态：id/verified/updated_at。
	subjectIDs := make([]uint, 0)
	seenSubj := map[uint]bool{}
	for _, t := range teachers {
		if t.CourseSubjectID != nil && !seenSubj[*t.CourseSubjectID] {
			seenSubj[*t.CourseSubjectID] = true
			subjectIDs = append(subjectIDs, *t.CourseSubjectID)
		}
	}
	if len(subjectIDs) > 0 {
		var subjects []models.CourseSubject
		db.Where("id IN ?", subjectIDs).Order("id ASC").Find(&subjects)
		for _, cs := range subjects {
			fmt.Fprintf(h, "CS:%d:%v:%d;", cs.ID, cs.Verified, cs.UpdatedAt.UnixNano())
		}
	}

	return hex.EncodeToString(h.Sum(nil))
}

// computeCourseMergeSnapshotToken 计算课程合并涉及实体的状态快照 Token。
// 完整覆盖课程实体、教师实体、课程别名、教师评价、评价投票、教师别名与评价提交。
func computeCourseMergeSnapshotToken(db *gorm.DB, keeperID uint, loserIDs []uint, finalCourseName string, pairs []CourseMergeTeacherPair) string {
	allSubjectIDs := append([]uint{keeperID}, loserIDs...)
	sort.Slice(allSubjectIDs, func(i, j int) bool { return allSubjectIDs[i] < allSubjectIDs[j] })

	h := sha256.New()
	fmt.Fprintf(h, "FCN:%s;", strings.TrimSpace(finalCourseName))

	for _, p := range pairs {
		fmt.Fprintf(h, "P:%d:%d:%s;", p.LoserTeacherID, p.KeeperTeacherID, strings.TrimSpace(p.FinalTeacherName))
	}

	var subjects []models.CourseSubject
	db.Where("id IN ?", allSubjectIDs).Order("id ASC").Find(&subjects)
	for _, s := range subjects {
		mID := uint(0)
		if s.MergedIntoID != nil {
			mID = *s.MergedIntoID
		}
		fmt.Fprintf(h, "S:%d:%s:%s:%d:%d;", s.ID, s.Name, s.NormalizedName, mID, s.UpdatedAt.UnixNano())
	}

	var teachers []models.Teacher
	db.Where("course_subject_id IN ?", allSubjectIDs).Order("id ASC").Find(&teachers)
	allTeacherIDs := make([]uint, 0, len(teachers))
	for _, t := range teachers {
		allTeacherIDs = append(allTeacherIDs, t.ID)
		mID := uint(0)
		if t.MergedIntoID != nil {
			mID = *t.MergedIntoID
		}
		fmt.Fprintf(h, "T:%d:%s:%s:%d:%d;", t.ID, t.Name, t.Course, mID, t.UpdatedAt.UnixNano())
	}

	var aliases []models.CourseSubjectAlias
	db.Where("course_subject_id IN ?", allSubjectIDs).Order("id ASC").Find(&aliases)
	for _, a := range aliases {
		fmt.Fprintf(h, "A:%d:%d:%s;", a.ID, a.CourseSubjectID, a.NormalizedAlias)
	}

	if len(allTeacherIDs) > 0 {
		var ratings []models.TeacherRating
		db.Where("teacher_id IN ? AND deleted_at IS NULL", allTeacherIDs).Order("id ASC").Find(&ratings)
		ratingIDs := make([]uint, 0, len(ratings))
		for _, r := range ratings {
			fmt.Fprintf(h, "R:%d:%d:%d:%d:%d;", r.ID, r.TeacherID, r.UserID, r.Star, r.UpdatedAt.UnixNano())
			ratingIDs = append(ratingIDs, r.ID)
		}

		if len(ratingIDs) > 0 {
			var votes []models.TeacherRatingVote
			db.Where("rating_id IN ?", ratingIDs).Order("id ASC").Find(&votes)
			for _, v := range votes {
				fmt.Fprintf(h, "V:%d:%d:%d:%s:%d;", v.ID, v.RatingID, v.UserID, v.VoteType, v.UpdatedAt.UnixNano())
			}
		}

		var teacherAliases []models.TeacherAlias
		db.Where("teacher_id IN ?", allTeacherIDs).Order("id ASC").Find(&teacherAliases)
		for _, ta := range teacherAliases {
			fmt.Fprintf(h, "TA:%d:%d:%d:%s;", ta.ID, ta.TeacherID, ta.CourseSubjectID, ta.NormalizedAlias)
		}
	}

	var subs []models.CourseEvaluationSubmission
	db.Where("course_subject_id IN ? OR teacher_id IN ?", allSubjectIDs, allTeacherIDs).Order("id ASC").Find(&subs)
	for _, s := range subs {
		ratingRef := uint(0)
		if s.TeacherRatingID != nil {
			ratingRef = *s.TeacherRatingID
		}
		fmt.Fprintf(h, "Sub:%d:%d:%d:%d:%s:%d:%d;", s.ID, derefUint(s.TeacherID), derefUint(s.CourseSubjectID), ratingRef, s.Status, s.Revision, s.UpdatedAt.UnixNano())
	}

	return hex.EncodeToString(h.Sum(nil))
}

// buildMergePlan 构建合并计划。
func (s *TeacherGovernanceService) buildMergePlan(db *gorm.DB, input MergeInput) (*MergePlan, error) {
	if input.KeeperID == 0 || len(input.LoserIDs) == 0 {
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "必须指定合并目标与至少一位被合并教师", nil)
	}
	if input.Decisions != nil && len(input.Decisions.SubjectMerges) > 0 && len(input.CourseMerges) == 0 {
		input.CourseMerges = input.Decisions.SubjectMerges
	}

	loserSet := map[uint]bool{}
	uniqueLosers := make([]uint, 0, len(input.LoserIDs))
	for _, id := range input.LoserIDs {
		if id == 0 {
			continue
		}
		if id == input.KeeperID || loserSet[id] {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "合并列表中包含目标教师本人或重复项", nil)
		}
		loserSet[id] = true
		uniqueLosers = append(uniqueLosers, id)
	}
	if len(uniqueLosers) == 0 {
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "必须指定至少一位被合并教师", nil)
	}

	var keeper models.Teacher
	if err := db.Where("id = ?", input.KeeperID).First(&keeper).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, governanceErr(CodeTeacherNotFound, "目标教师不存在", nil)
		}
		return nil, governanceErr(CodeTeacherNotFound, "读取目标教师失败", err)
	}
	if keeper.MergedIntoID != nil {
		return nil, governanceErr(CodeTeacherAlreadyMerged, "目标教师已被合并，不能作为合并目标", nil)
	}
	keeperSubjectID := derefUint(keeper.CourseSubjectID)

	plan := &MergePlan{
		TeacherAliases:  []aliasPlanItem{},
		CourseAliases:   []aliasPlanItem{},
		Conflicts:       []string{},
		RatingConflicts: []RatingConflictDetail{},
		MergeAllowed:    true,
	}

	decisionBySubject := map[uint]CourseMergeDecision{}
	for _, decision := range input.CourseMerges {
		if decision.KeeperSubjectID == 0 || decision.LoserSubjectID == 0 {
			return nil, governanceErr(CodeInvalidGovernanceDecision, "课程归并决策缺少学科 ID", nil)
		}
		if decision.KeeperSubjectID != keeperSubjectID {
			return nil, governanceErr(CodeInvalidGovernanceDecision, "课程归并目标必须是目标教师所属学科", nil)
		}
		decisionBySubject[decision.LoserSubjectID] = decision
	}

	registerAliases := true
	if input.RegisterTeacherAliases != nil {
		registerAliases = *input.RegisterTeacherAliases
	} else if input.RegisterAliasesCompat != nil {
		registerAliases = *input.RegisterAliasesCompat
	}

	ratingCount := func(teacherID uint) int {
		var count int64
		db.Model(&models.TeacherRating{}).
			Where("teacher_id = ? AND deleted_at IS NULL AND status = ?", teacherID, "normal").
			Count(&count)
		return int(count)
	}
	pendingCount := func(teacherID uint) int {
		var count int64
		db.Model(&models.CourseEvaluationSubmission{}).
			Where("teacher_id = ? AND status = ?", teacherID, models.CourseEvaluationStatusPending).
			Count(&count)
		return int(count)
	}

	plan.Keeper = teacherViewOf(db, keeper, ratingCount(keeper.ID), pendingCount(keeper.ID))

	finalTName := strings.TrimSpace(input.FinalTeacherName)
	if finalTName != "" {
		if len([]rune(finalTName)) > models.TeacherNameMaxLength {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "最终教师名称超出长度上限", nil)
		}
		if keeperSubjectID != 0 {
			normalizedFinal := models.NormalizeTeacherName(finalTName)
			var conflictT models.Teacher
			err := db.Where("course_subject_id = ? AND name_normalized = ? AND id != ? AND merged_into_id IS NULL",
				keeperSubjectID, normalizedFinal, keeper.ID).First(&conflictT).Error
			if err == nil && !loserSet[conflictT.ID] {
				msg := fmt.Sprintf("最终教师姓名 %q 与同一学科下已有活动教师 %q(#%d) 冲突", finalTName, conflictT.Name, conflictT.ID)
				plan.Conflicts = append(plan.Conflicts, msg)
				plan.MergeAllowed = false
				plan.BlockReason = msg
			}
		}
		plan.Keeper.Name = finalTName
	}

	// 读取 keeper 上的所有活动评价（按 user_id 索引，供冲突比对）
	var keeperRatings []models.TeacherRating
	db.Where("teacher_id = ? AND deleted_at IS NULL AND status = ?", keeper.ID, "normal").Find(&keeperRatings)
	keeperRatingsByUser := map[uint]models.TeacherRating{}
	for _, r := range keeperRatings {
		keeperRatingsByUser[r.UserID] = r
	}

	// 汇总所有 loser 的所有活动评价
	var allLoserRatings []models.TeacherRating
	db.Where("teacher_id IN ? AND deleted_at IS NULL AND status = ?", uniqueLosers, "normal").
		Order("created_at DESC, id DESC").Find(&allLoserRatings)
	loserRatingsByUser := map[uint][]models.TeacherRating{}
	for _, r := range allLoserRatings {
		loserRatingsByUser[r.UserID] = append(loserRatingsByUser[r.UserID], r)
	}

	// 计算评价冲突与明细
	for userID, lRatings := range loserRatingsByUser {
		kRating, hasKeeper := keeperRatingsByUser[userID]
		if !hasKeeper && len(lRatings) == 1 {
			// 无冲突，直接迁移 1 条
			plan.TotalRatingsMigrated++
			continue
		}
		// 存在冲突（多个 loser 有同用户评价，或者 keeper 与 loser 有同用户评价）
		plan.RatingConflictsCount++
		allCandidateRatings := make([]models.TeacherRating, 0, len(lRatings)+1)
		if hasKeeper {
			allCandidateRatings = append(allCandidateRatings, kRating)
		}
		allCandidateRatings = append(allCandidateRatings, lRatings...)
		sort.Slice(allCandidateRatings, func(i, j int) bool {
			if !allCandidateRatings[i].CreatedAt.Equal(allCandidateRatings[j].CreatedAt) {
				return allCandidateRatings[i].CreatedAt.After(allCandidateRatings[j].CreatedAt)
			}
			return allCandidateRatings[i].ID > allCandidateRatings[j].ID
		})
		winner := allCandidateRatings[0]

		// 统计口径与执行一致：仅当胜出评价来自 loser 时才发生"迁移"；
		// 若 keeper 原评价胜出，则 loser 评价全部软删，迁移数为 0。
		if !hasKeeper || winner.ID != kRating.ID {
			plan.TotalRatingsMigrated++
		} else {
			plan.TotalRatingsPreserved++
		}
		plan.TotalRatingsSoftDeleted += len(allCandidateRatings) - 1

		var userObj models.User
		nickname := ""
		if err := db.Select("nickname").First(&userObj, userID).Error; err == nil {
			nickname = userObj.Nickname
		}

		firstLoserRating := lRatings[0]
		detail := RatingConflictDetail{
			UserID:              userID,
			Nickname:            nickname,
			UserNickname:        nickname,
			KeeperRatingID:      kRating.ID,
			KeeperRatingStar:    kRating.Star,
			KeeperRatingComment: kRating.Comment,
			LoserRatingID:       firstLoserRating.ID,
			LoserRatingStar:     firstLoserRating.Star,
			LoserRatingComment:  firstLoserRating.Comment,
			WinnerRatingID:      winner.ID,
			WinnerRatingStar:    winner.Star,
			WinnerCreatedAt:     &winner.CreatedAt,
		}
		for _, cr := range allCandidateRatings {
			if cr.ID == winner.ID {
				continue
			}
			detail.LoserRatings = append(detail.LoserRatings, RatingConflictLoserItem{
				RatingID:  cr.ID,
				TeacherID: cr.TeacherID,
				Star:      cr.Star,
				Comment:   cr.Comment,
			})
		}
		var winnerSub models.CourseEvaluationSubmission
		if err := db.Where("teacher_rating_id = ?", winner.ID).First(&winnerSub).Error; err == nil {
			detail.WinnerSubmissionID = &winnerSub.ID
		}
		plan.RatingConflicts = append(plan.RatingConflicts, detail)

		// 统计投票去重与迁移
		ratingIDs := make([]uint, 0, len(allCandidateRatings))
		for _, r := range allCandidateRatings {
			ratingIDs = append(ratingIDs, r.ID)
		}
		var votes []models.TeacherRatingVote
		db.Where("rating_id IN ?", ratingIDs).Order("updated_at DESC, id DESC").Find(&votes)
		seenVoters := map[uint]bool{}
		for _, v := range votes {
			if seenVoters[v.UserID] {
				plan.TotalVoteConflictsDeduped++
			} else {
				seenVoters[v.UserID] = true
				if v.RatingID != winner.ID {
					plan.TotalVotesMigrated++
				}
			}
		}

		// 统计提交记录归并与 superseded 数量
		loserRatingIDs := make([]uint, 0, len(allCandidateRatings)-1)
		for _, r := range allCandidateRatings {
			if r.ID != winner.ID {
				loserRatingIDs = append(loserRatingIDs, r.ID)
			}
		}
		var supersededCount int64
		db.Model(&models.CourseEvaluationSubmission{}).Where("teacher_rating_id IN ?", loserRatingIDs).Count(&supersededCount)
		plan.TotalSubmissionsSuperseded += int(supersededCount)
	}

	// 统计普通提交迁移数量
	var normalSubCount int64
	db.Model(&models.CourseEvaluationSubmission{}).
		Where("teacher_id IN ? AND status <> ?", uniqueLosers, models.CourseEvaluationStatusSuperseded).
		Count(&normalSubCount)
	plan.TotalSubmissionsMigrated = int(normalSubCount)

	// 分析各个 loser
	mergeIgnoreTeacherIDs := map[uint]bool{keeper.ID: true}
	for _, id := range uniqueLosers {
		mergeIgnoreTeacherIDs[id] = true
	}

	var queriedLosers []models.Teacher
	for _, loserID := range uniqueLosers {
		var loser models.Teacher
		if err := db.Where("id = ?", loserID).First(&loser).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil, governanceErr(CodeTeacherNotFound, fmt.Sprintf("被合并教师 #%d 不存在", loserID), nil)
			}
			return nil, governanceErr(CodeTeacherNotFound, "读取被合并教师失败", err)
		}
		queriedLosers = append(queriedLosers, loser)
		if loser.MergedIntoID != nil {
			if *loser.MergedIntoID == keeper.ID {
				plan.IdempotentLosers = append(plan.IdempotentLosers, loser.ID)
				plan.Losers = append(plan.Losers, loserPlan{
					Teacher:       teacherViewOf(db, loser, ratingCount(loser.ID), pendingCount(loser.ID)),
					AlreadyMerged: true,
				})
				continue
			}
			return nil, governanceErr(CodeTeacherAlreadyMerged, fmt.Sprintf("教师 #%d 已被合并至其他教师(#%d)", loser.ID, *loser.MergedIntoID), nil)
		}

		loserSubj := derefUint(loser.CourseSubjectID)
		if loserSubj != 0 && loserSubj != keeperSubjectID {
			decision, hasDecision := decisionBySubject[loserSubj]
			if !hasDecision {
				msg := fmt.Sprintf("教师 %q 与目标属于不同课程，请选择课程处理方式（仅合并教师或同时归并课程）", loser.Name)
				plan.Conflicts = append(plan.Conflicts, msg)
				plan.MergeAllowed = false
				plan.BlockReason = msg
			} else if decision.MergeSubjectEntity {
				// 情况 B：教师 + 课程一起合并，检查原课程是否仍有其他活动教师
				var leftoverCount int64
				db.Model(&models.Teacher{}).
					Where("course_subject_id = ? AND merged_into_id IS NULL AND id NOT IN ?", loserSubj, uniqueLosers).
					Count(&leftoverCount)
				if leftoverCount > 0 {
					msg := fmt.Sprintf("原课程仍有 %d 位活动教师，不满足课程合并条件（仅在 loser 课程无其他活动教师时允许合并）", leftoverCount)
					plan.Conflicts = append(plan.Conflicts, msg)
					plan.MergeAllowed = false
					plan.BlockReason = msg
				}
			}
			// 情况 A：hasDecision && !decision.MergeSubjectEntity（仅合并教师，保留各自课程实体，允许合并）
		}

		var lRatingsThisLoser []models.TeacherRating
		db.Where("teacher_id = ? AND deleted_at IS NULL AND status = ?", loser.ID, "normal").Find(&lRatingsThisLoser)
		lpMigrated := 0
		lpSoftDeleted := 0
		lpMovedVotes := 0
		for _, r := range lRatingsThisLoser {
			allRatings := []models.TeacherRating{}
			if kr, ok := keeperRatingsByUser[r.UserID]; ok {
				allRatings = append(allRatings, kr)
			}
			if lrs, ok := loserRatingsByUser[r.UserID]; ok {
				allRatings = append(allRatings, lrs...)
			}
			sort.Slice(allRatings, func(i, j int) bool {
				if !allRatings[i].CreatedAt.Equal(allRatings[j].CreatedAt) {
					return allRatings[i].CreatedAt.After(allRatings[j].CreatedAt)
				}
				return allRatings[i].ID > allRatings[j].ID
			})
			if len(allRatings) > 0 {
				winner := allRatings[0]
				if winner.ID == r.ID {
					lpMigrated++
				} else {
					lpSoftDeleted++
					var vc int64
					db.Model(&models.TeacherRatingVote{}).Where("rating_id = ?", r.ID).Count(&vc)
					lpMovedVotes += int(vc)
				}
			}
		}

		var relinkedSubCount, supersededSubCount int64
		db.Model(&models.CourseEvaluationSubmission{}).
			Where("teacher_id = ? AND status <> ?", loser.ID, models.CourseEvaluationStatusSuperseded).
			Count(&relinkedSubCount)
		var thisLoserRatingIDs []uint
		for _, r := range lRatingsThisLoser {
			thisLoserRatingIDs = append(thisLoserRatingIDs, r.ID)
		}
		if len(thisLoserRatingIDs) > 0 {
			db.Model(&models.CourseEvaluationSubmission{}).
				Where("teacher_id = ? AND teacher_rating_id IN ?", loser.ID, thisLoserRatingIDs).
				Count(&supersededSubCount)
		}

		lp := loserPlan{
			Teacher:               teacherViewOf(db, loser, ratingCount(loser.ID), pendingCount(loser.ID)),
			ActiveRatings:         len(lRatingsThisLoser),
			MigratedRatings:       lpMigrated,
			SoftDeletedRatings:    lpSoftDeleted,
			MovedVotes:            lpMovedVotes,
			RelinkedSubmissions:   int(relinkedSubCount),
			SupersededSubmissions: int(supersededSubCount),
		}
		plan.Losers = append(plan.Losers, lp)

		// 教师别名规划
		if registerAliases && models.NormalizeTeacherName(loser.Name) != models.NormalizeTeacherName(keeper.Name) {
			targetSubject := keeperSubjectID
			if targetSubject != 0 {
				aliasItem, conflictMsg, err := planTeacherAlias(db, targetSubject, loser.Name, keeper.ID, keeper.Name, mergeIgnoreTeacherIDs)
				if err != nil {
					return nil, err
				}
				plan.TeacherAliases = append(plan.TeacherAliases, aliasItem)
				if conflictMsg != "" {
					plan.Conflicts = append(plan.Conflicts, conflictMsg)
					plan.MergeAllowed = false
					plan.BlockReason = conflictMsg
				}
			}
		}
	}

	// 课程归并规划：优先使用输入决策，并自动发现未配置决策的跨学科 Loser
	plannedSubjects := map[uint]bool{}
	for _, decision := range input.CourseMerges {
		cmp, err := planCourseMerge(db, decision, keeper, mergeIgnoreTeacherIDs, plan)
		if err != nil {
			return nil, err
		}
		plan.CourseMerges = append(plan.CourseMerges, *cmp)
		plannedSubjects[decision.LoserSubjectID] = true
	}
	for _, loser := range queriedLosers {
		loserSubj := derefUint(loser.CourseSubjectID)
		if loserSubj != 0 && loserSubj != keeperSubjectID && !plannedSubjects[loserSubj] {
			defaultDecision := CourseMergeDecision{
				LoserSubjectID:     loserSubj,
				KeeperSubjectID:    keeperSubjectID,
				MergeSubjectEntity: false,
			}
			cmp, err := planCourseMerge(db, defaultDecision, keeper, mergeIgnoreTeacherIDs, plan)
			if err != nil {
				return nil, err
			}
			plan.CourseMerges = append(plan.CourseMerges, *cmp)
			plannedSubjects[loserSubj] = true
		}
	}

	plan.HasConflicts = len(plan.Conflicts) > 0
	plan.SnapshotToken = computeSnapshotToken(db, keeper.ID, uniqueLosers, input.FinalTeacherName)

	plan.TotalTeachersBefore = 1 + len(uniqueLosers)
	plan.TotalTeachersAfter = 1

	plan.RatingConflictDetails = plan.RatingConflicts
	plan.VotesDeduped = plan.TotalVoteConflictsDeduped
	plan.SubjectMerges = plan.CourseMerges
	plan.LoserIDs = uniqueLosers

	return plan, nil
}

// planTeacherAlias 计算教师别名状态。
func planTeacherAlias(db *gorm.DB, subjectID uint, alias string, targetID uint, targetName string, ignoreIDs map[uint]bool) (aliasPlanItem, string, error) {
	normalized := models.NormalizeTeacherName(alias)
	item := aliasPlanItem{
		Alias:      alias,
		Normalized: normalized,
		TargetID:   targetID,
		TargetName: targetName,
		Status:     "to_create",
	}
	if normalized == "" {
		return item, "", nil
	}

	// 1. 检查是否与同学科下其他活动教师 canonical name 冲突
	var liveTeacher models.Teacher
	err := db.Where("course_subject_id = ? AND name_normalized = ? AND merged_into_id IS NULL", subjectID, normalized).
		First(&liveTeacher).Error
	if err == nil {
		if !ignoreIDs[liveTeacher.ID] && liveTeacher.ID != targetID {
			msg := fmt.Sprintf("别名 %q 与已有真实教师 %q 规范化名称冲突", alias, liveTeacher.Name)
			item.Status = "conflict"
			item.Conflict = msg
			return item, msg, nil
		}
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return item, "", err
	}

	// 2. 检查既有别名
	var existing models.TeacherAlias
	err = db.Where("course_subject_id = ? AND normalized_alias = ?", subjectID, normalized).First(&existing).Error
	if err == nil {
		if existing.TeacherID == targetID || ignoreIDs[existing.TeacherID] {
			item.Status = "existing_same_target"
			return item, "", nil
		}
		var owner models.Teacher
		_ = db.Select("name").First(&owner, existing.TeacherID).Error
		msg := fmt.Sprintf("别名 %q 已指向教师 %q(#%d)，无法重定向至 %q", alias, owner.Name, existing.TeacherID, targetName)
		item.Status = "conflict"
		item.Conflict = msg
		return item, msg, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return item, "", err
	}
	return item, "", nil
}

// planCourseMerge 规划课程合并。
func planCourseMerge(db *gorm.DB, decision CourseMergeDecision, keeper models.Teacher, mergeIgnoreIDs map[uint]bool, plan *MergePlan) (*courseMergePlan, error) {
	var loserSubject, keeperSubject models.CourseSubject
	if err := db.First(&loserSubject, decision.LoserSubjectID).Error; err != nil {
		return nil, governanceErr(CodeTeacherNotFound, "课程归并源学科不存在", err)
	}
	if err := db.First(&keeperSubject, decision.KeeperSubjectID).Error; err != nil {
		return nil, governanceErr(CodeTeacherNotFound, "课程归并目标学科不存在", err)
	}

	cmp := &courseMergePlan{
		LoserSubjectID:     loserSubject.ID,
		LoserSubjectName:   loserSubject.Name,
		KeeperSubjectID:    keeperSubject.ID,
		KeeperSubjectName:  keeperSubject.Name,
		MergeSubjectEntity: decision.MergeSubjectEntity,
	}

	if decision.MergeSubjectEntity {
		aliasItem, conflictMsg, err := planCourseAliasExcluding(db, loserSubject.Name, keeperSubject.ID, keeperSubject.Name, []uint{loserSubject.ID})
		if err != nil {
			return nil, err
		}
		cmp.CourseAlias = loserSubject.Name
		cmp.CourseAliasStatus = aliasItem.Status
		plan.CourseAliases = append(plan.CourseAliases, aliasItem)
		if conflictMsg != "" {
			plan.Conflicts = append(plan.Conflicts, conflictMsg)
			plan.MergeAllowed = false
			plan.BlockReason = conflictMsg
		}
	}
	return cmp, nil
}

// planCourseAlias 规划课程别名。
func planCourseAlias(db *gorm.DB, alias string, keeperSubjectID uint, keeperSubjectName string) (aliasPlanItem, string, error) {
	return planCourseAliasExcluding(db, alias, keeperSubjectID, keeperSubjectName, nil)
}

func planCourseAliasExcluding(db *gorm.DB, alias string, keeperSubjectID uint, keeperSubjectName string, excludeSubjectIDs []uint) (aliasPlanItem, string, error) {
	normalized := models.NormalizeCourseSubjectName(alias)
	item := aliasPlanItem{
		Alias:      alias,
		Normalized: normalized,
		TargetID:   keeperSubjectID,
		TargetName: keeperSubjectName,
		Status:     "to_create",
	}

	// 1. 检查是否与独立其他活动学科冲突
	var canonical models.CourseSubject
	if err := db.Where("normalized_name = ? AND merged_into_id IS NULL", normalized).First(&canonical).Error; err == nil {
		isExcluded := canonical.ID == keeperSubjectID
		if !isExcluded {
			for _, id := range excludeSubjectIDs {
				if canonical.ID == id {
					isExcluded = true
					break
				}
			}
		}
		if !isExcluded {
			msg := fmt.Sprintf("课程别名 %q 与已有学科 %q(#%d) 规范化名称冲突", alias, canonical.Name, canonical.ID)
			item.Status = "conflict"
			item.Conflict = msg
			return item, msg, nil
		}
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return item, "", err
	}

	// 2. 检查既有别名
	var existing models.CourseSubjectAlias
	err := db.Where("normalized_alias = ?", normalized).First(&existing).Error
	if err == nil {
		if existing.CourseSubjectID == keeperSubjectID {
			item.Status = "existing_same_target"
			return item, "", nil
		}
		isExcluded := false
		for _, id := range excludeSubjectIDs {
			if existing.CourseSubjectID == id {
				isExcluded = true
				break
			}
		}
		if isExcluded {
			item.Status = "to_repoint"
			return item, "", nil
		}
		var owner models.CourseSubject
		_ = db.Select("name").First(&owner, existing.CourseSubjectID).Error
		msg := fmt.Sprintf("课程别名 %q 已指向学科 %q(#%d)，无法重定向至 %q", alias, owner.Name, existing.CourseSubjectID, keeperSubjectName)
		item.Status = "conflict"
		item.Conflict = msg
		return item, msg, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return item, "", err
	}
	return item, "", nil
}

// PreviewMerge 执行合并预览，纯只读计算，绝不写数据库。
func (s *TeacherGovernanceService) PreviewMerge(input MergeInput) (*MergePlan, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	return s.buildMergePlan(s.db, input)
}

// Merge 执行教师合并。整单一个原子事务：
// 加锁 → 校验 snapshot_token → 校验实体与课程 → 评价与投票迁移 → 提交处理 → 别名重挂 → 写审计与管理日志。
func (s *TeacherGovernanceService) Merge(adminID uint, input MergeInput) (*MergePlan, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if adminID == 0 {
		return nil, governanceErr(CodeTeacherGovernanceForbidden, "无权执行教师合并", nil)
	}

	if strings.TrimSpace(input.SnapshotToken) == "" {
		return nil, governanceErr(CodeGovernanceSnapshotRequired, "请先重新预览合并影响", nil)
	}

	plan, err := s.buildMergePlan(s.db, input)
	if err != nil {
		return nil, err
	}
	if !plan.MergeAllowed || plan.HasConflicts {
		return nil, governanceErrWithDetails(CodeMergeRatingConflict, "存在阻断性冲突，无法执行合并: "+plan.BlockReason, map[string]interface{}{
			"conflicts": plan.Conflicts,
		})
	}

	adminName := ""
	var admin models.User
	if err := s.db.Select("nickname").First(&admin, adminID).Error; err == nil {
		adminName = admin.Nickname
	}

	batchID := fmt.Sprintf("merge-%d", time.Now().UnixNano())

	allIDs := append([]uint{input.KeeperID}, input.LoserIDs...)
	sort.Slice(allIDs, func(i, j int) bool { return allIDs[i] < allIDs[j] })

	err = s.db.Transaction(func(tx *gorm.DB) error {
		// 1. 严格按 ID 顺序加写锁，防止死锁
		lockedTeachers := make(map[uint]models.Teacher, len(allIDs))
		for _, id := range allIDs {
			var lockedTeacher models.Teacher
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&lockedTeacher, id).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, fmt.Sprintf("锁定教师 #%d 失败", id), err)
			}
			lockedTeachers[id] = lockedTeacher
		}

		// 1b. 幂等重试：若所有请求的 loser 已经并入当前 keeper，说明上一次操作
		// 已成功（典型为响应在途中断后客户端重试），直接返回成功而不因 snapshot
		// 漂移误报 GOVERNANCE_SNAPSHOT_STALE。
		if len(input.LoserIDs) > 0 {
			allIdempotent := true
			for _, id := range input.LoserIDs {
				lt, ok := lockedTeachers[id]
				if !ok || lt.MergedIntoID == nil || *lt.MergedIntoID != input.KeeperID {
					allIdempotent = false
					break
				}
			}
			if allIdempotent {
				return nil
			}
		}

		// 2. 校验 snapshot_token，防止陈旧合并
		if strings.TrimSpace(input.SnapshotToken) == "" {
			return governanceErr(CodeGovernanceSnapshotRequired, "请先重新预览合并影响", nil)
		}
		currentToken := computeSnapshotToken(tx, input.KeeperID, input.LoserIDs, input.FinalTeacherName)
		if input.SnapshotToken != currentToken {
			return governanceErr(CodeGovernanceSnapshotStale, "数据状态已发生变更，请刷新预览后重试", nil)
		}

		// 2b. 自定义最终教师名称更新
		originalKeeperName := lockedTeachers[input.KeeperID].Name
		finalTName := strings.TrimSpace(input.FinalTeacherName)
		if finalTName == "" {
			finalTName = originalKeeperName
		}

		keeperSubject := derefUint(plan.Keeper.SubjectID)
		registerAliases := true
		if input.RegisterTeacherAliases != nil {
			registerAliases = *input.RegisterTeacherAliases
		} else if input.RegisterAliasesCompat != nil {
			registerAliases = *input.RegisterAliasesCompat
		}

		// 2c. 先合并归档全部 loser 教师，释放唯一名称占用
		for i := range plan.Losers {
			lp := &plan.Losers[i]
			if lp.AlreadyMerged {
				continue
			}
			stats, err := mergeSingleTeacher(tx, adminID, plan.Keeper.ID, lp.Teacher.ID)
			if err != nil {
				return err
			}
			lp.MigratedRatings = stats.MigratedRatings
			lp.SoftDeletedRatings = stats.SoftDeletedRatings
			lp.MovedVotes = stats.MovedVotes
			lp.RelinkedSubmissions = stats.RelinkedSubmissions
			lp.SupersededSubmissions = stats.SupersededSubmissions

			aliasAdded := false
			if registerAliases && models.NormalizeTeacherName(lp.Teacher.Name) != models.NormalizeTeacherName(finalTName) {
				if err := ensureTeacherAlias(tx, keeperSubject, lp.Teacher.Name, plan.Keeper.ID, finalTName, adminID); err != nil {
					return err
				}
				aliasAdded = true
			}

			tAliasCount := 0
			if aliasAdded {
				tAliasCount = 1
			}

			record := models.TeacherMergeRecord{
				BatchID:                   batchID,
				KeeperID:                  plan.Keeper.ID,
				LoserID:                   lp.Teacher.ID,
				KeeperNameSnapshot:        finalTName,
				LoserNameSnapshot:         lp.Teacher.Name,
				KeeperSubjectNameSnapshot: plan.Keeper.SubjectName,
				LoserSubjectNameSnapshot:  lp.Teacher.Course,
				MigratedRatings:           stats.MigratedRatings,
				SoftDeletedRatings:        stats.SoftDeletedRatings,
				MigratedVotes:             stats.MovedVotes,
				MigratedSubmissions:       stats.RelinkedSubmissions,
				SupersededSubmissions:     stats.SupersededSubmissions,
				CourseAliasesAdded:        0,
				TeacherAliasesAdded:       tAliasCount,
				AdminID:                   adminID,
				AdminName:                 adminName,
				Action:                    "teacher_merge",
				Reason:                    input.Reason,
				CreatedAt:                 time.Now(),
			}
			if err := tx.Create(&record).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "写入合并记录失败", err)
			}
		}

		// 2d. 自定义最终教师名称更新（在 loser 归档释放唯一名称占用后执行）
		if finalTName != "" && finalTName != originalKeeperName {
			if registerAliases && models.NormalizeTeacherName(originalKeeperName) != models.NormalizeTeacherName(finalTName) {
				if err := ensureTeacherAlias(tx, keeperSubject, originalKeeperName, plan.Keeper.ID, finalTName, adminID); err != nil {
					return err
				}
			}
			if err := tx.Model(&models.Teacher{}).Where("id = ?", input.KeeperID).Updates(map[string]interface{}{
				"name":            finalTName,
				"name_normalized": models.NormalizeTeacherName(finalTName),
			}).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "更新教师规范名称失败", err)
			}
			plan.Keeper.Name = finalTName

			// 同步更新 keeper 关联活动提交的 teacher_name 与规范 dedup_key
			var keeperSubs []models.CourseEvaluationSubmission
			if err := tx.Where("teacher_id = ? AND status <> ?", plan.Keeper.ID, models.CourseEvaluationStatusSuperseded).Find(&keeperSubs).Error; err == nil {
				for _, ks := range keeperSubs {
					cName := ks.CourseSubjectName
					if cName == "" {
						cName = plan.Keeper.SubjectName
					}
					newDK := models.CourseEvaluationDedupKey(ks.UserID, cName, finalTName)
					_ = tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", ks.ID).Updates(map[string]interface{}{
						"teacher_name": finalTName,
						"dedup_key":    newDK,
					}).Error
				}
			}
		}

		// 课程实体归并
		for _, cmp := range plan.CourseMerges {
			if !cmp.MergeSubjectEntity {
				continue
			}
			if err := mergeCourseSubjectEntity(tx, adminID, batchID, cmp, adminName); err != nil {
				return err
			}
		}

		logDetail := fmt.Sprintf("批次 %s：并入 %d 位教师", batchID, len(plan.Losers)-len(plan.IdempotentLosers))
		if strings.TrimSpace(input.Reason) != "" {
			logDetail += fmt.Sprintf("，原因：%s", strings.TrimSpace(input.Reason))
		}
		return writeCourseEvaluationAdminLog(tx, adminID, "合并教师", plan.Keeper.Name, logDetail)
	})

	if err != nil {
		return nil, err
	}
	return plan, nil
}

type loserExecutionStats struct {
	MigratedRatings       int
	SoftDeletedRatings    int
	MovedVotes            int
	RelinkedSubmissions   int
	SupersededSubmissions int
}

func mergeSingleTeacher(tx *gorm.DB, adminID, keeperID, loserID uint) (loserExecutionStats, error) {
	var stats loserExecutionStats
	if keeperID == loserID {
		return stats, nil
	}
	var keeper models.Teacher
	if err := tx.Where("id = ? AND merged_into_id IS NULL", keeperID).First(&keeper).Error; err != nil {
		return stats, governanceErr(CodeTeacherGovernanceStateConflict, "目标教师状态已变化，请刷新后重试", err)
	}
	var loser models.Teacher
	if err := tx.Where("id = ? AND merged_into_id IS NULL", loserID).First(&loser).Error; err != nil {
		return stats, governanceErr(CodeTeacherGovernanceStateConflict, "被合并教师状态已变化，请刷新后重试", err)
	}

	// 1) 迁移评价：同一用户冲突时按 (created_at DESC, id DESC) 保留最新
	var loserRatings []models.TeacherRating
	if err := tx.Where("teacher_id = ? AND deleted_at IS NULL", loser.ID).
		Order("created_at DESC, id DESC").Find(&loserRatings).Error; err != nil {
		return stats, governanceErr(CodeTeacherNotFound, "读取被合并教师评价失败", err)
	}

	for _, rating := range loserRatings {
		var keeperRating models.TeacherRating
		err := tx.Where("teacher_id = ? AND user_id = ? AND deleted_at IS NULL", keeper.ID, rating.UserID).
			First(&keeperRating).Error
		switch {
		case err == nil:
			// 存在冲突
			var winnerID, loserRatingID uint
			winnerIsLoser := false
			if keeperRating.CreatedAt.After(rating.CreatedAt) ||
				(keeperRating.CreatedAt.Equal(rating.CreatedAt) && keeperRating.ID > rating.ID) {
				winnerID = keeperRating.ID
				loserRatingID = rating.ID
			} else {
				winnerID = rating.ID
				loserRatingID = keeperRating.ID
				winnerIsLoser = true
			}

			// 必须先软删除 loser 评价（释放 keeper 上的 (teacher_id, user_id) 唯一索引槽位）
			if err := softDeleteRating(tx, loserRatingID, adminID); err != nil {
				return stats, err
			}
			stats.SoftDeletedRatings++

			// 胜出评价若来自 loser，在旧 keeper 评价已软删后重挂到 keeper
			if winnerIsLoser {
				if err := tx.Model(&models.TeacherRating{}).Where("id = ?", rating.ID).
					Update("teacher_id", keeper.ID).Error; err != nil {
					return stats, governanceErr(CodeTeacherNotFound, "重挂胜出评价失败", err)
				}
				stats.MigratedRatings++
			}

			// 投票重挂
			movedVotes, err := moveVotes(tx, loserRatingID, winnerID)
			if err != nil {
				return stats, err
			}
			stats.MovedVotes += movedVotes

			// 将 loser 评价的提交标记为 superseded
			superseded, err := supersedeSubmissionsOfDeletedRating(tx, loserRatingID, winnerID, keeper.ID)
			if err != nil {
				return stats, err
			}
			stats.SupersededSubmissions += superseded

			// 重算 winner 投票
			if err := recomputeRatingVoteCounts(tx, winnerID); err != nil {
				return stats, err
			}

		case errors.Is(err, gorm.ErrRecordNotFound):
			if err := tx.Model(&models.TeacherRating{}).Where("id = ?", rating.ID).
				Update("teacher_id", keeper.ID).Error; err != nil {
				return stats, governanceErr(CodeTeacherNotFound, "重挂评价失败", err)
			}
			stats.MigratedRatings++
		default:
			return stats, governanceErr(CodeTeacherNotFound, "查询评价冲突失败", err)
		}
	}

	// 2) 迁移未受冲突影响的普通提交并维护规范 DedupKey
	var loserSubmissions []models.CourseEvaluationSubmission
	if err := tx.Where("teacher_id = ? AND status <> ?", loser.ID, models.CourseEvaluationStatusSuperseded).
		Order("id ASC").Find(&loserSubmissions).Error; err != nil {
		return stats, governanceErr(CodeTeacherNotFound, "读取被合并教师提交记录失败", err)
	}

	targetCourseName := keeper.Course
	keeperSubjectID := derefUint(keeper.CourseSubjectID)
	if targetCourseName == "" && keeperSubjectID > 0 {
		var cs models.CourseSubject
		if tx.First(&cs, keeperSubjectID).Error == nil {
			targetCourseName = cs.Name
		}
	}

	for _, sub := range loserSubmissions {
		cName := targetCourseName
		if cName == "" {
			cName = sub.CourseSubjectName
		}
		newDedupKey := models.CourseEvaluationDedupKey(sub.UserID, cName, keeper.Name)
		var existingSub models.CourseEvaluationSubmission
		err := tx.Where("user_id = ? AND dedup_key = ? AND id <> ? AND status <> ?", sub.UserID, newDedupKey, sub.ID, models.CourseEvaluationStatusSuperseded).
			First(&existingSub).Error
		if err == nil {
			// 目标教师已有对应活动提交，此提交标记为 superseded
			if err := tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", sub.ID).Updates(map[string]interface{}{
				"status":              models.CourseEvaluationStatusSuperseded,
				"moderation_reason":   "teacher_merge_submission_superseded",
				"teacher_id":          keeper.ID,
				"teacher_name":        keeper.Name,
				"course_subject_id":   keeperSubjectID,
				"course_subject_name": cName,
			}).Error; err != nil {
				return stats, governanceErr(CodeTeacherNotFound, "更新冲突提交状态失败", err)
			}
			stats.SupersededSubmissions++
		} else if errors.Is(err, gorm.ErrRecordNotFound) {
			// 无冲突，重挂至目标并更新规范 DedupKey
			updates := map[string]interface{}{
				"teacher_id":   keeper.ID,
				"teacher_name": keeper.Name,
				"dedup_key":    newDedupKey,
			}
			if keeperSubjectID > 0 {
				updates["course_subject_id"] = keeperSubjectID
				updates["course_subject_name"] = cName
			}
			if err := tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", sub.ID).Updates(updates).Error; err != nil {
				return stats, governanceErr(CodeTeacherNotFound, "重挂提交记录失败", err)
			}
			stats.RelinkedSubmissions++
		} else {
			return stats, governanceErr(CodeTeacherNotFound, "查询目标提交冲突失败", err)
		}
	}

	// 3) 别名重挂（逐条处理，防止唯一索引冲突）
	keeperSubjectID = derefUint(keeper.CourseSubjectID)
	if err := reconcileTeacherAliases(tx, loser.ID, keeper.ID, keeperSubjectID); err != nil {
		return stats, err
	}

	// 4) 压平既有合并链条
	if err := tx.Model(&models.Teacher{}).Where("merged_into_id = ?", loser.ID).Update("merged_into_id", keeper.ID).Error; err != nil {
		return stats, governanceErr(CodeTeacherNotFound, "压平历史合并链条失败", err)
	}

	// 5) 标记 loser 为 merged
	if err := tx.Model(&models.Teacher{}).Where("id = ?", loser.ID).Update("merged_into_id", keeper.ID).Error; err != nil {
		return stats, governanceErr(CodeTeacherNotFound, "标记合并状态失败", err)
	}

	// 6) 继承 verified
	if loser.Verified && !keeper.Verified {
		if err := tx.Model(&models.Teacher{}).Where("id = ?", keeper.ID).Update("verified", true).Error; err != nil {
			return stats, governanceErr(CodeTeacherNotFound, "继承审核状态失败", err)
		}
	}

	return stats, nil
}

func softDeleteRating(tx *gorm.DB, ratingID, adminID uint) error {
	now := time.Now()
	return tx.Model(&models.TeacherRating{}).Where("id = ?", ratingID).Updates(map[string]interface{}{
		"deleted_at":        now,
		"moderated_by":      adminID,
		"moderated_at":      now,
		"moderation_reason": "teacher_merge_duplicate",
	}).Error
}

func moveVotes(tx *gorm.DB, fromRatingID, toRatingID uint) (int, error) {
	if fromRatingID == 0 || toRatingID == 0 || fromRatingID == toRatingID {
		return 0, nil
	}
	var votes []models.TeacherRatingVote
	if err := tx.Where("rating_id IN ?", []uint{fromRatingID, toRatingID}).
		Order("updated_at DESC, id DESC").Find(&votes).Error; err != nil {
		return 0, governanceErr(CodeTeacherNotFound, "读取投票记录失败", err)
	}
	moved := 0
	seenVoters := map[uint]bool{}
	for _, v := range votes {
		if seenVoters[v.UserID] {
			if err := tx.Delete(&models.TeacherRatingVote{}, v.ID).Error; err != nil {
				return 0, governanceErr(CodeTeacherNotFound, "清理重复投票失败", err)
			}
		} else {
			seenVoters[v.UserID] = true
			if v.RatingID != toRatingID {
				if err := tx.Model(&models.TeacherRatingVote{}).Where("id = ?", v.ID).
					Update("rating_id", toRatingID).Error; err != nil {
					return 0, governanceErr(CodeTeacherNotFound, "重挂投票失败", err)
				}
				moved++
			}
		}
	}
	return moved, nil
}

func supersedeSubmissionsOfDeletedRating(tx *gorm.DB, deletedRatingID, survivingRatingID, keeperID uint) (int, error) {
	if deletedRatingID == 0 {
		return 0, nil
	}
	var winnerSub models.CourseEvaluationSubmission
	var winnerSubID *uint
	if survivingRatingID != 0 {
		if err := tx.Where("teacher_rating_id = ?", survivingRatingID).First(&winnerSub).Error; err == nil {
			winnerSubID = &winnerSub.ID
		}
	}

	var loserSubs []models.CourseEvaluationSubmission
	if err := tx.Where("teacher_rating_id = ?", deletedRatingID).Find(&loserSubs).Error; err != nil {
		return 0, err
	}
	superseded := 0
	for _, sub := range loserSubs {
		if err := tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", sub.ID).Updates(map[string]interface{}{
			"status":                      models.CourseEvaluationStatusSuperseded,
			"teacher_id":                  keeperID,
			"teacher_rating_id":           nil,
			"superseded_by_submission_id": winnerSubID,
			"superseded_reason":           "teacher_merge_duplicate",
		}).Error; err != nil {
			return 0, err
		}
		superseded++
	}
	return superseded, nil
}

func recomputeRatingVoteCounts(tx *gorm.DB, ratingID uint) error {
	if ratingID == 0 {
		return nil
	}
	var helpful, unhelpful int64
	if err := tx.Model(&models.TeacherRatingVote{}).Where("rating_id = ? AND vote_type = ?", ratingID, "up").Count(&helpful).Error; err != nil {
		return err
	}
	if err := tx.Model(&models.TeacherRatingVote{}).Where("rating_id = ? AND vote_type = ?", ratingID, "down").Count(&unhelpful).Error; err != nil {
		return err
	}
	return tx.Model(&models.TeacherRating{}).Where("id = ?", ratingID).Updates(map[string]interface{}{
		"helpful_count":   int(helpful),
		"unhelpful_count": int(unhelpful),
		"updated_at":      time.Now(),
	}).Error
}

func ensureTeacherAlias(tx *gorm.DB, subjectID uint, alias string, teacherID uint, teacherName string, adminID uint) error {
	if subjectID == 0 || teacherID == 0 {
		return nil
	}
	normalized := models.NormalizeTeacherName(alias)
	if normalized == "" {
		return nil
	}

	// 1. 检查是否与同学科下其他活动教师规范化实名冲突
	var liveTeacher models.Teacher
	err := tx.Where("course_subject_id = ? AND name_normalized = ? AND merged_into_id IS NULL", subjectID, normalized).
		First(&liveTeacher).Error
	if err == nil && liveTeacher.ID != teacherID {
		return governanceErr(CodeCanonicalNameConflict, fmt.Sprintf("别名 %q 与已有真实教师 %q 名称冲突", alias, liveTeacher.Name), nil)
	}

	// 2. 检查既有别名
	var existing models.TeacherAlias
	err = tx.Where("course_subject_id = ? AND normalized_alias = ?", subjectID, normalized).First(&existing).Error
	switch {
	case err == nil:
		if existing.TeacherID == teacherID {
			return nil // 幂等跳过
		}
		var owner models.Teacher
		_ = tx.Select("name").First(&owner, existing.TeacherID).Error
		return governanceErr(CodeAliasTargetConflict, fmt.Sprintf("别名 %q 已存在并指向教师 %q(#%d)", alias, owner.Name, existing.TeacherID), nil)
	case errors.Is(err, gorm.ErrRecordNotFound):
		creator := adminID
		return tx.Create(&models.TeacherAlias{
			TeacherID:       teacherID,
			CourseSubjectID: subjectID,
			Alias:           strings.TrimSpace(alias),
			NormalizedAlias: normalized,
			Source:          "merge",
			CreatedBy:       &creator,
		}).Error
	default:
		return governanceErr(CodeTeacherNotFound, "查询教师别名失败", err)
	}
}

func mergeCourseSubjectEntity(tx *gorm.DB, adminID uint, batchID string, cmp courseMergePlan, adminName string) error {
	// 1. 再次确认 loser 学科无本次操作之外的活动教师
	var activeTeacherCount int64
	if err := tx.Model(&models.Teacher{}).
		Where("course_subject_id = ? AND merged_into_id IS NULL", cmp.LoserSubjectID).
		Count(&activeTeacherCount).Error; err != nil {
		return err
	}
	if activeTeacherCount > 0 {
		return governanceErr(CodeSubjectNotEmpty, fmt.Sprintf("原课程仍有 %d 位活动教师，不能合并课程实体", activeTeacherCount), nil)
	}

	// 2. 将 merged Teacher 的 course_subject_id 更新为 keeper 学科
	if err := tx.Model(&models.Teacher{}).Where("course_subject_id = ?", cmp.LoserSubjectID).
		Update("course_subject_id", cmp.KeeperSubjectID).Error; err != nil {
		return governanceErr(CodeTeacherNotFound, "更新教师所属课程失败", err)
	}

	// 3. 提交记录更新
	if err := tx.Model(&models.CourseEvaluationSubmission{}).Where("course_subject_id = ?", cmp.LoserSubjectID).
		Updates(map[string]interface{}{
			"course_subject_id":   cmp.KeeperSubjectID,
			"course_subject_name": cmp.KeeperSubjectName,
		}).Error; err != nil {
		return governanceErr(CodeTeacherNotFound, "更新提交所属课程失败", err)
	}

	// 4. 重挂原课程别名（逐条处理，防止唯一索引冲突）
	if err := reconcileCourseSubjectAliases(tx, cmp.LoserSubjectID, cmp.KeeperSubjectID); err != nil {
		return err
	}

	// 5. 将 loser 课程名登记为 keeper 课程别名（排除 loser 课程自身，防止名称自冲突）
	if err := ensureCourseSubjectAliasExcluding(tx, cmp.LoserSubjectName, cmp.KeeperSubjectID, []uint{cmp.LoserSubjectID}); err != nil {
		return err
	}

	// 6. 标记 loser 课程实体为已合并（软合并），压平历史合并链条
	if err := tx.Model(&models.CourseSubject{}).Where("merged_into_id = ?", cmp.LoserSubjectID).Update("merged_into_id", cmp.KeeperSubjectID).Error; err != nil {
		return governanceErr(CodeTeacherNotFound, "压平历史课程合并链条失败", err)
	}
	if err := tx.Model(&models.CourseSubject{}).Where("id = ?", cmp.LoserSubjectID).Update("merged_into_id", cmp.KeeperSubjectID).Error; err != nil {
		return governanceErr(CodeTeacherNotFound, "标记已合并课程实体失败", err)
	}

	return nil
}

func reconcileTeacherAliases(tx *gorm.DB, loserID, keeperID, keeperSubjectID uint) error {
	var loserAliases []models.TeacherAlias
	if err := tx.Where("teacher_id = ?", loserID).Find(&loserAliases).Error; err != nil {
		return governanceErr(CodeTeacherNotFound, "读取被合并教师别名失败", err)
	}

	for _, alias := range loserAliases {
		var existing models.TeacherAlias
		err := tx.Where("course_subject_id = ? AND normalized_alias = ?", keeperSubjectID, alias.NormalizedAlias).
			First(&existing).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			if err := tx.Model(&models.TeacherAlias{}).Where("id = ?", alias.ID).Updates(map[string]interface{}{
				"teacher_id":        keeperID,
				"course_subject_id": keeperSubjectID,
			}).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "重挂别名失败", err)
			}
		} else if err != nil {
			return err
		} else {
			if existing.ID == alias.ID {
				// 命中自身：更新指向 keeperID 与 keeperSubjectID
				if err := tx.Model(&models.TeacherAlias{}).Where("id = ?", alias.ID).Updates(map[string]interface{}{
					"teacher_id":        keeperID,
					"course_subject_id": keeperSubjectID,
				}).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "重挂教师别名失败", err)
				}
			} else if existing.TeacherID == keeperID {
				if err := tx.Delete(&models.TeacherAlias{}, alias.ID).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "删除重复别名失败", err)
				}
			} else {
				var owner models.Teacher
				if err := tx.First(&owner, existing.TeacherID).Error; err == nil && owner.MergedIntoID == nil {
					return governanceErr(CodeAliasTargetConflict, fmt.Sprintf("别名 %q 已指向其他活动教师 %q(#%d)，无法合并", alias.Alias, owner.Name, owner.ID), nil)
				}
				if err := tx.Delete(&models.TeacherAlias{}, alias.ID).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "清理无效别名失败", err)
				}
				if err := tx.Model(&models.TeacherAlias{}).Where("id = ?", existing.ID).Updates(map[string]interface{}{
					"teacher_id": keeperID,
				}).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "更新别名目标失败", err)
				}
			}
		}
	}

	var lingeringTeacherAliases int64
	if err := tx.Model(&models.TeacherAlias{}).Where("teacher_id = ?", loserID).Count(&lingeringTeacherAliases).Error; err != nil {
		return err
	}
	if lingeringTeacherAliases > 0 {
		return governanceErr(CodeTeacherNotFound, fmt.Sprintf("教师别名未完全重挂，仍有 %d 条指向被合并教师", lingeringTeacherAliases), nil)
	}
	return nil
}

func reconcileCourseSubjectAliases(tx *gorm.DB, loserSubjectID, keeperSubjectID uint) error {
	var loserAliases []models.CourseSubjectAlias
	if err := tx.Where("course_subject_id = ?", loserSubjectID).Find(&loserAliases).Error; err != nil {
		return governanceErr(CodeTeacherNotFound, "读取被归并课程别名失败", err)
	}

	for _, alias := range loserAliases {
		var existing models.CourseSubjectAlias
		err := tx.Where("normalized_alias = ?", alias.NormalizedAlias).First(&existing).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			if err := tx.Model(&models.CourseSubjectAlias{}).Where("id = ?", alias.ID).
				Update("course_subject_id", keeperSubjectID).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "重挂课程别名失败", err)
			}
		} else if err != nil {
			return err
		} else {
			if existing.ID == alias.ID {
				// 命中自身：更新指向 keeperSubjectID
				if err := tx.Model(&models.CourseSubjectAlias{}).Where("id = ?", alias.ID).
					Update("course_subject_id", keeperSubjectID).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "重挂课程别名目标失败", err)
				}
			} else if existing.CourseSubjectID == keeperSubjectID {
				if err := tx.Delete(&models.CourseSubjectAlias{}, alias.ID).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "删除重复课程别名失败", err)
				}
			} else {
				var targetSub models.CourseSubject
				_ = tx.First(&targetSub, existing.CourseSubjectID).Error
				return governanceErr(CodeAliasTargetConflict, fmt.Sprintf("课程别名 %q 已指向其他课程 %q(#%d)，无法归并", alias.Alias, targetSub.Name, targetSub.ID), nil)
			}
		}
	}

	var lingeringCourseAliases int64
	if err := tx.Model(&models.CourseSubjectAlias{}).Where("course_subject_id = ?", loserSubjectID).Count(&lingeringCourseAliases).Error; err != nil {
		return err
	}
	if lingeringCourseAliases > 0 {
		return governanceErr(CodeTeacherNotFound, fmt.Sprintf("课程别名未完全重挂，仍有 %d 条指向被归并课程", lingeringCourseAliases), nil)
	}
	return nil
}

func ensureCourseSubjectAlias(tx *gorm.DB, alias string, subjectID uint) error {
	return ensureCourseSubjectAliasExcluding(tx, alias, subjectID, nil)
}

func ensureCourseSubjectAliasExcluding(tx *gorm.DB, alias string, subjectID uint, excludeSubjectIDs []uint) error {
	normalized := models.NormalizeCourseSubjectName(alias)
	if normalized == "" || subjectID == 0 {
		return nil
	}

	// 1. 检查是否与已有其他标准学科的规范化名称冲突
	var canonical models.CourseSubject
	if err := tx.Where("normalized_name = ? AND merged_into_id IS NULL", normalized).First(&canonical).Error; err == nil {
		isExcluded := canonical.ID == subjectID
		if !isExcluded {
			for _, id := range excludeSubjectIDs {
				if canonical.ID == id {
					isExcluded = true
					break
				}
			}
		}
		if !isExcluded {
			return governanceErr(CodeCanonicalNameConflict, fmt.Sprintf("课程别名 %q 与已有学科 %q 规范化名称冲突", alias, canonical.Name), nil)
		}
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}

	// 2. 检查既有别名表
	var existing models.CourseSubjectAlias
	err := tx.Where("normalized_alias = ?", normalized).First(&existing).Error
	switch {
	case err == nil:
		if existing.CourseSubjectID == subjectID {
			return nil
		}
		isExcluded := false
		for _, id := range excludeSubjectIDs {
			if existing.CourseSubjectID == id {
				isExcluded = true
				break
			}
		}
		if isExcluded {
			return tx.Model(&models.CourseSubjectAlias{}).Where("id = ?", existing.ID).Update("course_subject_id", subjectID).Error
		}
		return governanceErr(CodeAliasTargetConflict, fmt.Sprintf("课程别名 %q 已指向其他学科", alias), nil)
	case errors.Is(err, gorm.ErrRecordNotFound):
		return tx.Create(&models.CourseSubjectAlias{
			CourseSubjectID: subjectID,
			Alias:           strings.TrimSpace(alias),
			NormalizedAlias: normalized,
		}).Error
	default:
		return err
	}
}

// PreviewCourseMerge 独立课程合并预览
func (s *TeacherGovernanceService) PreviewCourseMerge(input CourseMergeInput) (*CourseMergePreviewResult, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	return s.buildCourseMergePlan(s.db, input)
}

func (s *TeacherGovernanceService) buildCourseMergePlan(db *gorm.DB, input CourseMergeInput) (*CourseMergePreviewResult, error) {
	if input.KeeperSubjectID == 0 || len(input.LoserSubjectIDs) == 0 {
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "必须指定保留课程与至少一门被合并课程", nil)
	}

	uniqueLoserIDs := make([]uint, 0, len(input.LoserSubjectIDs))
	seenLoserIDs := map[uint]bool{}
	for _, id := range input.LoserSubjectIDs {
		if id == 0 {
			continue
		}
		if id == input.KeeperSubjectID || seenLoserIDs[id] {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "被合并课程包含目标课程自身或重复项", nil)
		}
		seenLoserIDs[id] = true
		uniqueLoserIDs = append(uniqueLoserIDs, id)
	}
	if len(uniqueLoserIDs) == 0 {
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "必须指定至少一门被合并课程", nil)
	}

	var keeperSubject models.CourseSubject
	if err := db.Where("id = ?", input.KeeperSubjectID).First(&keeperSubject).Error; err != nil {
		return nil, governanceErr(CodeTeacherNotFound, "目标课程不存在", err)
	}
	if keeperSubject.MergedIntoID != nil {
		return nil, governanceErr(CodeTeacherAlreadyMerged, "目标课程已被合并，不能作为合并目标", nil)
	}

	var loserSubjects []models.CourseSubject
	if err := db.Where("id IN ?", uniqueLoserIDs).Find(&loserSubjects).Error; err != nil {
		return nil, governanceErr(CodeTeacherNotFound, "读取被合并课程失败", err)
	}
	if len(loserSubjects) != len(uniqueLoserIDs) {
		return nil, governanceErr(CodeTeacherNotFound, "部分被合并课程不存在", nil)
	}
	for _, ls := range loserSubjects {
		if ls.MergedIntoID != nil {
			return nil, governanceErr(CodeTeacherAlreadyMerged, fmt.Sprintf("课程 %q 已被合并，不能重复合并", ls.Name), nil)
		}
	}

	finalCourseName := strings.TrimSpace(input.FinalCourseName)
	if finalCourseName == "" {
		finalCourseName = keeperSubject.Name
	}

	result := &CourseMergePreviewResult{
		MergeAllowed:          true,
		FinalCourseName:       finalCourseName,
		Conflicts:             []string{},
		LoserSubjects:         make([]CourseSubjectSummary, 0, len(loserSubjects)),
		MigratingTeachers:     []MigratingTeacherSummary{},
		PairedTeacherMerges:   []PairedTeacherMergeSummary{},
		CourseAliasesToCreate: []string{},
	}

	// 最终课程名冲突校验
	normFinal := models.NormalizeCourseSubjectName(finalCourseName)
	if normFinal == "" {
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "最终课程名称不能为空", nil)
	}
	var conflictSubj models.CourseSubject
	if err := db.Where("normalized_name = ? AND merged_into_id IS NULL", normFinal).First(&conflictSubj).Error; err == nil {
		isExcluded := conflictSubj.ID == keeperSubject.ID || seenLoserIDs[conflictSubj.ID]
		if !isExcluded {
			cMsg := fmt.Sprintf("最终课程名称 %q 与已有课程 %q(#%d) 冲突", finalCourseName, conflictSubj.Name, conflictSubj.ID)
			result.Conflicts = append(result.Conflicts, cMsg)
			result.MergeAllowed = false
			result.BlockReason = cMsg
		}
	}

	// 统计 keeper 课程数据
	var keeperTeachers []models.Teacher
	db.Where("course_subject_id = ? AND merged_into_id IS NULL", keeperSubject.ID).Find(&keeperTeachers)
	keeperTeacherMap := map[uint]models.Teacher{}
	keeperTeacherIDs := make([]uint, 0, len(keeperTeachers))
	for _, t := range keeperTeachers {
		keeperTeacherMap[t.ID] = t
		keeperTeacherIDs = append(keeperTeacherIDs, t.ID)
	}
	var keeperRatingCount int64
	var keeperAvgStar float64
	if len(keeperTeacherIDs) > 0 {
		type statRow struct {
			TotalRatings int64
			AvgStar      float64
		}
		var stat statRow
		db.Table("teacher_ratings").
			Select("COUNT(id) as total_ratings, COALESCE(AVG(star), 0) as avg_star").
			Where("teacher_id IN ? AND deleted_at IS NULL", keeperTeacherIDs).
			Scan(&stat)
		keeperRatingCount = stat.TotalRatings
		keeperAvgStar = stat.AvgStar
	}
	result.KeeperSubject = CourseSubjectSummary{
		ID:           keeperSubject.ID,
		Name:         keeperSubject.Name,
		Verified:     keeperSubject.Verified,
		TeacherCount: len(keeperTeachers),
		RatingCount:  int(keeperRatingCount),
		AverageStar:  math.Round(keeperAvgStar*10) / 10,
	}

	// 别名与被合并课程统计
	for _, ls := range loserSubjects {
		var lsTeachers []models.Teacher
		db.Where("course_subject_id = ? AND merged_into_id IS NULL", ls.ID).Find(&lsTeachers)
		lsTeacherIDs := make([]uint, 0, len(lsTeachers))
		for _, t := range lsTeachers {
			lsTeacherIDs = append(lsTeacherIDs, t.ID)
		}
		var lsRatings int64
		var lsAvgStar float64
		if len(lsTeacherIDs) > 0 {
			type statRow struct {
				TotalRatings int64
				AvgStar      float64
			}
			var stat statRow
			db.Table("teacher_ratings").
				Select("COUNT(id) as total_ratings, COALESCE(AVG(star), 0) as avg_star").
				Where("teacher_id IN ? AND deleted_at IS NULL", lsTeacherIDs).
				Scan(&stat)
			lsRatings = stat.TotalRatings
			lsAvgStar = stat.AvgStar
		}
		result.LoserSubjects = append(result.LoserSubjects, CourseSubjectSummary{
			ID:           ls.ID,
			Name:         ls.Name,
			Verified:     ls.Verified,
			TeacherCount: len(lsTeachers),
			RatingCount:  int(lsRatings),
			AverageStar:  math.Round(lsAvgStar*10) / 10,
		})

		aliasPlan, conflictMsg, err := planCourseAliasExcluding(db, ls.Name, keeperSubject.ID, keeperSubject.Name, uniqueLoserIDs)
		if err != nil {
			return nil, err
		}
		if conflictMsg != "" {
			result.Conflicts = append(result.Conflicts, conflictMsg)
			result.MergeAllowed = false
			result.BlockReason = conflictMsg
		}
		if aliasPlan.Status == "to_create" || aliasPlan.Status == "to_repoint" {
			result.CourseAliasesToCreate = append(result.CourseAliasesToCreate, ls.Name)
		}
	}

	if finalCourseName != keeperSubject.Name {
		kAliasPlan, kConflictMsg, err := planCourseAliasExcluding(db, keeperSubject.Name, keeperSubject.ID, finalCourseName, uniqueLoserIDs)
		if err != nil {
			return nil, err
		}
		if kConflictMsg != "" {
			result.Conflicts = append(result.Conflicts, kConflictMsg)
			result.MergeAllowed = false
			result.BlockReason = kConflictMsg
		}
		if kAliasPlan.Status == "to_create" || kAliasPlan.Status == "to_repoint" {
			result.CourseAliasesToCreate = append(result.CourseAliasesToCreate, keeperSubject.Name)
		}
	}

	var allLoserTeachers []models.Teacher
	db.Where("course_subject_id IN ? AND merged_into_id IS NULL", uniqueLoserIDs).Find(&allLoserTeachers)
	loserTeacherMap := map[uint]models.Teacher{}
	for _, t := range allLoserTeachers {
		loserTeacherMap[t.ID] = t
	}

	pairedLoserIDs := map[uint]bool{}
	pairedKeeperIDs := map[uint]bool{}

	for _, pair := range input.TeacherPairs {
		loserT, lOk := loserTeacherMap[pair.LoserTeacherID]
		if !lOk {
			return nil, governanceErr(CodeTeacherNotFound, fmt.Sprintf("配对教师 #%d 不是被合并课程下的活动教师", pair.LoserTeacherID), nil)
		}
		keeperT, kOk := keeperTeacherMap[pair.KeeperTeacherID]
		if !kOk {
			return nil, governanceErr(CodeTeacherNotFound, fmt.Sprintf("配对目标教师 #%d 不是保留课程下的活动教师", pair.KeeperTeacherID), nil)
		}
		if pairedLoserIDs[pair.LoserTeacherID] {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, fmt.Sprintf("教师 #%d 在配对中重复出现", pair.LoserTeacherID), nil)
		}
		if pairedKeeperIDs[pair.KeeperTeacherID] {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, fmt.Sprintf("目标教师 #%d 在配对中被多次指定", pair.KeeperTeacherID), nil)
		}
		pairedLoserIDs[pair.LoserTeacherID] = true
		pairedKeeperIDs[pair.KeeperTeacherID] = true

		finalTName := strings.TrimSpace(pair.FinalTeacherName)
		if finalTName == "" {
			finalTName = keeperT.Name
		}

		var lRatings []models.TeacherRating
		db.Where("teacher_id = ? AND deleted_at IS NULL", loserT.ID).Find(&lRatings)
		var kRatings []models.TeacherRating
		db.Where("teacher_id = ? AND deleted_at IS NULL", keeperT.ID).Find(&kRatings)
		kUserMap := map[uint]models.TeacherRating{}
		for _, kr := range kRatings {
			kUserMap[kr.UserID] = kr
		}

		migratedRatings := 0
		softDeletedRatings := 0
		for _, lr := range lRatings {
			if kr, exists := kUserMap[lr.UserID]; exists {
				softDeletedRatings++
				if lr.CreatedAt.After(kr.CreatedAt) || (lr.CreatedAt.Equal(kr.CreatedAt) && lr.ID > kr.ID) {
					migratedRatings++
				}
			} else {
				migratedRatings++
			}
		}

		var movedVotes int64
		db.Model(&models.TeacherRatingVote{}).
			Joins("JOIN teacher_ratings ON teacher_ratings.id = teacher_rating_votes.rating_id").
			Where("teacher_ratings.teacher_id = ? AND teacher_ratings.deleted_at IS NULL", loserT.ID).
			Count(&movedVotes)

		result.PairedTeacherMerges = append(result.PairedTeacherMerges, PairedTeacherMergeSummary{
			LoserTeacherID:     loserT.ID,
			LoserTeacherName:   loserT.Name,
			KeeperTeacherID:    keeperT.ID,
			KeeperTeacherName:  keeperT.Name,
			FinalTeacherName:   finalTName,
			MigratedRatings:    migratedRatings,
			SoftDeletedRatings: softDeletedRatings,
			MigratedVotes:      int(movedVotes),
		})

		result.TotalRatingsMigrating += migratedRatings
		result.TotalRatingsDeduped += softDeletedRatings
		result.TotalVotesMigrating += int(movedVotes)
	}

	keeperNormNames := map[string]models.Teacher{}
	for _, kt := range keeperTeachers {
		if !pairedKeeperIDs[kt.ID] {
			keeperNormNames[models.NormalizeTeacherName(kt.Name)] = kt
		}
	}

	for _, lt := range allLoserTeachers {
		if pairedLoserIDs[lt.ID] {
			continue
		}
		lNorm := models.NormalizeTeacherName(lt.Name)
		if existKt, exists := keeperNormNames[lNorm]; exists {
			cMsg := fmt.Sprintf("原课程教师 %q(#%d) 与目标课程教师 %q(#%d) 同名。请在配对中确认为同一教师，或在合并前调整名称。", lt.Name, lt.ID, existKt.Name, existKt.ID)
			result.Conflicts = append(result.Conflicts, cMsg)
			result.MergeAllowed = false
			result.BlockReason = cMsg
		}

		fromSubjName := ""
		for _, ls := range loserSubjects {
			if lt.CourseSubjectID != nil && *lt.CourseSubjectID == ls.ID {
				fromSubjName = ls.Name
				break
			}
		}

		var ratingCount int64
		db.Model(&models.TeacherRating{}).Where("teacher_id = ? AND deleted_at IS NULL", lt.ID).Count(&ratingCount)

		result.MigratingTeachers = append(result.MigratingTeachers, MigratingTeacherSummary{
			TeacherID:   lt.ID,
			TeacherName: lt.Name,
			FromSubject: fromSubjName,
			ToSubject:   finalCourseName,
			RatingCount: int(ratingCount),
		})
		result.TotalRatingsMigrating += int(ratingCount)
	}

	var submissionsRelinked int64
	db.Model(&models.CourseEvaluationSubmission{}).Where("course_subject_id IN ?", uniqueLoserIDs).Count(&submissionsRelinked)
	result.TotalSubmissionsRelinked = int(submissionsRelinked)

	result.SnapshotToken = computeCourseMergeSnapshotToken(db, keeperSubject.ID, uniqueLoserIDs, finalCourseName, input.TeacherPairs)
	return result, nil
}

// CourseMerge 执行独立课程合并
func (s *TeacherGovernanceService) CourseMerge(adminID uint, input CourseMergeInput) (*CourseMergePreviewResult, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if adminID == 0 {
		return nil, governanceErr(CodeTeacherGovernanceForbidden, "无权执行课程合并", nil)
	}

	// 幂等重试检查：若请求的所有 loser 课程已全部并入当前 keeper，直接返回成功
	if len(input.LoserSubjectIDs) > 0 {
		var loserSubjects []models.CourseSubject
		if err := s.db.Where("id IN ?", input.LoserSubjectIDs).Find(&loserSubjects).Error; err == nil && len(loserSubjects) == len(input.LoserSubjectIDs) {
			allMergedIntoKeeper := true
			for _, ls := range loserSubjects {
				if ls.MergedIntoID == nil || *ls.MergedIntoID != input.KeeperSubjectID {
					allMergedIntoKeeper = false
					break
				}
			}
			if allMergedIntoKeeper {
				return &CourseMergePreviewResult{
					MergeAllowed:    true,
					FinalCourseName: input.FinalCourseName,
					KeeperSubject: CourseSubjectSummary{
						ID: input.KeeperSubjectID,
					},
				}, nil
			}
		}
	}

	if strings.TrimSpace(input.SnapshotToken) == "" {
		return nil, governanceErr(CodeGovernanceSnapshotRequired, "请先重新预览合并影响", nil)
	}

	plan, err := s.buildCourseMergePlan(s.db, input)
	if err != nil {
		return nil, err
	}
	if !plan.MergeAllowed || len(plan.Conflicts) > 0 {
		return nil, governanceErrWithDetails(CodeMergeRatingConflict, "存在阻断性冲突，无法执行合并: "+plan.BlockReason, map[string]interface{}{
			"conflicts": plan.Conflicts,
		})
	}

	adminName := ""
	var admin models.User
	if err := s.db.Select("nickname").First(&admin, adminID).Error; err == nil {
		adminName = admin.Nickname
	}

	batchID := fmt.Sprintf("course-merge-%d", time.Now().UnixNano())

	allSubjectIDs := append([]uint{input.KeeperSubjectID}, input.LoserSubjectIDs...)
	sort.Slice(allSubjectIDs, func(i, j int) bool { return allSubjectIDs[i] < allSubjectIDs[j] })

	err = s.db.Transaction(func(tx *gorm.DB) error {
		// 1. 严格按 ID 顺序锁定涉及的课程实体
		lockedSubjects := make(map[uint]models.CourseSubject, len(allSubjectIDs))
		for _, id := range allSubjectIDs {
			var locked models.CourseSubject
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&locked, id).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, fmt.Sprintf("锁定课程 #%d 失败", id), err)
			}
			lockedSubjects[id] = locked
		}

		// 1b. 幂等检查
		allIdempotent := true
		for _, id := range input.LoserSubjectIDs {
			ls, ok := lockedSubjects[id]
			if !ok || ls.MergedIntoID == nil || *ls.MergedIntoID != input.KeeperSubjectID {
				allIdempotent = false
				break
			}
		}
		if allIdempotent {
			return nil
		}

		// 2. 锁定涉及的全部教师（在校验快照前先持锁，避免并发修改竞态）
		var allTeacherIDs []uint
		for _, p := range plan.PairedTeacherMerges {
			allTeacherIDs = append(allTeacherIDs, p.KeeperTeacherID, p.LoserTeacherID)
		}
		for _, mt := range plan.MigratingTeachers {
			allTeacherIDs = append(allTeacherIDs, mt.TeacherID)
		}
		sort.Slice(allTeacherIDs, func(i, j int) bool { return allTeacherIDs[i] < allTeacherIDs[j] })
		lockedTeachersMap := make(map[uint]models.Teacher, len(allTeacherIDs))
		for _, tid := range allTeacherIDs {
			var lt models.Teacher
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&lt, tid).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, fmt.Sprintf("锁定教师 #%d 失败", tid), err)
			}
			lockedTeachersMap[tid] = lt
		}

		// 3. SnapshotToken 校验（持锁后核验，确保执行的是管理员确认的数据状态）
		currentToken := computeCourseMergeSnapshotToken(tx, input.KeeperSubjectID, input.LoserSubjectIDs, plan.FinalCourseName, input.TeacherPairs)
		if input.SnapshotToken != currentToken {
			return governanceErr(CodeGovernanceSnapshotStale, "数据状态已发生变更，请刷新预览后重试", nil)
		}

		keeperSubject := lockedSubjects[input.KeeperSubjectID]
		finalCourseName := plan.FinalCourseName

		// 4. 先标记并压平 loser 课程合并状态，释放唯一名称占用
		for _, lsID := range input.LoserSubjectIDs {
			if err := tx.Model(&models.CourseSubject{}).Where("merged_into_id = ?", lsID).
				Update("merged_into_id", keeperSubject.ID).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "压平历史课程合并链条失败", err)
			}
			if err := tx.Model(&models.CourseSubject{}).Where("id = ?", lsID).
				Update("merged_into_id", keeperSubject.ID).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "标记课程合并状态失败", err)
			}
		}

		// 5. 更新目标课程名称（在 loser 归档释放名称占用后执行）
		if finalCourseName != keeperSubject.Name {
			if models.NormalizeCourseSubjectName(keeperSubject.Name) != models.NormalizeCourseSubjectName(finalCourseName) {
				if err := ensureCourseSubjectAliasExcluding(tx, keeperSubject.Name, keeperSubject.ID, input.LoserSubjectIDs); err != nil {
					return err
				}
			}
			if err := tx.Model(&models.CourseSubject{}).Where("id = ?", keeperSubject.ID).Updates(map[string]interface{}{
				"name":            finalCourseName,
				"normalized_name": models.NormalizeCourseSubjectName(finalCourseName),
			}).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "更新目标课程名称失败", err)
			}
		}

		// 6. 重挂原课程别名并登记原课程名为 keeper 别名
		for _, lsID := range input.LoserSubjectIDs {
			ls := lockedSubjects[lsID]
			if err := reconcileCourseSubjectAliases(tx, ls.ID, keeperSubject.ID); err != nil {
				return err
			}
			if err := ensureCourseSubjectAliasExcluding(tx, ls.Name, keeperSubject.ID, input.LoserSubjectIDs); err != nil {
				return err
			}
		}

		// 7. 执行配对教师合并
		for _, p := range plan.PairedTeacherMerges {
			stats, err := mergeSingleTeacher(tx, adminID, p.KeeperTeacherID, p.LoserTeacherID)
			if err != nil {
				return err
			}
			finalTName := strings.TrimSpace(p.FinalTeacherName)
			var curKeeperT models.Teacher
			if err := tx.Select("name").First(&curKeeperT, p.KeeperTeacherID).Error; err == nil && finalTName != "" && finalTName != curKeeperT.Name {
				if models.NormalizeTeacherName(curKeeperT.Name) != models.NormalizeTeacherName(finalTName) {
					if err := ensureTeacherAlias(tx, keeperSubject.ID, curKeeperT.Name, p.KeeperTeacherID, finalTName, adminID); err != nil {
						return err
					}
				}
				if err := tx.Model(&models.Teacher{}).Where("id = ?", p.KeeperTeacherID).Updates(map[string]interface{}{
					"name":            finalTName,
					"name_normalized": models.NormalizeTeacherName(finalTName),
				}).Error; err != nil {
					return governanceErr(CodeTeacherNotFound, "更新教师规范名称失败", err)
				}
			}

			tAliasAdded := 0
			if models.NormalizeTeacherName(p.LoserTeacherName) != models.NormalizeTeacherName(finalTName) {
				if err := ensureTeacherAlias(tx, keeperSubject.ID, p.LoserTeacherName, p.KeeperTeacherID, finalTName, adminID); err != nil {
					return err
				}
				tAliasAdded = 1
			}

			loserSubjName := ""
			if lt, ok := lockedTeachersMap[p.LoserTeacherID]; ok && lt.CourseSubjectID != nil {
				if ls, okSub := lockedSubjects[*lt.CourseSubjectID]; okSub {
					loserSubjName = ls.Name
				}
			}
			if loserSubjName == "" {
				loserSubjName = p.LoserTeacherName
			}

			record := models.TeacherMergeRecord{
				BatchID:                   batchID,
				KeeperID:                  p.KeeperTeacherID,
				LoserID:                   p.LoserTeacherID,
				KeeperNameSnapshot:        finalTName,
				LoserNameSnapshot:         p.LoserTeacherName,
				KeeperSubjectNameSnapshot: finalCourseName,
				LoserSubjectNameSnapshot:  loserSubjName,
				MigratedRatings:           stats.MigratedRatings,
				SoftDeletedRatings:        stats.SoftDeletedRatings,
				MigratedVotes:             stats.MovedVotes,
				MigratedSubmissions:       stats.RelinkedSubmissions,
				SupersededSubmissions:     stats.SupersededSubmissions,
				TeacherAliasesAdded:       tAliasAdded,
				AdminID:                   adminID,
				AdminName:                 adminName,
				Action:                    "course_teacher_merge",
				Reason:                    input.Reason,
				CreatedAt:                 time.Now(),
			}
			if err := tx.Create(&record).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "写入教师合并记录失败", err)
			}
		}

		// 8. 迁移未配对教师：更新 course_subject_id 和 course
		for _, mt := range plan.MigratingTeachers {
			if err := tx.Model(&models.Teacher{}).Where("id = ?", mt.TeacherID).Updates(map[string]interface{}{
				"course_subject_id": keeperSubject.ID,
				"course":            finalCourseName,
			}).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, fmt.Sprintf("迁移教师 #%d 失败", mt.TeacherID), err)
			}
			if err := tx.Model(&models.TeacherAlias{}).Where("teacher_id = ?", mt.TeacherID).
				Update("course_subject_id", keeperSubject.ID).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, fmt.Sprintf("迁移教师别名 #%d 失败", mt.TeacherID), err)
			}
		}

		// 9. 统一原有教师的 course 规范名称
		if err := tx.Model(&models.Teacher{}).Where("course_subject_id = ? AND merged_into_id IS NULL", keeperSubject.ID).
			Update("course", finalCourseName).Error; err != nil {
			return governanceErr(CodeTeacherNotFound, "更新教师课程名失败", err)
		}

		// 10. 重挂提交记录并同步规范 DedupKey 与冲突处理
		var loserSubs []models.CourseEvaluationSubmission
		if err := tx.Where("course_subject_id IN ? AND status <> ?", input.LoserSubjectIDs, models.CourseEvaluationStatusSuperseded).
			Order("id ASC").Find(&loserSubs).Error; err == nil {
			for _, sub := range loserSubs {
				tName := sub.TeacherName
				newDedupKey := models.CourseEvaluationDedupKey(sub.UserID, finalCourseName, tName)
				var existingSub models.CourseEvaluationSubmission
				err := tx.Where("user_id = ? AND dedup_key = ? AND id <> ? AND status <> ?", sub.UserID, newDedupKey, sub.ID, models.CourseEvaluationStatusSuperseded).
					First(&existingSub).Error
				if err == nil {
					_ = tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", sub.ID).Updates(map[string]interface{}{
						"status":              models.CourseEvaluationStatusSuperseded,
						"moderation_reason":   "course_merge_submission_superseded",
						"course_subject_id":   keeperSubject.ID,
						"course_subject_name": finalCourseName,
					}).Error
				} else if errors.Is(err, gorm.ErrRecordNotFound) {
					_ = tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", sub.ID).Updates(map[string]interface{}{
						"course_subject_id":   keeperSubject.ID,
						"course_subject_name": finalCourseName,
						"dedup_key":           newDedupKey,
					}).Error
				}
			}
		}

		// 同步 keeper 身上已有提交的课程规范名与去重键
		var keeperSubs []models.CourseEvaluationSubmission
		if err := tx.Where("course_subject_id = ? AND status <> ?", keeperSubject.ID, models.CourseEvaluationStatusSuperseded).
			Order("id ASC").Find(&keeperSubs).Error; err == nil {
			for _, ksub := range keeperSubs {
				newDK := models.CourseEvaluationDedupKey(ksub.UserID, finalCourseName, ksub.TeacherName)
				_ = tx.Model(&models.CourseEvaluationSubmission{}).Where("id = ?", ksub.ID).Updates(map[string]interface{}{
					"course_subject_name": finalCourseName,
					"dedup_key":           newDK,
				}).Error
			}
		}

		// 11. 记录课程合并记录
		for _, lsID := range input.LoserSubjectIDs {
			ls := lockedSubjects[lsID]
			cRecord := models.TeacherMergeRecord{
				BatchID:                   batchID,
				KeeperID:                  keeperSubject.ID,
				LoserID:                   ls.ID,
				KeeperNameSnapshot:        finalCourseName,
				LoserNameSnapshot:         ls.Name,
				KeeperSubjectNameSnapshot: finalCourseName,
				LoserSubjectNameSnapshot:  ls.Name,
				CourseAliasesAdded:        1,
				AdminID:                   adminID,
				AdminName:                 adminName,
				Action:                    "course_merge",
				Reason:                    input.Reason,
				CreatedAt:                 time.Now(),
			}
			if err := tx.Create(&cRecord).Error; err != nil {
				return governanceErr(CodeTeacherNotFound, "写入课程合并记录失败", err)
			}
		}

		logDetail := fmt.Sprintf("批次 %s：合并 %d 门课程为「%s」，迁移教师 %d 位，配对合并教师 %d 对",
			batchID, len(input.LoserSubjectIDs), finalCourseName, len(plan.MigratingTeachers), len(plan.PairedTeacherMerges))
		if strings.TrimSpace(input.Reason) != "" {
			logDetail += fmt.Sprintf("，原因：%s", strings.TrimSpace(input.Reason))
		}
		return writeCourseEvaluationAdminLog(tx, adminID, "合并课程", finalCourseName, logDetail)
	})

	if err != nil {
		return nil, err
	}
	return plan, nil
}

// SearchGovernanceCourses 搜索课程（附带授课教师数与评分统计）
func (s *TeacherGovernanceService) SearchGovernanceCourses(q string, limit int) ([]GovernanceCourseItem, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	query := models.ScopeActiveSubjects(s.db).Order("verified DESC, id ASC").Limit(limit)
	if q := strings.TrimSpace(q); q != "" {
		like := "%" + escapeLike(q) + "%"
		query = query.Where("name LIKE ?", like)
	}
	var subjects []models.CourseSubject
	if err := query.Find(&subjects).Error; err != nil {
		return nil, governanceErr(CodeTeacherNotFound, "读取课程失败", err)
	}
	if len(subjects) == 0 {
		return []GovernanceCourseItem{}, nil
	}

	subjectIDs := make([]uint, len(subjects))
	for i, subj := range subjects {
		subjectIDs[i] = subj.ID
	}

	type tCountRow struct {
		CourseSubjectID uint
		Count           int
	}
	var tCounts []tCountRow
	s.db.Table("teachers").
		Select("course_subject_id, COUNT(id) as count").
		Where("course_subject_id IN ? AND merged_into_id IS NULL", subjectIDs).
		Group("course_subject_id").
		Scan(&tCounts)
	teacherCountMap := map[uint]int{}
	for _, tc := range tCounts {
		teacherCountMap[tc.CourseSubjectID] = tc.Count
	}

	type rStatRow struct {
		CourseSubjectID uint
		RatingCount     int
		AvgStar         float64
	}
	var rStats []rStatRow
	s.db.Table("teachers").
		Select("teachers.course_subject_id, COUNT(teacher_ratings.id) as rating_count, COALESCE(AVG(teacher_ratings.star), 0) as avg_star").
		Joins("JOIN teacher_ratings ON teacher_ratings.teacher_id = teachers.id AND teacher_ratings.deleted_at IS NULL").
		Where("teachers.course_subject_id IN ? AND teachers.merged_into_id IS NULL", subjectIDs).
		Group("teachers.course_subject_id").
		Scan(&rStats)
	statMap := map[uint]rStatRow{}
	for _, rs := range rStats {
		statMap[rs.CourseSubjectID] = rs
	}

	items := make([]GovernanceCourseItem, 0, len(subjects))
	for _, cs := range subjects {
		stat := statMap[cs.ID]
		items = append(items, GovernanceCourseItem{
			ID:           cs.ID,
			Name:         cs.Name,
			Verified:     cs.Verified,
			TeacherCount: teacherCountMap[cs.ID],
			RatingCount:  stat.RatingCount,
			AverageStar:  math.Round(stat.AvgStar*10) / 10,
		})
	}
	return items, nil
}

// ---------------- 别名管理与记录 ----------------

// AliasView 别名视图。
type AliasView struct {
	ID         uint      `json:"id"`
	Type       string    `json:"type"` // teacher | course
	SubjectID  uint      `json:"course_subject_id"`
	Subject    string    `json:"course_subject_name"`
	TargetID   uint      `json:"target_id"`
	TargetName string    `json:"target_name"`
	Alias      string    `json:"alias"`
	Normalized string    `json:"normalized_alias"`
	Source     string    `json:"source"`
	CreatedBy  *uint     `json:"created_by,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
}

// AddAliasInput 别名新增输入。
type AddAliasInput struct {
	Type            string `json:"type"` // teacher | course
	CourseSubjectID uint   `json:"course_subject_id"`
	TeacherID       uint   `json:"teacher_id,omitempty"`
	Alias           string `json:"alias"`
}

func (s *TeacherGovernanceService) ListAliases(aliasType, q string, page, limit int) ([]AliasView, bool, int, error) {
	if s == nil || s.db == nil {
		return nil, false, 0, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if page <= 0 {
		page = 1
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	out := []AliasView{}
	aliasType = strings.ToLower(strings.TrimSpace(aliasType))

	if aliasType == "" || aliasType == "course" {
		var courseAliases []models.CourseSubjectAlias
		if err := s.db.Order("id DESC").Find(&courseAliases).Error; err != nil {
			return nil, false, 0, governanceErr(CodeTeacherNotFound, "读取课程别名失败", err)
		}
		subjectIDs := []uint{}
		for _, a := range courseAliases {
			subjectIDs = append(subjectIDs, a.CourseSubjectID)
		}
		subjects := map[uint]models.CourseSubject{}
		if len(subjectIDs) > 0 {
			var list []models.CourseSubject
			s.db.Where("id IN ?", subjectIDs).Find(&list)
			for _, subj := range list {
				subjects[subj.ID] = subj
			}
		}
		for _, a := range courseAliases {
			subj := subjects[a.CourseSubjectID]
			out = append(out, AliasView{
				ID:         a.ID,
				Type:       "course",
				SubjectID:  a.CourseSubjectID,
				Subject:    subj.Name,
				TargetID:   subj.ID,
				TargetName: subj.Name,
				Alias:      a.Alias,
				Normalized: a.NormalizedAlias,
				Source:     "admin",
				CreatedAt:  a.CreatedAt,
			})
		}
	}

	if aliasType == "" || aliasType == "teacher" {
		var teacherAliases []models.TeacherAlias
		if err := s.db.Order("id DESC").Find(&teacherAliases).Error; err != nil {
			return nil, false, 0, governanceErr(CodeTeacherNotFound, "读取教师别名失败", err)
		}
		tIDs := []uint{}
		sIDs := []uint{}
		for _, a := range teacherAliases {
			tIDs = append(tIDs, a.TeacherID)
			sIDs = append(sIDs, a.CourseSubjectID)
		}
		teachers := map[uint]models.Teacher{}
		if len(tIDs) > 0 {
			var list []models.Teacher
			s.db.Where("id IN ?", tIDs).Find(&list)
			for _, t := range list {
				teachers[t.ID] = t
			}
		}
		subjects := map[uint]models.CourseSubject{}
		if len(sIDs) > 0 {
			var list []models.CourseSubject
			s.db.Where("id IN ?", sIDs).Find(&list)
			for _, subj := range list {
				subjects[subj.ID] = subj
			}
		}
		for _, a := range teacherAliases {
			t := teachers[a.TeacherID]
			subj := subjects[a.CourseSubjectID]
			out = append(out, AliasView{
				ID:         a.ID,
				Type:       "teacher",
				SubjectID:  a.CourseSubjectID,
				Subject:    subj.Name,
				TargetID:   t.ID,
				TargetName: t.Name,
				Alias:      a.Alias,
				Normalized: a.NormalizedAlias,
				Source:     a.Source,
				CreatedBy:  a.CreatedBy,
				CreatedAt:  a.CreatedAt,
			})
		}
	}

	if q := strings.TrimSpace(q); q != "" {
		filtered := make([]AliasView, 0, len(out))
		for _, item := range out {
			if strings.Contains(item.Alias, q) || strings.Contains(item.TargetName, q) || strings.Contains(item.Subject, q) {
				filtered = append(filtered, item)
			}
		}
		out = filtered
	}

	sort.Slice(out, func(i, j int) bool {
		return out[i].CreatedAt.After(out[j].CreatedAt)
	})

	offset := (page - 1) * limit
	hasMore := false
	if offset < len(out) {
		end := offset + limit
		if end < len(out) {
			hasMore = true
			out = out[offset:end]
		} else {
			out = out[offset:]
		}
	} else {
		out = []AliasView{}
	}

	return out, hasMore, page, nil
}

func (s *TeacherGovernanceService) AddAlias(adminID uint, input AddAliasInput) (*AliasView, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if adminID == 0 {
		return nil, governanceErr(CodeTeacherGovernanceForbidden, "无权管理别名", nil)
	}
	alias := strings.TrimSpace(input.Alias)
	if alias == "" {
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "别名不能为空", nil)
	}

	switch strings.ToLower(input.Type) {
	case "course":
		if input.CourseSubjectID == 0 {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "必须指定目标学科", nil)
		}
		var subject models.CourseSubject
		if err := s.db.First(&subject, input.CourseSubjectID).Error; err != nil {
			return nil, governanceErr(CodeTeacherNotFound, "目标学科不存在", err)
		}
		if err := ensureCourseSubjectAlias(s.db, alias, subject.ID); err != nil {
			return nil, err
		}
		return &AliasView{
			Type:       "course",
			SubjectID:  subject.ID,
			Subject:    subject.Name,
			TargetID:   subject.ID,
			TargetName: subject.Name,
			Alias:      alias,
			Normalized: models.NormalizeCourseSubjectName(alias),
			Source:     "admin",
			CreatedAt:  time.Now(),
		}, nil

	case "teacher":
		if input.TeacherID == 0 {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "必须指定目标教师", nil)
		}
		var teacher models.Teacher
		if err := models.ScopeActiveTeachers(s.db).First(&teacher, input.TeacherID).Error; err != nil {
			return nil, governanceErr(CodeTeacherNotFound, "目标教师不存在或已被合并", err)
		}
		subjectID := derefUint(teacher.CourseSubjectID)
		if subjectID == 0 && input.CourseSubjectID != 0 {
			subjectID = input.CourseSubjectID
		}
		if subjectID == 0 {
			return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "目标教师未归属任何学科", nil)
		}
		if err := ensureTeacherAlias(s.db, subjectID, alias, teacher.ID, teacher.Name, adminID); err != nil {
			return nil, err
		}
		return &AliasView{
			Type:       "teacher",
			SubjectID:  subjectID,
			TargetID:   teacher.ID,
			TargetName: teacher.Name,
			Alias:      alias,
			Normalized: models.NormalizeTeacherName(alias),
			Source:     "admin",
			CreatedBy:  &adminID,
			CreatedAt:  time.Now(),
		}, nil

	default:
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "未知的别名类型", nil)
	}
}

func (s *TeacherGovernanceService) DeleteAlias(adminID uint, aliasType string, id uint) error {
	if s == nil || s.db == nil {
		return governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if adminID == 0 {
		return governanceErr(CodeTeacherGovernanceForbidden, "无权管理别名", nil)
	}
	switch strings.ToLower(aliasType) {
	case "course":
		return s.db.Delete(&models.CourseSubjectAlias{}, id).Error
	case "teacher":
		return s.db.Delete(&models.TeacherAlias{}, id).Error
	default:
		return governanceErr(CodeTeacherGovernanceInvalidInput, "未知的别名类型", nil)
	}
}

// MergeRecordView 审计快照视图。
type MergeRecordView struct {
	ID                    uint      `json:"id"`
	BatchID               string    `json:"batch_id"`
	Action                string    `json:"action"`
	Reason                string    `json:"reason"`
	KeeperID              uint      `json:"keeper_id"`
	KeeperName            string    `json:"keeper_name"`
	LoserID               uint      `json:"loser_id"`
	LoserName             string    `json:"loser_name"`
	SubjectName           string    `json:"subject_name"`
	LoserCourse           string    `json:"loser_course"`
	MigratedRatings       int       `json:"migrated_ratings"`
	SoftDeletedRatings    int       `json:"soft_deleted_ratings"`
	MigratedVotes         int       `json:"migrated_votes"`
	MigratedSubmissions   int       `json:"migrated_submissions"`
	SupersededSubmissions int       `json:"superseded_submissions"`
	CourseAliasesAdded    int       `json:"course_aliases_added"`
	TeacherAliasesAdded   int       `json:"teacher_aliases_added"`
	AdminName             string    `json:"admin_name"`
	CreatedAt             time.Time `json:"created_at"`
}

func (s *TeacherGovernanceService) ListMergeRecords(cursor uint, limit int) ([]MergeRecordView, bool, uint, error) {
	if s == nil || s.db == nil {
		return nil, false, 0, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	query := s.db.Order("id DESC")
	if cursor > 0 {
		query = query.Where("id < ?", cursor)
	}
	var rows []models.TeacherMergeRecord
	if err := query.Limit(limit + 1).Find(&rows).Error; err != nil {
		return nil, false, 0, governanceErr(CodeTeacherNotFound, "读取合并记录失败", err)
	}
	hasMore := false
	var nextCursor uint
	if len(rows) > limit {
		hasMore = true
		rows = rows[:limit]
		nextCursor = rows[limit-1].ID
	} else if len(rows) > 0 {
		nextCursor = rows[len(rows)-1].ID
	}
	out := make([]MergeRecordView, 0, len(rows))
	for _, row := range rows {
		out = append(out, MergeRecordView{
			ID:                    row.ID,
			BatchID:               row.BatchID,
			Action:                row.Action,
			Reason:                row.Reason,
			KeeperID:              row.KeeperID,
			KeeperName:            row.KeeperNameSnapshot,
			LoserID:               row.LoserID,
			LoserName:             row.LoserNameSnapshot,
			SubjectName:           row.KeeperSubjectNameSnapshot,
			LoserCourse:           row.LoserSubjectNameSnapshot,
			MigratedRatings:       row.MigratedRatings,
			SoftDeletedRatings:    row.SoftDeletedRatings,
			MigratedVotes:         row.MigratedVotes,
			MigratedSubmissions:   row.MigratedSubmissions,
			SupersededSubmissions: row.SupersededSubmissions,
			CourseAliasesAdded:    row.CourseAliasesAdded,
			TeacherAliasesAdded:   row.TeacherAliasesAdded,
			AdminName:             row.AdminName,
			CreatedAt:             row.CreatedAt,
		})
	}
	return out, hasMore, nextCursor, nil
}

func (s *TeacherGovernanceService) ListGovernanceTeachers(q string, cursor uint, limit int, includeMerged bool, subjectID *uint) ([]GovernanceTeacherView, bool, uint, error) {
	if s == nil || s.db == nil {
		return nil, false, 0, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, hasMore, nextCursor, maps, err := loadGovernanceTeacherRows(s.db, q, cursor, limit, includeMerged, subjectID)
	if err != nil {
		return nil, false, 0, governanceErr(CodeTeacherNotFound, "读取教师数据失败", err)
	}
	out := make([]GovernanceTeacherView, 0, len(rows))
	for _, row := range rows {
		out = append(out, maps.view(row))
	}
	return out, hasMore, nextCursor, nil
}

// AliasTargetView 别名目标搜索项（供治理工作台下拉选择）。
type AliasTargetView struct {
	ID        uint   `json:"id"`
	Name      string `json:"name"`
	SubjectID uint   `json:"course_subject_id,omitempty"`
	Verified  bool   `json:"verified"`
}

// SearchAliasTargets 按类型与关键词搜索别名目标（学科 / 教师），
// 供治理工作台以名称选择替代手输数据库 ID。
func (s *TeacherGovernanceService) SearchAliasTargets(targetType, q string, limit int) ([]AliasTargetView, error) {
	if s == nil || s.db == nil {
		return nil, governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	like := "%" + escapeLike(strings.TrimSpace(q)) + "%"
	out := []AliasTargetView{}

	switch strings.ToLower(strings.TrimSpace(targetType)) {
	case "course":
		var subjects []models.CourseSubject
		query := s.db.Order("verified DESC, id ASC").Limit(limit)
		if strings.TrimSpace(q) != "" {
			query = query.Where("name LIKE ?", like)
		}
		if err := query.Find(&subjects).Error; err != nil {
			return nil, governanceErr(CodeTeacherNotFound, "读取学科失败", err)
		}
		for _, cs := range subjects {
			out = append(out, AliasTargetView{ID: cs.ID, Name: cs.Name, Verified: cs.Verified})
		}
	case "teacher":
		var teachers []models.Teacher
		query := models.ScopeActiveTeachers(s.db).Order("verified DESC, id ASC").Limit(limit)
		if strings.TrimSpace(q) != "" {
			query = query.Where("name LIKE ? OR course LIKE ?", like, like)
		}
		if err := query.Find(&teachers).Error; err != nil {
			return nil, governanceErr(CodeTeacherNotFound, "读取教师失败", err)
		}
		for _, t := range teachers {
			out = append(out, AliasTargetView{ID: t.ID, Name: t.Name, SubjectID: derefUint(t.CourseSubjectID), Verified: t.Verified})
		}
	default:
		return nil, governanceErr(CodeTeacherGovernanceInvalidInput, "未知的目标类型", nil)
	}
	return out, nil
}

// MergePendingTeacherInto 待审教师快速并入已有教师（Section 21.1）。
func (s *TeacherGovernanceService) MergePendingTeacherInto(adminID, pendingID, keeperID uint, registerAlias bool) (string, error) {
	if s == nil || s.db == nil {
		return "", governanceErr(CodeTeacherNotFound, "治理服务不可用", nil)
	}
	if adminID == 0 {
		return "", governanceErr(CodeTeacherGovernanceForbidden, "无权执行合并", nil)
	}
	if pendingID == keeperID {
		return "", governanceErr(CodeTeacherGovernanceInvalidInput, "不能合并到教师本人", nil)
	}

	adminName := ""
	var admin models.User
	if err := s.db.Select("nickname").First(&admin, adminID).Error; err == nil {
		adminName = admin.Nickname
	}
	batchID := fmt.Sprintf("pending-merge-%d", time.Now().UnixNano())

	// 所有读取、校验与写入都在同一事务内完成，并对 pending / keeper 加确定性行锁，
	// 避免并发快速合并绕过 verified/merged 校验，或重挂后状态不一致。
	lockIDs := []uint{pendingID, keeperID}
	sort.Slice(lockIDs, func(i, j int) bool { return lockIDs[i] < lockIDs[j] })

	var keeperName string
	err := s.db.Transaction(func(tx *gorm.DB) error {
		// 1. 按 ID 顺序加写锁
		locked := map[uint]models.Teacher{}
		for _, id := range lockIDs {
			var lt models.Teacher
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&lt, id).Error; err != nil {
				if id == pendingID {
					return governanceErr(CodeTeacherNotFound, "待审教师不存在或已被合并", err)
				}
				return governanceErr(CodeTeacherNotFound, "目标教师不存在或已被合并", err)
			}
			locked[id] = lt
		}
		pending := locked[pendingID]
		keeper := locked[keeperID]

		// 2. 快速合并仅适用于待审（未审核）且尚未合并的教师
		if pending.Verified {
			return governanceErr(CodeUseGovernanceMerge, "目标教师已审核，禁止快速并入，请使用教师数据治理工作台", nil)
		}
		if pending.MergedIntoID != nil {
			return governanceErr(CodeTeacherAlreadyMerged, "待审教师已被合并", nil)
		}
		if keeper.MergedIntoID != nil {
			return governanceErr(CodeTeacherNotFound, "目标教师不存在或已被合并", nil)
		}

		// 3. 学科校验：解析 pending 的 canonical 学科，必须与 keeper 学科一致，
		//    否则必须走完整课程实体决策。pending 无学科时按课程名 exact → alias 解析。
		keeperSubjectID := derefUint(keeper.CourseSubjectID)
		if keeperSubjectID == 0 {
			return governanceErr(CodeCrossSubjectMergeRequiresSubjectDecision, "目标教师无学科归属，不能快速并入，请使用教师数据治理工作台", nil)
		}
		pendingSubjectID := derefUint(pending.CourseSubjectID)
		if pendingSubjectID == 0 {
			resolved, rerr := resolveCourseSubjectByAlias(tx, pending.Course)
			if rerr != nil || resolved == nil {
				return governanceErr(CodeCrossSubjectMergeRequiresSubjectDecision, "待审教师课程无法解析到目标学科，不能快速并入，请使用教师数据治理工作台", nil)
			}
			pendingSubjectID = resolved.ID
		}
		if pendingSubjectID != keeperSubjectID {
			return governanceErr(CodeCrossSubjectMergeRequiresSubjectDecision, "待审教师与目标教师不属于同一学科，不能快速并入，请使用教师数据治理工作台", nil)
		}

		// 4. 依据 §21.1 约束：active rating count 必须为 0
		var activeRatings int64
		if err := tx.Model(&models.TeacherRating{}).
			Where("teacher_id = ? AND deleted_at IS NULL", pending.ID).Count(&activeRatings).Error; err != nil {
			return governanceErr(CodeTeacherGovernanceInternalError, "统计评价失败", err)
		}
		if activeRatings > 0 {
			return governanceErr(CodeUseGovernanceMerge, "待审教师已有评价数据，禁止快速并入，请使用教师数据治理工作台", nil)
		}

		// 5. CAS 更新：仅当 pending 仍未审核、未合并时才落库
		updateFields := map[string]interface{}{
			"merged_into_id": keeper.ID,
		}
		if derefUint(pending.CourseSubjectID) != keeperSubjectID {
			updateFields["course_subject_id"] = keeperSubjectID
		}
		res := tx.Model(&models.Teacher{}).
			Where("id = ? AND merged_into_id IS NULL AND verified = ?", pending.ID, false).
			Updates(updateFields)
		if res.Error != nil {
			return governanceErr(CodeTeacherNotFound, "标记合并状态失败", res.Error)
		}
		if res.RowsAffected != 1 {
			return governanceErr(CodeTeacherGovernanceStateConflict, "待审教师状态已变更，请刷新后重试", nil)
		}

		// 6. 重挂提交记录
		if err := tx.Model(&models.CourseEvaluationSubmission{}).
			Where("teacher_id = ?", pending.ID).
			Updates(map[string]interface{}{
				"teacher_id":   keeper.ID,
				"teacher_name": keeper.Name,
			}).Error; err != nil {
			return governanceErr(CodeTeacherNotFound, "重挂待审教师提交记录失败", err)
		}

		// 7. 登记别名
		aliasAdded := false
		if registerAlias &&
			models.NormalizeTeacherName(pending.Name) != models.NormalizeTeacherName(keeper.Name) {
			if err := ensureTeacherAlias(tx, keeperSubjectID, pending.Name, keeper.ID, keeper.Name, adminID); err != nil {
				return err
			}
			aliasAdded = true
		}
		tAliasCount := 0
		if aliasAdded {
			tAliasCount = 1
		}

		if err := tx.Create(&models.TeacherMergeRecord{
			BatchID:                   batchID,
			KeeperID:                  keeper.ID,
			LoserID:                   pending.ID,
			KeeperNameSnapshot:        keeper.Name,
			LoserNameSnapshot:         pending.Name,
			KeeperSubjectNameSnapshot: keeper.Course,
			LoserSubjectNameSnapshot:  pending.Course,
			TeacherAliasesAdded:       tAliasCount,
			AdminID:                   adminID,
			AdminName:                 adminName,
			CreatedAt:                 time.Now(),
		}).Error; err != nil {
			return err
		}

		if err := writeCourseEvaluationAdminLog(tx, adminID, "待审教师快速合并",
			fmt.Sprintf("teacher:%d", pending.ID),
			fmt.Sprintf("待审教师 %s(#%d) 并入 %s(#%d)，登记别名: %t", pending.Name, pending.ID, keeper.Name, keeper.ID, aliasAdded)); err != nil {
			return err
		}
		keeperName = keeper.Name
		return nil
	})
	if err != nil {
		return "", err
	}
	return keeperName, nil
}

// resolveCourseSubjectByAlias 按课程名解析 canonical 学科（精确 → 别名），不创建。
func resolveCourseSubjectByAlias(tx *gorm.DB, courseName string) (*models.CourseSubject, error) {
	normalized := models.NormalizeCourseSubjectName(courseName)
	if normalized == "" {
		return nil, gorm.ErrRecordNotFound
	}
	var subject models.CourseSubject
	if err := tx.Where("normalized_name = ?", normalized).Order("verified DESC, id ASC").First(&subject).Error; err == nil {
		return &subject, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}
	var alias models.CourseSubjectAlias
	if err := tx.Where("normalized_alias = ?", normalized).Order("id ASC").First(&alias).Error; err == nil {
		if err := tx.First(&subject, alias.CourseSubjectID).Error; err == nil {
			return &subject, nil
		}
	}
	return nil, gorm.ErrRecordNotFound
}

// 辅助函数
func derefUint(v *uint) uint {
	if v == nil {
		return 0
	}
	return *v
}

func teacherViewOf(db *gorm.DB, t models.Teacher, ratingCount, pendingCount int) GovernanceTeacherView {
	subjName := ""
	subjVerified := false
	if t.CourseSubjectID != nil && *t.CourseSubjectID != 0 {
		var cs models.CourseSubject
		if err := db.Select("name", "verified").First(&cs, *t.CourseSubjectID).Error; err == nil {
			subjName = cs.Name
			subjVerified = cs.Verified
		}
	}
	var aliasCount int64
	if t.CourseSubjectID != nil && *t.CourseSubjectID != 0 {
		db.Model(&models.TeacherAlias{}).
			Where("teacher_id = ? AND course_subject_id = ?", t.ID, *t.CourseSubjectID).
			Count(&aliasCount)
	}
	return GovernanceTeacherView{
		ID:                     t.ID,
		Name:                   t.Name,
		Course:                 t.Course,
		SubjectID:              t.CourseSubjectID,
		SubjectName:            subjName,
		SubjectNameCompat:      subjName,
		SubjectVerified:        subjVerified,
		SubjectVerifiedCompat:  subjVerified,
		AliasCount:             int(aliasCount),
		Verified:               t.Verified,
		CanonicalSource:        t.CanonicalSource,
		RatingCount:            ratingCount,
		PendingSubmissionCount: pendingCount,
		PendingCount:           pendingCount,
		CreatedAt:              t.CreatedAt,
		MergedIntoID:           t.MergedIntoID,
		IsMerged:               t.MergedIntoID != nil,
	}
}

func teacherActiveScope(db *gorm.DB) *gorm.DB {
	return models.ScopeActiveTeachers(db)
}
