package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestValidateCitationsBlocksUnknownChunksAndBuildsServerSources(t *testing.T) {
	chunks := []RetrievedChunk{{
		ChunkID: 18, DocumentID: 3, Title: "学生手册", Department: "学生处",
		SourceURI: "https://example.edu/policy", Content: "请假规定", RRFScore: 0.05,
	}}
	answer, sources, invalid := ValidateCitations("有效规定[chunk:18]，伪造内容[chunk:999]。", chunks)
	require.True(t, invalid)
	require.Contains(t, answer, "[chunk:18]")
	require.NotContains(t, answer, "[chunk:999]")
	require.Len(t, sources, 1)
	require.Equal(t, "学生手册", sources[0].Title)
	require.Equal(t, "confirmed", sources[0].Confidence)
}

func TestFormatVectorUsesPgvectorLiteral(t *testing.T) {
	require.Equal(t, "[0.5000000,-0.2500000]", formatVector([]float32{0.5, -0.25}))
}
