package handlers

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestHTTPSecurityWritesAlwaysCarryContext 是一条结构性约束：
// HTTP handler 里写安全事件必须走带 context 的入口。
//
// 为什么用源码扫描而不是行为测试：无 context 的 `security.Record(...)` 在功能上完全跑得通，
// 只有在数据库变慢时才暴露成「辅助安全层把业务请求拖满」。A10 的要求是预算对所有 HTTP
// 链路成立，这属于不能靠个别用例覆盖的调用点约束，所以把它钉成断言，新增调用点漏带
// context 时立即失败，而不是等生产超时。
func TestHTTPSecurityWritesAlwaysCarryContext(t *testing.T) {
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("读取工作目录失败: %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("读取 handler 目录失败: %v", err)
	}
	fset := token.NewFileSet()
	var offenders []string
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, filepath.Join(dir, name), nil, 0)
		if err != nil {
			t.Fatalf("解析 %s 失败: %v", name, err)
		}
		ast.Inspect(file, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			receiver, ok := sel.X.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if receiver.Sel.Name == "security" && (sel.Sel.Name == "Record" || sel.Sel.Name == "CountDistinctTargets" || sel.Sel.Name == "CountDistinctTargetsForEvents") {
				offenders = append(offenders, fmt.Sprintf("%s:%d -> %s()", name, fset.Position(call.Pos()).Line, sel.Sel.Name))
			}
			return true
		})
	}
	if len(offenders) > 0 {
		sort.Strings(offenders)
		t.Fatalf("HTTP handler 仍在调用不带 context 的安全事件入口，共 %d 处:\n%s",
			len(offenders), strings.Join(offenders, "\n"))
	}
}
