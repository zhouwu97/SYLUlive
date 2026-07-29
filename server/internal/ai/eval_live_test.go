package ai

import (
	"context"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestLiveEvaluationBackendAddsMetadataAndUsesProvider(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.Exec(`CREATE TABLE ai_knowledge_documents (
		id integer primary key, document_type text, source_type text, title text
	)`).Error)
	require.NoError(t, db.Exec(`INSERT INTO ai_knowledge_documents
		(id, document_type, source_type, title) VALUES (9, 'school_undergraduate_retake_policy', 'official', '重修办法')`).Error)

	provider := &MockProvider{Response: ChatResponse{Content: "每学期不得超过3门。[chunk:81]"}}
	backend, err := NewLiveEvaluationBackend(db, staticEvaluationRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 81, DocumentID: 9, Title: "重修办法", Content: "每学期不得超过3门。",
	}}}}, provider)
	require.NoError(t, err)

	testCase := EvaluationCase{Question: "重修最多几门"}
	documents, err := backend.Retrieve(context.Background(), testCase)
	require.NoError(t, err)
	require.Len(t, documents, 1)
	require.Equal(t, "school_undergraduate_retake_policy", documents[0].DocumentType)
	require.False(t, documents[0].Historical)

	output, err := backend.Generate(context.Background(), testCase, documents)
	require.NoError(t, err)
	require.False(t, output.Refused)
	require.Len(t, provider.Requests, 1)
	require.Contains(t, provider.Requests[0].Messages[1].Content, testCase.Question)
	require.Contains(t, provider.Requests[0].Messages[1].Content, "chunk_id=\"81\"")
}

type staticEvaluationRetriever struct {
	result RetrievalResult
	err    error
}

func (r staticEvaluationRetriever) Retrieve(context.Context, string) (RetrievalResult, error) {
	return r.result, r.err
}
