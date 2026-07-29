package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type dryRunOptions struct {
	Bundle      string
	Manifest    string
	Inventory   string
	Report      string
	BaseURL     string
	RAGBaseURL  string
	CheckRemote bool
	CheckRAG    bool
	RequireRAG  bool
	Timeout     time.Duration
}

type dryRunAction struct {
	DocumentKey          string                              `json:"document_key"`
	Title                string                              `json:"title"`
	ContentHash          string                              `json:"content_hash"`
	DocumentType         string                              `json:"document_type"`
	Currentness          string                              `json:"currentness"`
	Decision             string                              `json:"decision"`
	Reason               string                              `json:"reason"`
	RemoteDocumentID     uint                                `json:"remote_document_id,omitempty"`
	SupersedesDocumentID uint                                `json:"supersedes_document_id,omitempty"`
	Issues               []services.KnowledgeInspectionIssue `json:"issues"`
	sourceURI            string
	sourceFileName       string
}

type dryRunSummary struct {
	Add       int `json:"add"`
	Supersede int `json:"supersede"`
	Skip      int `json:"skip"`
	Blocked   int `json:"blocked"`
}

type ragInspectionResult struct {
	Status                string `json:"status"`
	DocumentsChecked      int    `json:"documents_checked"`
	ChunksChecked         int    `json:"chunks_checked"`
	ChunkingVersion       string `json:"chunking_version,omitempty"`
	EmbeddingModelName    string `json:"embedding_model_name,omitempty"`
	EmbeddingModelVersion string `json:"embedding_model_version,omitempty"`
	EmbeddingDimensions   int    `json:"embedding_dimensions,omitempty"`
	Error                 string `json:"error,omitempty"`
}

type dryRunReport struct {
	SchemaVersion       string                   `json:"schema_version"`
	KnowledgeBase       string                   `json:"knowledge_base"`
	Version             string                   `json:"version"`
	Mode                string                   `json:"mode"`
	WritesPerformed     bool                     `json:"writes_performed"`
	RemoteComparison    string                   `json:"remote_comparison"`
	ManifestValid       bool                     `json:"manifest_valid"`
	ManifestIssues      []string                 `json:"manifest_issues"`
	UnresolvedItems     []manifestUnresolvedItem `json:"unresolved_items"`
	Actions             []dryRunAction           `json:"actions"`
	Summary             dryRunSummary            `json:"summary"`
	LangChainInspection ragInspectionResult      `json:"langchain_inspection"`
	Blocked             bool                     `json:"blocked"`
}

func runDryRun(args []string, getenv environment, stdout, stderr io.Writer, client *http.Client, forceRAG bool) int {
	options, ok := parseDryRunOptions(args, getenv, stderr, forceRAG)
	if !ok {
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), options.Timeout)
	defer cancel()
	report, err := buildDryRunReport(ctx, options, getenv, client)
	if err != nil {
		fmt.Fprintf(stderr, "dry-run 失败：%v\n", err)
		return 1
	}
	encoded, err := marshalIndented(report)
	if err != nil {
		fmt.Fprintf(stderr, "编码 dry-run 报告失败：%v\n", err)
		return 1
	}
	if strings.TrimSpace(options.Report) != "" {
		if err := os.WriteFile(options.Report, encoded, 0o644); err != nil {
			fmt.Fprintf(stderr, "写入 dry-run 报告失败：%v\n", err)
			return 1
		}
	}
	_, _ = stdout.Write(encoded)
	if report.Blocked {
		return 1
	}
	return 0
}

