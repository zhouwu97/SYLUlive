package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type knowledgeReleaseAPIItem struct {
	DocumentID           uint `json:"document_id"`
	SupersedesDocumentID uint `json:"supersedes_document_id,omitempty"`
}

type releaseRecordItem struct {
	DocumentKey          string `json:"document_key"`
	DocumentID           uint   `json:"document_id"`
	SupersedesDocumentID uint   `json:"supersedes_document_id,omitempty"`
	ContentHash          string `json:"content_hash"`
	Status               string `json:"status"`
	Change               string `json:"change"`
}

type releaseRecord struct {
	SchemaVersion   string              `json:"schema_version"`
	KnowledgeBase   string              `json:"knowledge_base"`
	Version         string              `json:"version"`
	CompletedAt     string              `json:"completed_at"`
	WritesPerformed bool                `json:"writes_performed"`
	AtomicPublish   bool                `json:"atomic_publish"`
	Items           []releaseRecordItem `json:"items"`
}

func runRelease(args []string, getenv environment, stdout, stderr io.Writer, client *http.Client) int {
	flags := flag.NewFlagSet("release", flag.ContinueOnError)
	flags.SetOutput(stderr)
	bundle := flags.String("bundle", defaultKnowledgePath(defaultKnowledgeBundle), "JSONL 导入包")
	manifestPath := flags.String("manifest", defaultManifestPath(), "版本清单")
	baseURL := flags.String("base-url", envOrDefault(getenv, "SHENLIYUAN_API_BASE_URL", "http://127.0.0.1:8080"), "服务端 API 地址")
	ragBaseURL := flags.String("rag-base-url", envOrDefault(getenv, "RAG_SERVICE_URL", "http://127.0.0.1:18001"), "Python RAG 服务地址")
	agentQualityReport := flags.String("agent-quality-report", "", "A3 Agent 质量门禁报告（发布必需，须为 staging/online）")
	reportPath := flags.String("report", "", "必须新建的发布与回滚记录文件")
	execute := flags.Bool("execute", false, "允许发出写请求")
	confirm := flags.String("confirm", "", "精确确认短语 RELEASE:<version>")
	timeout := flags.Duration("timeout", 20*time.Minute, "整次发布超时")
	pollInterval := flags.Duration("poll-interval", 2*time.Second, "索引状态轮询间隔")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return 2
	}
	manifest, err := loadReleaseManifest(*manifestPath)
	if err != nil {
		fmt.Fprintf(stderr, "读取版本清单失败：%v\n", err)
		return 1
	}
	required := "RELEASE:" + manifest.Version
	if !*execute {
		fmt.Fprintf(stdout, "dry-run：未发出写请求。先运行 dry-run/check；确认后使用 --execute --confirm %q\n", required)
		return 0
	}
	token, ok := authorizeMutation(getenv, strings.TrimSpace(*confirm), required, stderr)
	if !ok {
		return 2
	}
	if strings.TrimSpace(getenv("RAG_SERVICE_TOKEN")) == "" {
		fmt.Fprintln(stderr, "缺少 RAG_SERVICE_TOKEN，无法验证 LangChain 分块与向量化。未发出写请求。")
		return 2
	}
	if strings.TrimSpace(*reportPath) == "" {
		fmt.Fprintln(stderr, "执行发布必须提供新的 --report 路径，以确保发布后可回滚。未发出写请求。")
		return 2
	}
	if strings.TrimSpace(*agentQualityReport) == "" {
		fmt.Fprintln(stderr, "执行 Agent 知识发布必须提供 --agent-quality-report；未发出写请求。")
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	options := dryRunOptions{
		Bundle: *bundle, Manifest: *manifestPath, BaseURL: *baseURL, RAGBaseURL: *ragBaseURL,
		CheckRemote: true, CheckRAG: true, RequireRAG: true, Timeout: *timeout,
		AgentQualityReport: *agentQualityReport, RequireAgentQuality: true,
	}
	dryRun, err := buildDryRunReport(ctx, options, getenv, client)
	if err != nil {
		fmt.Fprintf(stderr, "发布前 dry-run 失败：%v\n", err)
		return 1
	}
	if dryRun.Blocked {
		encoded, _ := marshalIndented(dryRun)
		_, _ = stdout.Write(encoded)
		fmt.Fprintln(stderr, "发布前检查存在阻塞项。未发出写请求。")
		return 1
	}
	documents, _, err := loadReleaseBundle(*bundle)
	if err != nil {
		fmt.Fprintf(stderr, "读取导入包失败：%v\n", err)
		return 1
	}
	api := newKnowledgeAPI(*baseURL, token, client)
	record := releaseRecord{
		SchemaVersion: "sylu-ai-kb-release-record/v1", KnowledgeBase: manifest.KnowledgeBase,
		Version: manifest.Version, WritesPerformed: false, AtomicPublish: false,
		Items: make([]releaseRecordItem, 0, len(documents)),
	}
	if err := initializeReleaseRecord(*reportPath, record); err != nil {
		fmt.Fprintf(stderr, "初始化发布记录失败：%v。未发出写请求。\n", err)
		return 1
	}
	batchItems := make([]knowledgeReleaseAPIItem, 0, len(documents))
	for index, action := range dryRun.Actions {
		if action.Decision == "skip" {
			record.Items = append(record.Items, releaseRecordItem{
				DocumentKey: action.DocumentKey, DocumentID: action.RemoteDocumentID,
				ContentHash: action.ContentHash, Status: "already_published", Change: "unchanged",
			})
			continue
		}
		documentID := action.RemoteDocumentID
		if documentID == 0 {
			created, err := api.importDocument(ctx, documents[index])
			if err != nil {
				fmt.Fprintf(stderr, "导入 %s 失败：%v；旧发布版本保持不变。\n", action.DocumentKey, err)
				return 1
			}
			documentID = created.ID
			record.WritesPerformed = true
		}
		ready, err := ensureInspectedDocument(ctx, api, documentID, manifest, *pollInterval)
		if err != nil {
			fmt.Fprintf(stderr, "检查 %s 失败：%v；旧发布版本保持不变。\n", action.DocumentKey, err)
			return 1
		}
		if !strings.EqualFold(ready.ContentHash, action.ContentHash) {
			fmt.Fprintf(stderr, "%s 的远端内容 hash 漂移；旧发布版本保持不变。\n", action.DocumentKey)
			return 1
		}
		batchItems = append(batchItems, knowledgeReleaseAPIItem{
			DocumentID: documentID, SupersedesDocumentID: action.SupersedesDocumentID,
		})
		record.Items = append(record.Items, releaseRecordItem{
			DocumentKey: action.DocumentKey, DocumentID: documentID,
			SupersedesDocumentID: action.SupersedesDocumentID, ContentHash: action.ContentHash,
			Status: "prepared", Change: releaseChange(action),
		})
	}
	if err := writeReleaseRecord(*reportPath, record); err != nil {
		fmt.Fprintf(stderr, "写入发布前回滚记录失败：%v；未执行原子发布。\n", err)
		return 1
	}
	if len(batchItems) > 0 {
		var response map[string]any
		if err := api.release(ctx, manifest.Version, batchItems, &response); err != nil {
			fmt.Fprintf(stderr, "原子发布失败：%v；旧发布版本保持不变。\n", err)
			return 1
		}
		record.WritesPerformed = true
	}
	record.AtomicPublish = true
	for index := range record.Items {
		if record.Items[index].Change != "unchanged" {
			record.Items[index].Status = "publish_api_succeeded"
		}
	}
	if err := writeReleaseRecord(*reportPath, record); err != nil {
		fmt.Fprintf(stderr, "发布已完成但更新回滚记录失败：%v；请使用 %s 中的候选 ID 立即核验。\n", err, *reportPath)
		return 1
	}
	for index := range record.Items {
		document, err := api.readDocument(ctx, record.Items[index].DocumentID)
		if err != nil || document.Status != models.KnowledgeStatusPublished {
			fmt.Fprintf(stderr, "发布后 smoke-test 失败：document_id=%d\n", record.Items[index].DocumentID)
			return 1
		}
		record.Items[index].Status = models.KnowledgeStatusPublished
	}
	record.CompletedAt = time.Now().UTC().Format(time.RFC3339)
	encoded, _ := marshalIndented(record)
	if err := os.WriteFile(*reportPath, encoded, 0o600); err != nil {
		fmt.Fprintf(stderr, "发布与 smoke-test 已完成，但更新发布记录失败：%v；原记录仍可用于回滚。\n", err)
		return 1
	}
	_, _ = stdout.Write(encoded)
	return 0
}

