package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

func runDocumentMutation(action string, args []string, getenv environment, stdout, stderr io.Writer, client *http.Client) int {
	flags := flag.NewFlagSet(action, flag.ContinueOnError)
	flags.SetOutput(stderr)
	documentID := flags.Uint("document-id", 0, "知识文档 ID")
	replacementID := flags.Uint("replacement-document-id", 0, "替代文档 ID（仅 supersede）")
	baseURL := flags.String("base-url", envOrDefault(getenv, "SHENLIYUAN_API_BASE_URL", "http://127.0.0.1:8080"), "服务端 API 地址")
	execute := flags.Bool("execute", false, "允许发出写请求")
	confirm := flags.String("confirm", "", "精确确认短语")
	timeout := flags.Duration("timeout", 30*time.Second, "请求超时")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return 2
	}
	if *documentID == 0 || (action == "supersede" && *replacementID == 0) {
		fmt.Fprintln(stderr, "必须提供有效的 --document-id；supersede 还需要 --replacement-document-id")
		return 2
	}
	required := fmt.Sprintf("APPLY:%s:%d", action, *documentID)
	if action == "supersede" {
		required = fmt.Sprintf("APPLY:%s:%d:%d", action, *documentID, *replacementID)
	}
	if !*execute {
		fmt.Fprintf(stdout, "dry-run：未发出写请求。确认后使用 --execute --confirm %q\n", required)
		return 0
	}
	token, ok := authorizeMutation(getenv, strings.TrimSpace(*confirm), required, stderr)
	if !ok {
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	var response map[string]any
	if err := newKnowledgeAPI(*baseURL, token, client).action(ctx, action, *documentID, *replacementID, &response); err != nil {
		fmt.Fprintf(stderr, "%s 失败：%v\n", action, err)
		return 1
	}
	encoded, _ := marshalIndented(response)
	_, _ = stdout.Write(encoded)
	return 0
}

func authorizeMutation(getenv environment, actual, required string, stderr io.Writer) (string, bool) {
	if actual != required {
		fmt.Fprintf(stderr, "确认短语不匹配；必须是 %q。未发出写请求。\n", required)
		return "", false
	}
	token := strings.TrimSpace(getenv("SHENLIYUAN_ADMIN_JWT"))
	if token == "" {
		fmt.Fprintln(stderr, "缺少 SHENLIYUAN_ADMIN_JWT。未发出写请求。")
		return "", false
	}
	return token, true
}