func parseDryRunOptions(args []string, getenv environment, stderr io.Writer, forceRAG bool) (dryRunOptions, bool) {
	flags := flag.NewFlagSet("dry-run", flag.ContinueOnError)
	flags.SetOutput(stderr)
	options := dryRunOptions{}
	flags.StringVar(&options.Bundle, "bundle", defaultKnowledgePath(defaultKnowledgeBundle), "JSONL 导入包")
	flags.StringVar(&options.Manifest, "manifest", defaultManifestPath(), "版本清单")
	flags.StringVar(&options.Inventory, "inventory", "", "离线数据库文档清单 JSON")
	flags.StringVar(&options.Report, "report", "", "同时写入报告文件")
	flags.StringVar(&options.BaseURL, "base-url", envOrDefault(getenv, "SHENLIYUAN_API_BASE_URL", "http://127.0.0.1:8080"), "服务端 API 地址")
	flags.StringVar(&options.RAGBaseURL, "rag-base-url", envOrDefault(getenv, "RAG_SERVICE_URL", "http://127.0.0.1:18001"), "Python RAG 服务地址")
	flags.BoolVar(&options.CheckRemote, "check-remote", false, "使用管理员 API 只读比对当前文档")
	flags.BoolVar(&options.CheckRAG, "check-rag", forceRAG, "执行 LangChain 分块与 embedding 检查")
	flags.BoolVar(&options.RequireRAG, "require-rag", forceRAG, "LangChain 检查缺失或失败时阻塞")
	flags.DurationVar(&options.Timeout, "timeout", 10*time.Minute, "检查总超时")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return dryRunOptions{}, false
	}
	return options, true
}

func buildDryRunReport(ctx context.Context, options dryRunOptions, getenv environment, client *http.Client) (dryRunReport, error) {
	documents, bundleBytes, err := loadReleaseBundle(options.Bundle)
	if err != nil {
		return dryRunReport{}, err
	}
	manifest, err := loadReleaseManifest(options.Manifest)
	if err != nil {
		return dryRunReport{}, fmt.Errorf("读取版本清单：%w", err)
	}
	report := dryRunReport{
		SchemaVersion: "sylu-ai-kb-dry-run/v1", KnowledgeBase: manifest.KnowledgeBase,
		Version: manifest.Version, Mode: "dry-run", WritesPerformed: false,
		RemoteComparison: "not_run", ManifestValid: true, ManifestIssues: make([]string, 0),
		UnresolvedItems: append([]manifestUnresolvedItem(nil), manifest.UnresolvedItems...),
		Actions:         make([]dryRunAction, len(documents)), LangChainInspection: ragInspectionResult{Status: "not_run"},
	}
	report.ManifestIssues = validateManifest(manifest, documents, bundleBytes)
	report.ManifestValid = len(report.ManifestIssues) == 0

	modelsByIndex := make([]models.AIKnowledgeDocument, len(documents))
	for index, document := range documents {
		model, err := document.toModel(uint(index + 1))
		if err != nil {
			return dryRunReport{}, fmt.Errorf("文档 %d 日期无效：%w", index+1, err)
		}
		modelsByIndex[index] = model
		inspection, err := services.InspectKnowledgeDocument(ctx, nil, model)
		if err != nil {
			return dryRunReport{}, err
		}
		key := fmt.Sprintf("bundle-%03d", index+1)
		currentness := releaseDocumentCurrentness(document)
		if index < len(manifest.Documents) {
			key = manifest.Documents[index].DocumentKey
			currentness = manifest.Documents[index].Currentness
		}
		action := dryRunAction{
			DocumentKey: key, Title: model.Title, ContentHash: model.ContentHash,
			DocumentType: model.DocumentType, Currentness: currentness,
			Decision: "add", Reason: "远端清单未比对，按新增候选报告", Issues: inspection.Issues,
			sourceURI: model.SourceURI, sourceFileName: model.SourceFileName,
		}
		if inspection.HasBlockingIssues() {
			action.Decision = "blocked"
			action.Reason = "存在阻塞治理问题"
		}
		report.Actions[index] = action
	}
	markBundleDuplicatesAndConflicts(report.Actions)
	if !report.ManifestValid {
		for index := range report.Actions {
			report.Actions[index].Decision = "blocked"
			report.Actions[index].Reason = "版本清单与导入包发生漂移"
		}
	}

	var inventory []models.AIKnowledgeDocument
	switch {
	case strings.TrimSpace(options.Inventory) != "":
		inventory, err = loadKnowledgeInventory(options.Inventory)
		if err != nil {
			return dryRunReport{}, fmt.Errorf("读取离线清单：%w", err)
		}
		report.RemoteComparison = "offline_inventory"
	case options.CheckRemote:
		token := strings.TrimSpace(getenv("SHENLIYUAN_ADMIN_JWT"))
		if token == "" {
			return dryRunReport{}, errors.New("--check-remote 需要 SHENLIYUAN_ADMIN_JWT；未发出远端请求")
		}
		inventory, err = fetchKnowledgeInventory(ctx, client, options.BaseURL, token)
		if err != nil {
			return dryRunReport{}, err
		}
		report.RemoteComparison = "admin_api_read_only"
	}
	if inventory != nil {
		applyInventory(report.Actions, inventory)
	}

	if options.CheckRAG {
		report.LangChainInspection = inspectWithLangChain(ctx, documents, manifest, options.RAGBaseURL, getenv, client)
	} else if options.RequireRAG {
		report.LangChainInspection = ragInspectionResult{Status: "failed", Error: "LangChain 检查被要求但未启用"}
	}
	if options.RequireRAG && report.LangChainInspection.Status != "passed" {
		for index := range report.Actions {
			if report.Actions[index].Decision != "skip" {
				report.Actions[index].Decision = "blocked"
				report.Actions[index].Reason = "LangChain 分块或向量化检查未通过"
			}
		}
	}
	report.Summary = summarizeActions(report.Actions)
	report.Blocked = report.Summary.Blocked > 0 || !report.ManifestValid || (options.RequireRAG && report.LangChainInspection.Status != "passed")
	return report, nil
}

