package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fatal("用法: shenliyuan-ai-kb <publish|revoke|inspect|reindex|supersede> --document-id ID")
	}
	action := os.Args[1]
	if action != "publish" && action != "revoke" && action != "inspect" && action != "reindex" && action != "supersede" {
		fatal("未知动作: " + action)
	}
	flags := flag.NewFlagSet(action, flag.ExitOnError)
	documentID := flags.Uint("document-id", 0, "知识文档 ID")
	replacementID := flags.Uint("replacement-document-id", 0, "替代文档 ID（仅 supersede）")
	baseURL := flags.String("base-url", envOrDefault("SHENLIYUAN_API_BASE_URL", "http://127.0.0.1:8080"), "服务端 API 地址")
	if err := flags.Parse(os.Args[2:]); err != nil {
		fatal(err.Error())
	}
	if *documentID == 0 {
		fatal("必须提供 --document-id")
	}
	token := strings.TrimSpace(os.Getenv("SHENLIYUAN_ADMIN_JWT"))
	if token == "" {
		fatal("必须通过 SHENLIYUAN_ADMIN_JWT 环境变量提供短期管理员 JWT")
	}

	var body io.Reader
	if action == "supersede" {
		if *replacementID == 0 {
			fatal("supersede 必须提供 --replacement-document-id")
		}
		payload, _ := json.Marshal(map[string]uint{"replacement_document_id": *replacementID})
		body = bytes.NewReader(payload)
	}
	endpoint := strings.TrimRight(*baseURL, "/") + "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(*documentID), 10) + "/" + action
	request, err := http.NewRequest(http.MethodPost, endpoint, body)
	if err != nil {
		fatal(err.Error())
	}
	request.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{Timeout: 30 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		fatal(err.Error())
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		fatal(fmt.Sprintf("API 返回 HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(responseBody))))
	}
	fmt.Println(strings.TrimSpace(string(responseBody)))
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
