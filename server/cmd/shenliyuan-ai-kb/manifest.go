package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"shenliyuan/internal/models"
)

const (
	manifestSchemaVersion        = "sylu-ai-kb-release/v1"
	defaultKnowledgeBaseName     = "sylu-academic-policy"
	defaultKnowledgeVersion      = "v0.8"
	defaultKnowledgeBundle       = "SYLUlive_AI学生资助政策完整导入包_v0.8.jsonl"
	defaultKnowledgeManifest     = "release-manifest.v0.8.json"
	defaultChunkingVersion       = "langchain-chinese-policy-v1"
	defaultEmbeddingModelName    = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
	defaultEmbeddingModelVersion = "paraphrase-multilingual-minilm-l12-v2-384-v1"
	defaultEmbeddingDimensions   = 384
)

var documentIDPattern = regexp.MustCompile(`(?m)^doc_id=([^\r\n]+)$`)

type releaseDocument struct {
	Title          string `json:"title"`
	SourceType     string `json:"source_type"`
	SourceURI      string `json:"source_uri"`
	SourceFileName string `json:"source_file_name"`
	DocumentType   string `json:"document_type"`
	Department     string `json:"department"`
	EffectiveFrom  string `json:"effective_from"`
	EffectiveTo    string `json:"effective_to"`
	Content        string `json:"content"`
}

type manifestDocument struct {
	DocumentKey          string `json:"document_key"`
	Title                string `json:"title"`
	ContentHash          string `json:"content_hash"`
	ExpectedDocumentType string `json:"expected_document_type"`
	SourceType           string `json:"source_type"`
	SourceURI            string `json:"source_uri,omitempty"`
	SourceFileName       string `json:"source_file_name,omitempty"`
	Department           string `json:"department"`
	EffectiveFrom        string `json:"effective_from,omitempty"`
	EffectiveTo          string `json:"effective_to,omitempty"`
	Currentness          string `json:"currentness"`
}

type manifestUnresolvedItem struct {
	Code     string `json:"code"`
	Severity string `json:"severity"`
	Title    string `json:"title"`
	Detail   string `json:"detail"`
}

type releaseManifest struct {
	SchemaVersion         string                   `json:"schema_version"`
	KnowledgeBase         string                   `json:"knowledge_base"`
	Version               string                   `json:"version"`
	GeneratedAt           string                   `json:"generated_at"`
	BundleFile            string                   `json:"bundle_file"`
	BundleSHA256          string                   `json:"bundle_sha256"`
	DocumentCount         int                      `json:"document_count"`
	ChunkingVersion       string                   `json:"chunking_version"`
	EmbeddingModelName    string                   `json:"embedding_model_name"`
	EmbeddingModelVersion string                   `json:"embedding_model_version"`
	EmbeddingDimensions   int                      `json:"embedding_dimensions"`
	SupersedesVersions    []string                 `json:"supersedes_versions"`
	Documents             []manifestDocument       `json:"documents"`
	UnresolvedItems       []manifestUnresolvedItem `json:"unresolved_items"`
}

type pendingSourceFile struct {
	StillMissing []struct {
		Priority  string `json:"priority"`
		Title     string `json:"title"`
		WhyNeeded string `json:"why_needed"`
	} `json:"still_missing_official_full_text"`
}