func validateManifest(manifest releaseManifest, documents []releaseDocument, bundleBytes []byte) []string {
	issues := make([]string, 0)
	hash := sha256.Sum256(bundleBytes)
	if !strings.EqualFold(manifest.BundleSHA256, hex.EncodeToString(hash[:])) {
		issues = append(issues, "bundle_sha256 与导入包不一致")
	}
	if manifest.DocumentCount != len(documents) || len(manifest.Documents) != len(documents) {
		issues = append(issues, "document_count 与导入包不一致")
	}
	if manifest.ChunkingVersion == "" || manifest.EmbeddingModelVersion == "" || manifest.EmbeddingDimensions <= 0 {
		issues = append(issues, "LangChain 分块或 embedding 版本契约缺失")
	}
	limit := len(documents)
	if len(manifest.Documents) < limit {
		limit = len(manifest.Documents)
	}
	for index := 0; index < limit; index++ {
		model, err := documents[index].toModel(uint(index + 1))
		if err != nil {
			issues = append(issues, fmt.Sprintf("documents[%d] 日期无效", index))
			continue
		}
		expected := manifest.Documents[index]
		if expected.Title != model.Title || expected.ContentHash != model.ContentHash ||
			expected.ExpectedDocumentType != model.DocumentType || expected.SourceType != model.SourceType ||
			expected.SourceURI != model.SourceURI || expected.SourceFileName != model.SourceFileName ||
			expected.Department != model.Department || expected.EffectiveFrom != strings.TrimSpace(documents[index].EffectiveFrom) ||
			expected.EffectiveTo != strings.TrimSpace(documents[index].EffectiveTo) ||
			expected.Currentness != releaseDocumentCurrentness(documents[index]) {
			issues = append(issues, fmt.Sprintf("documents[%d] 元数据或内容发生版本漂移", index))
		}
	}
	return issues
}

func markBundleDuplicatesAndConflicts(actions []dryRunAction) {
	byHash := make(map[string][]int)
	byKey := make(map[string][]int)
	byScope := make(map[string][]int)
	for index, action := range actions {
		byHash[action.ContentHash] = append(byHash[action.ContentHash], index)
		byKey[action.DocumentKey] = append(byKey[action.DocumentKey], index)
		if scope := actionVersionScope(action); scope != "" {
			byScope[scope] = append(byScope[scope], index)
		}
	}
	for _, indexes := range byHash {
		if len(indexes) > 1 {
			blockActions(actions, indexes, "导入包包含重复内容 hash")
		}
	}
	for _, indexes := range byKey {
		if len(indexes) > 1 && distinctActionHashes(actions, indexes) > 1 {
			blockActions(actions, indexes, "同一 document_key 存在冲突内容")
		}
	}
	for _, indexes := range byScope {
		if len(indexes) > 1 && distinctActionHashes(actions, indexes) > 1 {
			blockActions(actions, indexes, "同一 document_type 在候选包中存在冲突版本")
		}
	}
}

