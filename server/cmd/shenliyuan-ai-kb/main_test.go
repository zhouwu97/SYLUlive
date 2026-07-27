package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

func TestDocumentMutationNeverCallsAPIWithoutExecuteAndExactConfirmation(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"document":{"id":9}}`))
	}))
	defer server.Close()
	getenv := mapEnvironment(map[string]string{"SHENLIYUAN_ADMIN_JWT": "secret-token"})

	var stdout, stderr bytes.Buffer
	code := run([]string{"publish", "--document-id", "9", "--base-url", server.URL}, getenv, &stdout, &stderr, server.Client())
	require.Equal(t, 0, code)
	require.Zero(t, requests.Load())
	require.Contains(t, stdout.String(), "APPLY:publish:9")

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"publish", "--document-id", "9", "--base-url", server.URL, "--execute", "--confirm", "wrong"}, getenv, &stdout, &stderr, server.Client())
	require.Equal(t, 2, code)
	require.Zero(t, requests.Load())
	require.Contains(t, stderr.String(), "未发出写请求")
}

func TestReleaseExecuteRequiresRollbackRecordBeforeRemoteRequest(t *testing.T) {
	directory := t.TempDir()
	documents := []releaseDocument{{
		Title: "考试规定", SourceType: "text", SourceURI: "https://example.edu/exam",
		DocumentType: "school_exam_policy", Department: "教务处", EffectiveFrom: "2026-01-01", Content: "考试规定正文。",
	}}
	bundlePath, bundleBytes := writeBundleFixture(t, directory, documents)
	manifest, err := buildReleaseManifest("v0.6", bundlePath, "", documents, bundleBytes, time.Unix(0, 0))
	require.NoError(t, err)
	manifestPath := writeJSONFixture(t, directory, "manifest.json", manifest)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		http.Error(response, "不应发出请求", http.StatusInternalServerError)
	}))
	defer server.Close()

	getenv := mapEnvironment(map[string]string{
		"SHENLIYUAN_ADMIN_JWT": "admin-token",
		"RAG_SERVICE_TOKEN":    "rag-token",
	})
	var stdout, stderr bytes.Buffer
	code := run([]string{
		"release", "--bundle", bundlePath, "--manifest", manifestPath,
		"--base-url", server.URL, "--rag-base-url", server.URL,
		"--execute", "--confirm", "RELEASE:v0.6",
	}, getenv, &stdout, &stderr, server.Client())
	require.Equal(t, 2, code)
	require.Zero(t, requests.Load())
	require.Contains(t, stderr.String(), "--report")
}

func TestFetchKnowledgeInventoryFollowsBeforeIDPagination(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		require.Equal(t, http.MethodGet, request.Method)
		require.Equal(t, "Bearer inventory-token", request.Header.Get("Authorization"))
		require.Equal(t, "100", request.URL.Query().Get("limit"))
		response.Header().Set("Content-Type", "application/json")
		switch request.URL.Query().Get("before_id") {
		case "":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"documents":      []models.AIKnowledgeDocument{{ID: 305}, {ID: 204}},
				"next_before_id": 204,
			})
		case "204":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"documents":      []models.AIKnowledgeDocument{{ID: 103}},
				"next_before_id": 0,
			})
		default:
			http.Error(response, "unexpected cursor", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	documents, err := fetchKnowledgeInventory(context.Background(), server.Client(), server.URL, "inventory-token")
	require.NoError(t, err)
	require.Equal(t, int32(2), requests.Load())
	require.Equal(t, []uint{305, 204, 103}, []uint{documents[0].ID, documents[1].ID, documents[2].ID})
}

func TestDryRunReportsSkipAddAndManifestDrift(t *testing.T) {
	directory := t.TempDir()
	documents := []releaseDocument{
		{Title: "计算机专业", SourceType: "text", SourceURI: "https://example.edu/cs", DocumentType: "official_major_profile", Department: "学院", Content: "# 计算机专业\n\n专业正文。"},
		{Title: "通信专业", SourceType: "text", SourceURI: "https://example.edu/ce", DocumentType: "official_major_profile", Department: "学院", Content: "# 通信专业\n\n专业正文。"},
	}
	bundlePath, bundleBytes := writeBundleFixture(t, directory, documents)
	manifest, err := buildReleaseManifest("v0.6", bundlePath, "", documents, bundleBytes, time.Unix(0, 0))
	require.NoError(t, err)
	manifestPath := writeJSONFixture(t, directory, "manifest.json", manifest)
	first, err := documents[0].toModel(90)
	require.NoError(t, err)
	first.Status = models.KnowledgeStatusPublished
	inventoryPath := writeJSONFixture(t, directory, "inventory.json", map[string]any{"documents": []models.AIKnowledgeDocument{first}})

	report, err := buildDryRunReport(context.Background(), dryRunOptions{
		Bundle: bundlePath, Manifest: manifestPath, Inventory: inventoryPath, Timeout: time.Minute,
	}, mapEnvironment(nil), http.DefaultClient)
	require.NoError(t, err)
	require.False(t, report.Blocked)
	require.Equal(t, dryRunSummary{Add: 1, Skip: 1}, report.Summary)

	manifest.Documents[1].ExpectedDocumentType = "drifted_type"
	manifestPath = writeJSONFixture(t, directory, "manifest-drift.json", manifest)
	report, err = buildDryRunReport(context.Background(), dryRunOptions{
		Bundle: bundlePath, Manifest: manifestPath, Timeout: time.Minute,
	}, mapEnvironment(nil), http.DefaultClient)
	require.NoError(t, err)
	require.True(t, report.Blocked)
	require.False(t, report.ManifestValid)
	require.Contains(t, strings.Join(report.ManifestIssues, "\n"), "版本漂移")
}

func TestDryRunBlocksDuplicateContentInsideBundle(t *testing.T) {
	directory := t.TempDir()
	documents := []releaseDocument{
		{Title: "规则 A", SourceType: "text", SourceURI: "https://example.edu/a", DocumentType: "policy_a", Department: "教务处", Content: "相同正文"},
		{Title: "规则 B", SourceType: "text", SourceURI: "https://example.edu/b", DocumentType: "policy_b", Department: "教务处", Content: "相同正文"},
	}
	bundlePath, bundleBytes := writeBundleFixture(t, directory, documents)
	manifest, err := buildReleaseManifest("v0.6", bundlePath, "", documents, bundleBytes, time.Unix(0, 0))
	require.NoError(t, err)
	manifestPath := writeJSONFixture(t, directory, "manifest.json", manifest)

	report, err := buildDryRunReport(context.Background(), dryRunOptions{
		Bundle: bundlePath, Manifest: manifestPath, Timeout: time.Minute,
	}, mapEnvironment(nil), http.DefaultClient)
	require.NoError(t, err)
	require.True(t, report.Blocked)
	require.Equal(t, 2, report.Summary.Blocked)
	require.Contains(t, report.Actions[0].Reason, "重复内容 hash")
}

func TestLangChainInspectionChecksChunkerAndEmbeddingContract(t *testing.T) {
	document := releaseDocument{
		Title: "考试规定", SourceType: "text", SourceURI: "https://example.edu/exam",
		DocumentType: "school_exam_policy", Department: "教务处", EffectiveFrom: "2026-01-01", Content: "# 考试规定\n\n第一条 正文。",
	}
	invalidChunkHash := false
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/internal/rag/knowledge/chunk":
			var payload struct {
				DocumentID uint `json:"document_id"`
			}
			require.NoError(t, json.NewDecoder(request.Body).Decode(&payload))
			content := "第一条 正文。"
			hash := sha256.Sum256([]byte(content))
			contentHash := hex.EncodeToString(hash[:])
			if invalidChunkHash {
				contentHash = strings.Repeat("0", 64)
			}
			_ = json.NewEncoder(response).Encode(map[string]any{
				"document_id": payload.DocumentID, "chunking_version": defaultChunkingVersion,
				"chunks": []map[string]any{{
					"index": 0, "content": content, "content_hash": contentHash,
					"embedding_text": "考试规定 第一条 正文", "section_title": "考试规定", "source_locator": "第一条",
					"metadata": map[string]any{
						"document_id": payload.DocumentID, "section_title": "考试规定", "section_path": []string{"考试规定", "第一条"},
						"source_locator": "第一条", "document_type": "school_exam_policy", "department": "教务处",
						"version_status": "candidate", "effective_from": "2026-01-01", "effective_to": nil,
						"chunking_version": defaultChunkingVersion,
					},
				}},
			})
		case "/internal/rag/embed-batch":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"embeddings": [][]float32{make([]float32, defaultEmbeddingDimensions)},
				"model_name": defaultEmbeddingModelName, "model_version": defaultEmbeddingModelVersion,
				"dimensions": defaultEmbeddingDimensions,
			})
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()
	manifest := releaseManifest{
		ChunkingVersion: defaultChunkingVersion, EmbeddingModelName: defaultEmbeddingModelName,
		EmbeddingModelVersion: defaultEmbeddingModelVersion, EmbeddingDimensions: defaultEmbeddingDimensions,
	}
	result := inspectWithLangChain(context.Background(), []releaseDocument{document}, manifest, server.URL,
		mapEnvironment(map[string]string{"RAG_SERVICE_TOKEN": "test-token"}), server.Client())
	require.Equal(t, "passed", result.Status, result.Error)
	require.Equal(t, 1, result.DocumentsChecked)
	require.Equal(t, 1, result.ChunksChecked)

	invalidChunkHash = true
	result = inspectWithLangChain(context.Background(), []releaseDocument{document}, manifest, server.URL,
		mapEnvironment(map[string]string{"RAG_SERVICE_TOKEN": "test-token"}), server.Client())
	require.Equal(t, "failed", result.Status)
	require.Contains(t, result.Error, "hash 无效")
}

func writeBundleFixture(t *testing.T, directory string, documents []releaseDocument) (string, []byte) {
	t.Helper()
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	for _, document := range documents {
		require.NoError(t, encoder.Encode(document))
	}
	path := filepath.Join(directory, "bundle.jsonl")
	require.NoError(t, os.WriteFile(path, buffer.Bytes(), 0o600))
	return path, buffer.Bytes()
}

func writeJSONFixture(t *testing.T, directory, name string, value any) string {
	t.Helper()
	encoded, err := marshalIndented(value)
	require.NoError(t, err)
	path := filepath.Join(directory, name)
	require.NoError(t, os.WriteFile(path, encoded, 0o600))
	return path
}

func mapEnvironment(values map[string]string) environment {
	return func(name string) string { return values[name] }
}
