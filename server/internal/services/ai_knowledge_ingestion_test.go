package services

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestSplitKnowledgeDocumentCreatesBoundedOverlappingChunks(t *testing.T) {
	content := "第一章：\n" + strings.Repeat("校园政策内容。", 120) + "\n第二章：\n" + strings.Repeat("办理流程说明。", 120)
	chunks := splitKnowledgeDocument(content, 180, 20)
	require.Greater(t, len(chunks), 2)
	for _, chunk := range chunks {
		require.LessOrEqual(t, len([]rune(chunk.Content)), 180)
		require.NotEmpty(t, chunk.Content)
	}
}

func TestEnqueueKnowledgeIngestionIsIdempotentWhilePending(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:knowledge-jobs?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeIngestionJob{}))
	first, err := EnqueueKnowledgeIngestion(db, 9)
	require.NoError(t, err)
	second, err := EnqueueKnowledgeIngestion(db, 9)
	require.NoError(t, err)
	require.Equal(t, first.ID, second.ID)
}

func TestKnowledgeChunkIndexTextCarriesDocumentMetadata(t *testing.T) {
	document := models.AIKnowledgeDocument{
		Title:        "沈阳理工大学本科生课程重修管理办法（沈理工教〔2025〕6号）",
		DocumentType: "school_undergraduate_retake_policy",
		Department:   "教务处",
	}
	chunk := knowledgeTextChunk{SectionTitle: "第一部分 重修范围", Content: "首次考核不合格的课程可以申请重修。"}

	indexed := knowledgeChunkIndexText(document, chunk)

	// 只索引正文时，这一段无法与“重修”文件建立联系。
	require.Contains(t, indexed, "school_undergraduate_retake_policy")
	require.Contains(t, indexed, "课程重修管理办法")
	require.Contains(t, indexed, "教务处")
	require.Contains(t, indexed, "第一部分 重修范围")
	require.Contains(t, indexed, "首次考核不合格的课程可以申请重修。")
}

func TestKnowledgeChunkIndexTextSkipsEmptyMetadata(t *testing.T) {
	indexed := knowledgeChunkIndexText(
		models.AIKnowledgeDocument{Title: "  "},
		knowledgeTextChunk{Content: "正文"},
	)
	require.Equal(t, "正文", indexed)
}

func TestKnowledgeSourceLocatorPrefersSectionTitle(t *testing.T) {
	require.Equal(t, "第九条", knowledgeSourceLocator("# 第九条：", 5))
	require.Equal(t, "关于课程重修第1项", knowledgeSourceLocator("关于课程重修第1项", 0))
	require.Equal(t, "chunk:6", knowledgeSourceLocator("", 5))
	require.Equal(t, "chunk:1", knowledgeSourceLocator("  ", 0))
	require.Len(t, []rune(knowledgeSourceLocator(strings.Repeat("章", 80), 0)), 40)
}
