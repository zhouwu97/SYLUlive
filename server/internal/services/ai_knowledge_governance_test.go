package services

import (
	"context"
	"crypto/sha256"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestInspectKnowledgeDocumentFindsMissingMetadataAndEmptySection(t *testing.T) {
	document := governanceDocument("待治理政策", "# 总则\n\n## 空章节", "school_policy")
	document.SourceURI = ""
	document.Department = ""

	report, err := InspectKnowledgeDocument(context.Background(), nil, document)
	require.NoError(t, err)
	require.True(t, report.HasBlockingIssues())
	require.NotEmpty(t, report.UnresolvedItems)
	requireIssueCodes(t, report, "department_missing", "source_locator_missing", "empty_section")
}

func TestInspectKnowledgeDocumentRejectsInvalidSourceURL(t *testing.T) {
	document := governanceDocument("来源异常政策", "政策正文", "school_policy")
	document.SourceURI = "not-a-valid-url"

	report, err := InspectKnowledgeDocument(context.Background(), nil, document)
	require.NoError(t, err)
	require.True(t, report.HasBlockingIssues())
	requireIssueCodes(t, report, "source_url_invalid")
}

func TestInspectKnowledgeDocumentFindsDuplicateAndPublishedVersionConflict(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:governance?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeDocument{}))

	current := governanceDocument("现行规定", "现行正文", "school_exam_policy")
	current.Status = models.KnowledgeStatusPublished
	require.NoError(t, db.Create(&current).Error)
	duplicate := governanceDocument("重复规定", "现行正文", "another_policy")
	require.NoError(t, db.Create(&duplicate).Error)

	replacement := governanceDocument("修订规定", "修订正文", "school_exam_policy")
	report, err := InspectKnowledgeDocument(context.Background(), db, replacement)
	require.NoError(t, err)
	require.True(t, report.RequiresSupersede())
	requireIssueCodes(t, report, "published_version_conflict")

	duplicateReport, err := InspectKnowledgeDocument(context.Background(), db, duplicate)
	require.NoError(t, err)
	require.True(t, duplicateReport.HasBlockingIssues())
	requireIssueCodes(t, duplicateReport, "duplicate_content_hash")
}

func TestInspectKnowledgeDocumentRequiresExplicitHistoricalBoundary(t *testing.T) {
	document := governanceDocument("历史二考口径", "2004 年二考成绩记为 D 或 F。", "historical_school_second_exam_policy")

	report, err := InspectKnowledgeDocument(context.Background(), nil, document)
	require.NoError(t, err)
	require.True(t, report.HasBlockingIssues())
	requireIssueCodes(t, report, "historical_boundary_missing")

	document.Content += " 本文件是历史材料，不得覆盖现行规则。"
	hash := sha256.Sum256([]byte(document.Content))
	document.ContentHash = fmt.Sprintf("%x", hash)
	report, err = InspectKnowledgeDocument(context.Background(), nil, document)
	require.NoError(t, err)
	require.False(t, report.HasBlockingIssues())
}

func governanceDocument(title, content, documentType string) models.AIKnowledgeDocument {
	effectiveFrom := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	hash := sha256.Sum256([]byte(content))
	return models.AIKnowledgeDocument{
		Title: title, SourceType: "official", SourceURI: "https://example.edu/policy",
		DocumentType: documentType, Department: "教务处", EffectiveFrom: &effectiveFrom,
		Content: content, ContentHash: fmt.Sprintf("%x", hash), Status: models.KnowledgeStatusInspected,
	}
}

func requireIssueCodes(t *testing.T, report KnowledgeInspectionReport, expected ...string) {
	t.Helper()
	codes := make(map[string]struct{}, len(report.Issues))
	for _, issue := range report.Issues {
		codes[issue.Code] = struct{}{}
	}
	for _, code := range expected {
		_, exists := codes[code]
		require.Truef(t, exists, "缺少治理问题 %s：%#v", code, report.Issues)
	}
}
