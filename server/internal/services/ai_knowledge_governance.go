package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const (
	KnowledgeIssueBlocking        = "blocking"
	KnowledgeIssueRequiresReview  = "requires_review"
	KnowledgeIssueRequiresReplace = "requires_supersede"
)

var markdownHeadingPattern = regexp.MustCompile(`^\s{0,3}(#{1,6})\s+(.+?)\s*$`)

// KnowledgeInspectionIssue 是可稳定落盘并供发布工具判定的治理问题。
type KnowledgeInspectionIssue struct {
	Code               string `json:"code"`
	Severity           string `json:"severity"`
	Field              string `json:"field,omitempty"`
	Message            string `json:"message"`
	RelatedDocumentIDs []uint `json:"related_document_ids,omitempty"`
}

// KnowledgeInspectionReport 同时承载静态治理结果和 LangChain 索引契约。
type KnowledgeInspectionReport struct {
	Bytes                  int                        `json:"bytes"`
	Runes                  int                        `json:"runes"`
	ContentHash            string                     `json:"content_hash"`
	Currentness            string                     `json:"currentness"`
	Issues                 []KnowledgeInspectionIssue `json:"issues"`
	UnresolvedItems        []string                   `json:"unresolved_items"`
	BlockingCount          int                        `json:"blocking_count"`
	RequiresSupersedeCount int                        `json:"requires_supersede_count"`
	ChunkCount             int                        `json:"chunk_count,omitempty"`
	ChunkingVersion        string                     `json:"chunking_version,omitempty"`
	EmbeddingModelName     string                     `json:"embedding_model_name,omitempty"`
	EmbeddingModelVersion  string                     `json:"embedding_model_version,omitempty"`
	EmbeddingDimensions    int                        `json:"embedding_dimensions,omitempty"`
}

func (r KnowledgeInspectionReport) HasBlockingIssues() bool {
	return r.BlockingCount > 0
}

func (r KnowledgeInspectionReport) RequiresSupersede() bool {
	return r.RequiresSupersedeCount > 0
}