func runManifest(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("manifest", flag.ContinueOnError)
	flags.SetOutput(stderr)
	bundle := flags.String("bundle", defaultKnowledgePath(defaultKnowledgeBundle), "JSONL 导入包")
	pending := flags.String("pending", "", "待补官方文件清单")
	version := flags.String("version", defaultKnowledgeVersion, "知识库版本")
	output := flags.String("output", "", "输出文件；留空时写标准输出")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "manifest 不接受位置参数")
		return 2
	}
	documents, bundleBytes, err := loadReleaseBundle(*bundle)
	if err != nil {
		fmt.Fprintf(stderr, "读取导入包失败：%v\n", err)
		return 1
	}
	manifest, err := buildReleaseManifest(*version, *bundle, *pending, documents, bundleBytes, time.Now())
	if err != nil {
		fmt.Fprintf(stderr, "生成版本清单失败：%v\n", err)
		return 1
	}
	encoded, err := marshalIndented(manifest)
	if err != nil {
		fmt.Fprintf(stderr, "编码版本清单失败：%v\n", err)
		return 1
	}
	if strings.TrimSpace(*output) == "" {
		_, _ = stdout.Write(encoded)
		return 0
	}
	if err := os.WriteFile(*output, encoded, 0o644); err != nil {
		fmt.Fprintf(stderr, "写入版本清单失败：%v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "已生成 %s（%d 份文档）\n", *output, len(documents))
	return 0
}

func loadReleaseBundle(path string) ([]releaseDocument, []byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 64<<10), 3<<20)
	documents := make([]releaseDocument, 0)
	for line := 1; scanner.Scan(); line++ {
		if len(bytes.TrimSpace(scanner.Bytes())) == 0 {
			continue
		}
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.DisallowUnknownFields()
		var document releaseDocument
		if err := decoder.Decode(&document); err != nil {
			return nil, nil, fmt.Errorf("第 %d 行 JSON 无效：%w", line, err)
		}
		if decoder.Decode(&struct{}{}) != io.EOF {
			return nil, nil, fmt.Errorf("第 %d 行包含多个 JSON 值", line)
		}
		documents = append(documents, document)
	}
	if err := scanner.Err(); err != nil {
		return nil, nil, err
	}
	if len(documents) == 0 {
		return nil, nil, errors.New("导入包没有文档")
	}
	return documents, raw, nil
}

func buildReleaseManifest(version, bundlePath, pendingPath string, documents []releaseDocument, bundleBytes []byte, now time.Time) (releaseManifest, error) {
	version = strings.TrimSpace(version)
	if version == "" {
		return releaseManifest{}, errors.New("版本不能为空")
	}
	bundleHash := sha256.Sum256(bundleBytes)
	manifest := releaseManifest{
		SchemaVersion: manifestSchemaVersion, KnowledgeBase: defaultKnowledgeBaseName, Version: version,
		GeneratedAt: now.UTC().Format(time.RFC3339), BundleFile: filepath.Base(bundlePath),
		BundleSHA256: hex.EncodeToString(bundleHash[:]), DocumentCount: len(documents),
		ChunkingVersion: defaultChunkingVersion, EmbeddingModelName: defaultEmbeddingModelName,
		EmbeddingModelVersion: defaultEmbeddingModelVersion, EmbeddingDimensions: defaultEmbeddingDimensions,
		SupersedesVersions: supersededKnowledgeVersions(version),
		Documents:          make([]manifestDocument, 0, len(documents)), UnresolvedItems: make([]manifestUnresolvedItem, 0),
	}
	for index, document := range documents {
		content := strings.TrimSpace(document.Content)
		hash := sha256.Sum256([]byte(content))
		key := extractDocumentKey(content)
		if key == "" {
			key = fmt.Sprintf("bundle-%03d", index+1)
		}
		manifest.Documents = append(manifest.Documents, manifestDocument{
			DocumentKey: key, Title: strings.TrimSpace(document.Title), ContentHash: hex.EncodeToString(hash[:]),
			ExpectedDocumentType: strings.TrimSpace(document.DocumentType), SourceType: strings.TrimSpace(document.SourceType),
			SourceURI: strings.TrimSpace(document.SourceURI), SourceFileName: strings.TrimSpace(document.SourceFileName),
			Department: strings.TrimSpace(document.Department), EffectiveFrom: strings.TrimSpace(document.EffectiveFrom),
			EffectiveTo: strings.TrimSpace(document.EffectiveTo), Currentness: releaseDocumentCurrentness(document),
		})
	}
	if strings.TrimSpace(pendingPath) != "" {
		raw, err := os.ReadFile(pendingPath)
		if err != nil {
			return releaseManifest{}, err
		}
		var pending pendingSourceFile
		if err := json.Unmarshal(raw, &pending); err != nil {
			return releaseManifest{}, err
		}
		for _, item := range pending.StillMissing {
			code := "missing_official_source"
			if strings.Contains(item.Title, "二次考试") || strings.Contains(item.Title, "二考") {
				code = "current_second_exam_policy_unverified"
			}
			manifest.UnresolvedItems = append(manifest.UnresolvedItems, manifestUnresolvedItem{
				Code: code, Severity: "requires_review", Title: item.Title,
				Detail: strings.TrimSpace(item.Priority + "：" + item.WhyNeeded),
			})
		}
	}
	return manifest, nil
}