func actionVersionScope(action dryRunAction) string {
	documentType := strings.ToLower(strings.TrimSpace(action.DocumentType))
	if documentType == "" {
		return ""
	}
	if strings.Contains(documentType, "profile") || strings.Contains(documentType, "catalog") {
		if action.sourceURI != "" {
			return documentType + "|uri:" + strings.ToLower(action.sourceURI)
		}
		if action.sourceFileName != "" {
			return documentType + "|file:" + strings.ToLower(action.sourceFileName)
		}
		return documentType + "|key:" + action.DocumentKey
	}
	return documentType
}

func blockActions(actions []dryRunAction, indexes []int, reason string) {
	for _, index := range indexes {
		actions[index].Decision = "blocked"
		actions[index].Reason = reason
	}
}

func distinctActionHashes(actions []dryRunAction, indexes []int) int {
	hashes := make(map[string]struct{})
	for _, index := range indexes {
		hashes[actions[index].ContentHash] = struct{}{}
	}
	return len(hashes)
}

func applyInventory(actions []dryRunAction, inventory []models.AIKnowledgeDocument) {
	for index := range actions {
		if actions[index].Decision == "blocked" {
			continue
		}
		exact := make([]models.AIKnowledgeDocument, 0)
		conflicts := make([]models.AIKnowledgeDocument, 0)
		for _, remote := range inventory {
			if remote.Status == models.KnowledgeStatusRevoked || remote.Status == models.KnowledgeStatusSuperseded {
				continue
			}
			if strings.EqualFold(remote.ContentHash, actions[index].ContentHash) {
				exact = append(exact, remote)
			} else if remote.Status == models.KnowledgeStatusPublished && inventoryVersionScopeMatches(actions[index], remote) {
				conflicts = append(conflicts, remote)
			}
		}
		publishedExact := make([]models.AIKnowledgeDocument, 0, len(exact))
		for _, remote := range exact {
			if remote.Status == models.KnowledgeStatusPublished {
				publishedExact = append(publishedExact, remote)
			}
		}
		switch {
		case len(exact) > 1 || len(publishedExact) > 1:
			actions[index].Decision = "blocked"
			actions[index].Reason = "远端存在多个相同 hash 的活动文档"
		case len(publishedExact) == 1:
			actions[index].Decision = "skip"
			actions[index].Reason = "远端已发布相同内容 hash"
			actions[index].RemoteDocumentID = publishedExact[0].ID
		case len(exact) == 1:
			actions[index].Decision = "add"
			actions[index].Reason = "复用远端相同 hash 的未发布候选"
			actions[index].RemoteDocumentID = exact[0].ID
		case len(conflicts) > 1:
			actions[index].Decision = "blocked"
			actions[index].Reason = "远端存在多个同类型已发布冲突版本"
		case len(conflicts) == 1:
			actions[index].Decision = "supersede"
			actions[index].Reason = "将原子替代同类型已发布版本"
			actions[index].SupersedesDocumentID = conflicts[0].ID
		default:
			actions[index].Decision = "add"
			actions[index].Reason = "远端没有相同 hash 或冲突版本"
		}
	}
}

func inventoryVersionScopeMatches(action dryRunAction, remote models.AIKnowledgeDocument) bool {
	if remote.DocumentType != action.DocumentType {
		return false
	}
	identity := strings.ToLower(action.DocumentType)
	if !strings.Contains(identity, "profile") && !strings.Contains(identity, "catalog") {
		return true
	}
	if action.sourceURI != "" && remote.SourceURI != "" && strings.EqualFold(action.sourceURI, remote.SourceURI) {
		return true
	}
	return action.sourceFileName != "" && remote.SourceFileName != "" && strings.EqualFold(action.sourceFileName, remote.SourceFileName)
}

