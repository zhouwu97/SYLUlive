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
