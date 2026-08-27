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

	"shenliyuan/internal/ai"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

const defaultEmbeddingModel = "paraphrase-multilingual-minilm-l12-v2-384-v1"

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

func run(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("shenliyuan-ai-eval", flag.ContinueOnError)
	flags.SetOutput(stderr)
	mode := flags.String("mode", "fixture", "评测模式：fixture 或 live")
	dataDirectory := flags.String("data", "testdata/ai_eval", "JSONL 评测数据目录")
	k := flags.Int("k", 5, "检索指标的 K 值")
	timeout := flags.Duration("timeout", 10*time.Minute, "整次评测超时")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() > 1 {
		fmt.Fprintln(stderr, "最多只能提供一个兼容位置参数作为数据目录")
		return 2
	}
	if flags.NArg() == 1 {
		*dataDirectory = flags.Arg(0)
	}
	if *k <= 0 {
		fmt.Fprintln(stderr, "--k 必须大于 0")
		return 2
	}

	cases, err := ai.LoadEvaluationCases(*dataDirectory)
	if err != nil {
		fmt.Fprintf(stderr, "加载评测数据失败：%v\n", err)
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	var runner *ai.EvaluationRunner
	switch strings.ToLower(strings.TrimSpace(*mode)) {
	case "fixture":
		runner = ai.NewEvaluationRunner("fixture", *k, ai.FixtureEvaluationBackend{})
	case "live":
		liveRunner, closeLive, err := buildLiveRunner(ctx, *k, getenv)
		if err != nil {
			fmt.Fprintf(stderr, "live 模式不可用：%v\n", err)
			return 2
		}
		defer closeLive()
		runner = liveRunner
	default:
		fmt.Fprintln(stderr, "--mode 只支持 fixture 或 live")
		return 2
	}

	report, err := runner.Run(ctx, cases)
	if err != nil {
		fmt.Fprintf(stderr, "评测运行失败：%v\n", err)
		return 1
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(report); err != nil {
		fmt.Fprintf(stderr, "输出评测报告失败：%v\n", err)
		return 1
	}
	if report.Failed > 0 {
		return 1
	}
	return 0
}

func buildLiveRunner(ctx context.Context, k int, getenv func(string) string) (*ai.EvaluationRunner, func(), error) {
	apiKey := firstConfiguredValue(getenv, "AI_API_KEY", "DEEPSEEK_API_KEY")
	baseURL := firstConfiguredValue(getenv, "AI_BASE_URL", "DEEPSEEK_BASE_URL")
	chatModel := firstConfiguredValue(getenv, "AI_CHAT_MODEL", "DEEPSEEK_CHAT_MODEL")
	if chatModel == "" {
		chatModel = "gpt-5.4"
	}
	required := map[string]string{
		"DATABASE_DSN":      strings.TrimSpace(getenv("DATABASE_DSN")),
		"RAG_SERVICE_URL":   strings.TrimSpace(getenv("RAG_SERVICE_URL")),
		"RAG_SERVICE_TOKEN": strings.TrimSpace(getenv("RAG_SERVICE_TOKEN")),
		"AI_API_KEY":        apiKey,
		"AI_BASE_URL":       baseURL,
		"AI_CHAT_MODEL":     chatModel,
	}
	missing := make([]string, 0)
	for _, name := range []string{"DATABASE_DSN", "RAG_SERVICE_URL", "RAG_SERVICE_TOKEN", "AI_API_KEY", "AI_BASE_URL"} {
		if required[name] == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return nil, func() {}, fmt.Errorf("缺少依赖配置：%s", strings.Join(missing, ", "))
	}

	db, err := gorm.Open(postgres.Open(required["DATABASE_DSN"]), &gorm.Config{})
	if err != nil {
		return nil, func() {}, fmt.Errorf("连接 PostgreSQL 失败")
	}
	sqlDB, err := db.DB()
	if err != nil {
		return nil, func() {}, fmt.Errorf("获取 PostgreSQL 连接失败")
	}
	closeLive := func() { _ = sqlDB.Close() }
	if err := sqlDB.PingContext(ctx); err != nil {
		closeLive()
		return nil, func() {}, fmt.Errorf("PostgreSQL 健康检查失败")
	}

	httpClient := &http.Client{Timeout: 90 * time.Second}
	rag, err := ai.NewRAGClient(required["RAG_SERVICE_URL"], required["RAG_SERVICE_TOKEN"], httpClient)
	if err != nil {
		closeLive()
		return nil, func() {}, fmt.Errorf("RAG 配置无效：%w", err)
	}
	if err := rag.Health(ctx); err != nil {
		closeLive()
		return nil, func() {}, fmt.Errorf("RAG 健康检查失败：%w", err)
	}
	provider, err := ai.NewOpenAICompatibleProvider(required["AI_BASE_URL"], required["AI_API_KEY"], required["AI_CHAT_MODEL"], httpClient)
	if err != nil {
		closeLive()
		return nil, func() {}, fmt.Errorf("Provider 配置无效：%w", err)
	}
	modelVersion := strings.TrimSpace(getenv("RAG_EMBEDDING_MODEL_VERSION"))
	if modelVersion == "" {
		modelVersion = defaultEmbeddingModel
	}
	backend, err := ai.NewLiveEvaluationBackend(db, ai.NewHybridRetriever(db, rag, modelVersion), provider)
	if err != nil {
		closeLive()
		return nil, func() {}, err
	}
	return ai.NewEvaluationRunner("live", k, backend), closeLive, nil
}

func firstConfiguredValue(getenv func(string) string, names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(getenv(name)); value != "" {
			return value
		}
	}
	return ""
}