func inspectWithLangChain(ctx context.Context, documents []releaseDocument, manifest releaseManifest, baseURL string, getenv environment, client *http.Client) ragInspectionResult {
	token := strings.TrimSpace(getenv("RAG_SERVICE_TOKEN"))
	if token == "" {
		return ragInspectionResult{Status: "failed", Error: "缺少 RAG_SERVICE_TOKEN"}
	}
	if client == nil {
		client = &http.Client{}
	}
	rag, err := ai.NewRAGClient(baseURL, token, client)
	if err != nil {
		return ragInspectionResult{Status: "failed", Error: err.Error()}
	}
	result := ragInspectionResult{
		Status: "passed", ChunkingVersion: manifest.ChunkingVersion,
		EmbeddingModelName: manifest.EmbeddingModelName, EmbeddingModelVersion: manifest.EmbeddingModelVersion,
		EmbeddingDimensions: manifest.EmbeddingDimensions,
	}
	for index, document := range documents {
		model, err := document.toModel(uint(index + 1))
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			return result
		}
		chunked, err := rag.ChunkKnowledgeDocument(ctx, ai.KnowledgeChunkRequest{
			DocumentID: model.ID, Title: model.Title, Content: model.Content,
			SourceLocator: firstNonEmpty(model.SourceURI, model.SourceFileName), DocumentType: model.DocumentType,
			Department: model.Department, VersionStatus: "candidate", EffectiveFrom: model.EffectiveFrom,
			EffectiveTo: model.EffectiveTo, ChunkSize: 700, ChunkOverlap: 80,
		})
		if err != nil {
			result.Status, result.Error = "failed", fmt.Sprintf("文档 %d 分块失败：%v", index+1, err)
			return result
		}
		if chunked.ChunkingVersion != manifest.ChunkingVersion {
			result.Status, result.Error = "failed", "分块器版本漂移"
			return result
		}
		for _, chunk := range chunked.Chunks {
			hash := sha256.Sum256([]byte(chunk.Content))
			if !strings.EqualFold(chunk.ContentHash, hex.EncodeToString(hash[:])) {
				result.Status, result.Error = "failed", fmt.Sprintf("文档 %d 分块内容 hash 无效", index+1)
				return result
			}
		}
		for start := 0; start < len(chunked.Chunks); start += 32 {
			end := start + 32
			if end > len(chunked.Chunks) {
				end = len(chunked.Chunks)
			}
			texts := make([]string, end-start)
			for offset := range texts {
				texts[offset] = chunked.Chunks[start+offset].EmbeddingText
			}
			vectors, modelName, modelVersion, dimensions, err := rag.EmbedBatch(ctx, texts)
			if err != nil {
				result.Status, result.Error = "failed", fmt.Sprintf("文档 %d 向量化失败：%v", index+1, err)
				return result
			}
			if len(vectors) != len(texts) || modelName != manifest.EmbeddingModelName ||
				modelVersion != manifest.EmbeddingModelVersion || dimensions != manifest.EmbeddingDimensions {
				result.Status, result.Error = "failed", "embedding 模型、版本或维度发生漂移"
				return result
			}
		}
		result.DocumentsChecked++
		result.ChunksChecked += len(chunked.Chunks)
	}
	return result
}

func loadKnowledgeInventory(path string) ([]models.AIKnowledgeDocument, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var wrapper struct {
		Documents []models.AIKnowledgeDocument `json:"documents"`
	}
	if err := json.Unmarshal(raw, &wrapper); err == nil && wrapper.Documents != nil {
		return wrapper.Documents, nil
	}
	var documents []models.AIKnowledgeDocument
	if err := json.Unmarshal(raw, &documents); err != nil {
		return nil, err
	}
	return documents, nil
}

func summarizeActions(actions []dryRunAction) dryRunSummary {
	var summary dryRunSummary
	for _, action := range actions {
		switch action.Decision {
		case "add":
			summary.Add++
		case "supersede":
			summary.Supersede++
		case "skip":
			summary.Skip++
		default:
			summary.Blocked++
		}
	}
	return summary
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return "candidate"
}

func envOrDefault(getenv environment, name, fallback string) string {
	if value := strings.TrimSpace(getenv(name)); value != "" {
		return value
	}
	return fallback
}

// 保持排序函数在该文件内，测试构造清单时可获得稳定输出。
func sortedDocumentIDs(documents []models.AIKnowledgeDocument) []uint {
	ids := make([]uint, len(documents))
	for index, document := range documents {
		ids[index] = document.ID
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}
