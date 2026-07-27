package ai

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestV08KnowledgeContractMatchesEmbeddedContract(t *testing.T) {
	path := filepath.Join("..", "..", "..", "knowledge-base", "sylu-academic-policy", "v0.8", "policy_query_contract_v0.8.json")
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	require.True(t, bytes.Equal(policyQueryContractBytes, raw), "知识库契约与 Go 嵌入契约必须字节一致")
}