// InspectKnowledgeDocument 执行不写库的静态与跨文档检查。
func InspectKnowledgeDocument(ctx context.Context, db *gorm.DB, document models.AIKnowledgeDocument) (KnowledgeInspectionReport, error) {
	content := strings.TrimSpace(document.Content)
	hash := sha256.Sum256([]byte(content))
	actualHash := hex.EncodeToString(hash[:])
	report := KnowledgeInspectionReport{
		Bytes: len(content), Runes: utf8.RuneCountInString(content), ContentHash: actualHash,
		Currentness: knowledgeCurrentness(document), Issues: make([]KnowledgeInspectionIssue, 0),
		UnresolvedItems: make([]string, 0),
	}
	add := func(code, severity, field, message string, related ...uint) {
		issue := KnowledgeInspectionIssue{Code: code, Severity: severity, Field: field, Message: message}
		if len(related) > 0 {
			issue.RelatedDocumentIDs = append([]uint(nil), related...)
		}
		report.Issues = append(report.Issues, issue)
	}

	if content == "" {
		add("content_empty", KnowledgeIssueBlocking, "content", "正文不能为空")
	}
	if strings.TrimSpace(document.ContentHash) == "" || !strings.EqualFold(document.ContentHash, actualHash) {
		add("content_hash_mismatch", KnowledgeIssueBlocking, "content_hash", "内容 hash 缺失或与正文不一致")
	}
	if strings.TrimSpace(document.SourceType) == "" {
		add("source_type_missing", KnowledgeIssueBlocking, "source_type", "来源类型不能为空")
	}
	if strings.TrimSpace(document.SourceURI) == "" && strings.TrimSpace(document.SourceFileName) == "" {
		add("source_locator_missing", KnowledgeIssueBlocking, "source_uri", "来源 URL 和来源文件至少填写一项")
	}
	if sourceURI := strings.TrimSpace(document.SourceURI); sourceURI != "" {
		parsed, err := url.ParseRequestURI(sourceURI)
		if err != nil || parsed.Host == "" || parsed.User != nil ||
			(!strings.EqualFold(parsed.Scheme, "http") && !strings.EqualFold(parsed.Scheme, "https")) {
			add("source_url_invalid", KnowledgeIssueBlocking, "source_uri", "来源 URL 格式无效")
		}
	}
	if strings.Contains(strings.ToLower(document.SourceURI), "uploaded") && strings.TrimSpace(document.SourceFileName) == "" {
		add("source_file_missing", KnowledgeIssueBlocking, "source_file_name", "上传来源必须记录原始文件名")
	}
	if strings.TrimSpace(document.DocumentType) == "" {
		add("document_type_missing", KnowledgeIssueBlocking, "document_type", "文档类型不能为空")
	}
	if strings.TrimSpace(document.Department) == "" {
		add("department_missing", KnowledgeIssueBlocking, "department", "发布或解释部门不能为空")
	}
	if document.EffectiveFrom == nil && strings.Contains(strings.ToLower(document.DocumentType), "policy") {
		add("effective_from_missing", KnowledgeIssueRequiresReview, "effective_from", "政策文档缺少生效时间，发布前需人工确认")
	}
	if document.EffectiveFrom != nil && document.EffectiveTo != nil && document.EffectiveTo.Before(*document.EffectiveFrom) {
		add("effective_range_invalid", KnowledgeIssueBlocking, "effective_to", "失效时间早于生效时间")
	}
	if report.Currentness == "historical" && !hasHistoricalBoundary(content) {
		add("historical_boundary_missing", KnowledgeIssueBlocking, "content", "历史文件必须明确不得覆盖现行规则")
	}
	if isCrawlerSource(document.SourceType) {
		add("crawler_requires_review", KnowledgeIssueBlocking, "source_type", "自动抓取内容只能进入 needs_review，须转为经人工核验的来源后再发布")
	}
	for _, title := range emptyMarkdownSections(content) {
		add("empty_section", KnowledgeIssueBlocking, "content", "章节没有正文："+title)
	}

	if db != nil && document.ContentHash != "" {
		var duplicates []models.AIKnowledgeDocument
		err := db.WithContext(ctx).
			Select("id", "status").
			Where("id <> ? AND content_hash = ? AND status NOT IN ?", document.ID, document.ContentHash,
				[]string{models.KnowledgeStatusRevoked, models.KnowledgeStatusSuperseded}).
			Find(&duplicates).Error
		if err != nil {
			return KnowledgeInspectionReport{}, err
		}
		if len(duplicates) > 0 {
			ids := knowledgeDocumentIDs(duplicates)
			add("duplicate_content_hash", KnowledgeIssueBlocking, "content_hash", "存在相同内容的未撤销文档", ids...)
		}
	}

	if db != nil && strings.TrimSpace(document.DocumentType) != "" {
		var conflicts []models.AIKnowledgeDocument
		err := db.WithContext(ctx).
			Select("id", "status", "effective_from", "effective_to").
			Where("id <> ? AND document_type = ? AND content_hash <> ? AND status = ?", document.ID,
				document.DocumentType, document.ContentHash, models.KnowledgeStatusPublished).
			Find(&conflicts).Error
		if err != nil {
			return KnowledgeInspectionReport{}, err
		}
		conflictIDs := make([]uint, 0, len(conflicts))
		for _, conflict := range conflicts {
			if knowledgeVersionScopeMatches(document, conflict) && knowledgeDateRangesOverlap(document, conflict) {
				conflictIDs = append(conflictIDs, conflict.ID)
			}
		}
		if len(conflictIDs) > 0 {
			sort.Slice(conflictIDs, func(i, j int) bool { return conflictIDs[i] < conflictIDs[j] })
			add("published_version_conflict", KnowledgeIssueRequiresReplace, "document_type", "同类型已发布版本与当前文档时间范围重叠，必须原子 supersede", conflictIDs...)
		}
	}

	sort.SliceStable(report.Issues, func(i, j int) bool {
		if report.Issues[i].Severity != report.Issues[j].Severity {
			return knowledgeIssuePriority(report.Issues[i].Severity) < knowledgeIssuePriority(report.Issues[j].Severity)
		}
		if report.Issues[i].Code != report.Issues[j].Code {
			return report.Issues[i].Code < report.Issues[j].Code
		}
		return report.Issues[i].Message < report.Issues[j].Message
	})
	for _, issue := range report.Issues {
		report.UnresolvedItems = append(report.UnresolvedItems, issue.Code+": "+issue.Message)
		switch issue.Severity {
		case KnowledgeIssueBlocking:
			report.BlockingCount++
		case KnowledgeIssueRequiresReplace:
			report.RequiresSupersedeCount++
		}
	}
	return report, nil
}

