package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

const cliUsage = `用法: shenliyuan-ai-kb <command> [options]

只读命令:
  manifest   根据 JSONL 导入包生成版本清单
  dry-run    校验清单并报告新增、替代、跳过和阻塞项
  check      在 dry-run 基础上强制执行 LangChain 分块与向量化检查

写操作:
  release    导入、检查、验证并原子发布整个版本
  rollback   根据发布记录原子恢复上一个版本
  publish|revoke|inspect|reindex|supersede

任何写操作都必须同时提供短期管理员 JWT、--execute 和命令输出要求的精确确认短语。`

type environment func(string) string

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr, &http.Client{}))
}

func run(args []string, getenv environment, stdout, stderr io.Writer, client *http.Client) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, cliUsage)
		return 2
	}
	switch args[0] {
	case "help", "-h", "--help":
		fmt.Fprintln(stdout, cliUsage)
		return 0
	case "manifest":
		return runManifest(args[1:], stdout, stderr)
	case "dry-run":
		return runDryRun(args[1:], getenv, stdout, stderr, client, false)
	case "check":
		return runDryRun(args[1:], getenv, stdout, stderr, client, true)
	case "release":
		return runRelease(args[1:], getenv, stdout, stderr, client)
	case "rollback":
		return runRollback(args[1:], getenv, stdout, stderr, client)
	case "publish", "revoke", "inspect", "reindex", "supersede":
		return runDocumentMutation(args[0], args[1:], getenv, stdout, stderr, client)
	default:
		fmt.Fprintf(stderr, "未知命令：%s\n%s\n", args[0], cliUsage)
		return 2
	}
}