func initializeReleaseRecord(path string, record releaseRecord) error {
	encoded, err := marshalIndented(record)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("记录路径必须不存在且可写：%w", err)
	}
	if _, err := file.Write(encoded); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func writeReleaseRecord(path string, record releaseRecord) error {
	encoded, err := marshalIndented(record)
	if err != nil {
		return err
	}
	return os.WriteFile(path, encoded, 0o600)
}

func releaseChange(action dryRunAction) string {
	if action.SupersedesDocumentID != 0 {
		return "superseded"
	}
	return "published"
}

type knowledgeRollbackAPIItem struct {
	DocumentID        uint `json:"document_id"`
	RestoreDocumentID uint `json:"restore_document_id,omitempty"`
}

func runRollback(args []string, getenv environment, stdout, stderr io.Writer, client *http.Client) int {
	flags := flag.NewFlagSet("rollback", flag.ContinueOnError)
	flags.SetOutput(stderr)
	recordPath := flags.String("record", "", "release 命令生成的发布记录")
	baseURL := flags.String("base-url", envOrDefault(getenv, "SHENLIYUAN_API_BASE_URL", "http://127.0.0.1:8080"), "服务端 API 地址")
	execute := flags.Bool("execute", false, "允许发出写请求")
	confirm := flags.String("confirm", "", "精确确认短语 ROLLBACK:<version>")
	timeout := flags.Duration("timeout", 2*time.Minute, "回滚超时")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || strings.TrimSpace(*recordPath) == "" {
		return 2
	}
	raw, err := os.ReadFile(*recordPath)
	if err != nil {
		fmt.Fprintf(stderr, "读取发布记录失败：%v\n", err)
		return 1
	}
	var record releaseRecord
	if err := json.Unmarshal(raw, &record); err != nil || record.SchemaVersion != "sylu-ai-kb-release-record/v1" || record.Version == "" {
		fmt.Fprintln(stderr, "发布记录格式无效")
		return 1
	}
	required := "ROLLBACK:" + record.Version
	if !*execute {
		fmt.Fprintf(stdout, "dry-run：将回滚 %s；未发出写请求。确认后使用 --execute --confirm %q\n", record.Version, required)
		return 0
	}
	token, ok := authorizeMutation(getenv, strings.TrimSpace(*confirm), required, stderr)
	if !ok {
		return 2
	}
	items := make([]knowledgeRollbackAPIItem, 0, len(record.Items))
	for _, item := range record.Items {
		if item.Change == "unchanged" {
			continue
		}
		rollback := knowledgeRollbackAPIItem{DocumentID: item.DocumentID}
		if item.Change == "superseded" {
			rollback.RestoreDocumentID = item.SupersedesDocumentID
		}
		items = append(items, rollback)
	}
	if len(items) == 0 {
		fmt.Fprintln(stdout, "发布记录没有需要回滚的变更。")
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	var response map[string]any
	if err := newKnowledgeAPI(*baseURL, token, client).rollback(ctx, record.Version, items, &response); err != nil {
		fmt.Fprintf(stderr, "回滚失败：%v\n", err)
		return 1
	}
	encoded, _ := marshalIndented(response)
	_, _ = stdout.Write(encoded)
	return 0
}

func ensureInspectedDocument(ctx context.Context, api *knowledgeAPI, documentID uint, manifest releaseManifest, pollInterval time.Duration) (models.AIKnowledgeDocument, error) {
	document, err := api.readDocument(ctx, documentID)
	if err != nil {
		return models.AIKnowledgeDocument{}, err
	}
	if document.Status != models.KnowledgeStatusInspected {
		var response map[string]any
		if err := api.action(ctx, "inspect", documentID, 0, &response); err != nil {
			return models.AIKnowledgeDocument{}, err
		}
	}
	if pollInterval < 100*time.Millisecond {
		pollInterval = 100 * time.Millisecond
	}
	for {
		document, err = api.readDocument(ctx, documentID)
		if err != nil {
			return models.AIKnowledgeDocument{}, err
		}
		switch document.Status {
		case models.KnowledgeStatusInspected:
			if err := verifyInspectionContract(document.Inspection, manifest); err != nil {
				return models.AIKnowledgeDocument{}, err
			}
			return document, nil
		case models.KnowledgeStatusNeedsReview, models.KnowledgeStatusFailed:
			return models.AIKnowledgeDocument{}, fmt.Errorf("文档状态为 %s", document.Status)
		case models.KnowledgeStatusPublished:
			return document, nil
		}
		select {
		case <-ctx.Done():
			return models.AIKnowledgeDocument{}, ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

func verifyInspectionContract(raw string, manifest releaseManifest) error {
	var report services.KnowledgeInspectionReport
	if strings.TrimSpace(raw) == "" || json.Unmarshal([]byte(raw), &report) != nil {
		return fmt.Errorf("缺少有效检查报告")
	}
	if report.HasBlockingIssues() {
		return fmt.Errorf("检查报告仍有 %d 个阻塞项", report.BlockingCount)
	}
	if report.ChunkCount <= 0 || report.ChunkingVersion != manifest.ChunkingVersion ||
		report.EmbeddingModelName != manifest.EmbeddingModelName ||
		report.EmbeddingModelVersion != manifest.EmbeddingModelVersion ||
		report.EmbeddingDimensions != manifest.EmbeddingDimensions {
		return fmt.Errorf("LangChain 分块或 embedding 版本与清单不一致")
	}
	return nil
}
