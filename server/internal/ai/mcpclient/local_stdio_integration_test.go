//go:build integration

package mcpclient

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestLocalStdioIntegration 使用独立 MCP 的 fixture 模式验证官方 Go SDK 的真实 stdio 握手。
// 仅在显式传入本地 MCP 路径时运行，默认单元测试和 CI 不依赖开发机目录。
func TestLocalStdioIntegration(t *testing.T) {
	command := integrationAbsolutePath(t, "HY3_MCP_INTEGRATION_COMMAND")
	campusRoot := integrationAbsolutePath(t, "HY3_MCP_INTEGRATION_CAMPUS_ROOT")
	fixtureRoot := integrationAbsolutePath(t, "HY3_MCP_INTEGRATION_FIXTURE_ROOT")

	t.Setenv("HY3_MODE", "fixture")
	t.Setenv("HY3_CAMPUS_ROOT", campusRoot)
	t.Setenv("HY3_FIXTURE_ROOT", fixtureRoot)

	client, err := New(Config{
		Enabled:        true,
		Transport:      TransportLocalStdio,
		Command:        command,
		ToolTimeout:    20 * time.Second,
		MaxCallsPerRun: 1,
	}, nil)
	require.NoError(t, err)
	t.Cleanup(func() {
		require.NoError(t, client.Close())
	})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	require.NoError(t, client.Connect(ctx))
	require.True(t, client.Healthy())

	definitions, err := client.ListTools(ctx)
	require.NoError(t, err)
	require.Equal(t, []string{
		"analyze_academic_snapshot",
		"compare_competitions",
		"plan_student_week",
	}, remoteToolNames(definitions))

	for _, call := range []struct {
		name      string
		arguments map[string]interface{}
	}{
		{
			name: "compare_competitions",
			arguments: map[string]interface{}{
				"student_profile": map[string]interface{}{"major": "测试专业", "grade": "测试年级", "weekly_hours": 8},
				"competitions": []interface{}{
					map[string]interface{}{"name": "测试赛事一", "difficulty": "low"},
					map[string]interface{}{"name": "测试赛事二", "difficulty": "medium"},
				},
			},
		},
		{
			name: "analyze_academic_snapshot",
			arguments: map[string]interface{}{
				"snapshot": map[string]interface{}{
					"courses": []interface{}{
						map[string]interface{}{
							"course_name": "测试课程",
							"credits":     3,
							"is_required": true,
							"grade":       85,
							"passed":      true,
						},
					},
					"earned_credits":   3,
					"required_credits": 160,
					"erke_earned":      0,
					"erke_required":    2,
				},
			},
		},
		{
			name: "plan_student_week",
			arguments: map[string]interface{}{
				"schedule": map[string]interface{}{
					"week_start":   "2026-07-20",
					"timezone":     "Asia/Shanghai",
					"fixed_events": []interface{}{},
				},
				"goals": []interface{}{
					map[string]interface{}{"name": "测试目标", "weekly_minutes": 60, "priority": "high"},
				},
				"constraints": map[string]interface{}{},
			},
		},
	} {
		payload, callErr := client.CallTool(ctx, call.name, call.arguments)
		require.NoError(t, callErr, call.name)
		var response struct {
			Status string `json:"status"`
		}
		require.NoError(t, json.Unmarshal(payload, &response), call.name)
		require.Equal(t, "ok", response.Status, call.name)
	}
}

func integrationAbsolutePath(t *testing.T, environment string) string {
	t.Helper()
	value := strings.TrimSpace(os.Getenv(environment))
	if value == "" {
		t.Skipf("设置 %s 后运行本地 MCP stdio 集成测试", environment)
	}
	if !filepath.IsAbs(value) {
		t.Fatalf("%s 必须是绝对路径", environment)
	}
	return value
}