func loadReleaseManifest(path string) (releaseManifest, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return releaseManifest{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var manifest releaseManifest
	if err := decoder.Decode(&manifest); err != nil {
		return releaseManifest{}, err
	}
	if manifest.SchemaVersion != manifestSchemaVersion || manifest.KnowledgeBase == "" || manifest.Version == "" {
		return releaseManifest{}, errors.New("清单 schema 或版本标识无效")
	}
	return manifest, nil
}

func (document releaseDocument) toModel(id uint) (models.AIKnowledgeDocument, error) {
	content := strings.TrimSpace(document.Content)
	hash := sha256.Sum256([]byte(content))
	effectiveFrom, err := parseReleaseDate(document.EffectiveFrom)
	if err != nil {
		return models.AIKnowledgeDocument{}, fmt.Errorf("effective_from: %w", err)
	}
	effectiveTo, err := parseReleaseDate(document.EffectiveTo)
	if err != nil {
		return models.AIKnowledgeDocument{}, fmt.Errorf("effective_to: %w", err)
	}
	return models.AIKnowledgeDocument{
		ID: id, Title: strings.TrimSpace(document.Title), SourceType: strings.TrimSpace(document.SourceType),
		SourceURI: strings.TrimSpace(document.SourceURI), SourceFileName: strings.TrimSpace(document.SourceFileName),
		DocumentType: strings.TrimSpace(document.DocumentType), Department: strings.TrimSpace(document.Department),
		EffectiveFrom: effectiveFrom, EffectiveTo: effectiveTo, Content: content,
		ContentHash: hex.EncodeToString(hash[:]), Status: models.KnowledgeStatusDraft,
	}, nil
}

func parseReleaseDate(value string) (*time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, nil
	}
	if parsed, err := time.Parse(time.RFC3339, value); err == nil {
		return &parsed, nil
	}
	location := time.FixedZone("Asia/Shanghai", 8*60*60)
	parsed, err := time.ParseInLocation("2006-01-02", value, location)
	if err != nil {
		return nil, err
	}
	return &parsed, nil
}

func extractDocumentKey(content string) string {
	match := documentIDPattern.FindStringSubmatch(content)
	if len(match) != 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func releaseDocumentCurrentness(document releaseDocument) string {
	identity := strings.ToLower(document.SourceType + " " + document.DocumentType)
	if strings.Contains(identity, "historical") {
		return "historical"
	}
	if strings.Contains(identity, "curated") || strings.Contains(identity, "reasoning_card") {
		return "mixed"
	}
	return "current"
}

func defaultKnowledgePath(fileName string) string {
	candidates := []string{
		filepath.Join("..", "knowledge-base", "sylu-academic-policy", defaultKnowledgeVersion, fileName),
		filepath.Join("knowledge-base", "sylu-academic-policy", defaultKnowledgeVersion, fileName),
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}

func defaultManifestPath() string {
	return defaultKnowledgePath(defaultKnowledgeManifest)
}

func supersededKnowledgeVersions(version string) []string {
	if strings.TrimSpace(version) == "v0.8" {
		return []string{"v0.7"}
	}
	return []string{"v0.1", "v0.2", "v0.3", "v0.4", "v0.5"}
}

func marshalIndented(value any) ([]byte, error) {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