func knowledgeVersionScopeMatches(left, right models.AIKnowledgeDocument) bool {
	leftURI, rightURI := strings.TrimSpace(left.SourceURI), strings.TrimSpace(right.SourceURI)
	if leftURI != "" && rightURI != "" && strings.EqualFold(leftURI, rightURI) {
		return true
	}
	leftFile, rightFile := strings.TrimSpace(left.SourceFileName), strings.TrimSpace(right.SourceFileName)
	if leftFile != "" && rightFile != "" && strings.EqualFold(leftFile, rightFile) {
		return true
	}
	// 专业介绍等集合型类型允许多个不同来源并存；正式政策类型默认同类型属于同一版本作用域。
	identity := strings.ToLower(left.DocumentType)
	return !strings.Contains(identity, "profile") && !strings.Contains(identity, "catalog")
}

func knowledgeCurrentness(document models.AIKnowledgeDocument) string {
	identity := strings.ToLower(document.SourceType + " " + document.DocumentType)
	if strings.Contains(identity, "historical") || strings.Contains(identity, "历史") {
		return "historical"
	}
	if strings.Contains(identity, "curated") || strings.Contains(identity, "reasoning_card") {
		return "mixed"
	}
	return "current"
}

func hasHistoricalBoundary(content string) bool {
	return strings.Contains(content, "历史") && (strings.Contains(content, "不能覆盖") ||
		strings.Contains(content, "不覆盖") || strings.Contains(content, "不得覆盖") ||
		strings.Contains(content, "仅供历史") || strings.Contains(content, "当前执行需"))
}

func isCrawlerSource(sourceType string) bool {
	normalized := strings.ToLower(strings.TrimSpace(sourceType))
	return strings.Contains(normalized, "crawl") || strings.Contains(normalized, "spider")
}

func emptyMarkdownSections(content string) []string {
	type heading struct {
		level      int
		title      string
		hasContent bool
	}
	stack := make([]heading, 0)
	empty := make([]string, 0)
	flush := func(nextLevel int) {
		for len(stack) > 0 && stack[len(stack)-1].level >= nextLevel {
			current := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if !current.hasContent {
				empty = append(empty, current.title)
			}
		}
	}
	for _, line := range strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n") {
		match := markdownHeadingPattern.FindStringSubmatch(line)
		if len(match) == 3 {
			level := len(match[1])
			flush(level)
			// 子章节本身构成父章节的有效结构。
			for index := range stack {
				stack[index].hasContent = true
			}
			stack = append(stack, heading{level: level, title: strings.TrimSpace(match[2])})
			continue
		}
		if strings.TrimSpace(line) != "" {
			for index := range stack {
				stack[index].hasContent = true
			}
		}
	}
	flush(0)
	return empty
}

func knowledgeDateRangesOverlap(left, right models.AIKnowledgeDocument) bool {
	if left.EffectiveTo != nil && right.EffectiveFrom != nil && left.EffectiveTo.Before(*right.EffectiveFrom) {
		return false
	}
	if right.EffectiveTo != nil && left.EffectiveFrom != nil && right.EffectiveTo.Before(*left.EffectiveFrom) {
		return false
	}
	return true
}

func knowledgeDocumentIDs(documents []models.AIKnowledgeDocument) []uint {
	ids := make([]uint, 0, len(documents))
	for _, document := range documents {
		ids = append(ids, document.ID)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

func knowledgeIssuePriority(severity string) int {
	switch severity {
	case KnowledgeIssueBlocking:
		return 0
	case KnowledgeIssueRequiresReplace:
		return 1
	default:
		return 2
	}
}
