package ai

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/academic"
)

func TestHy3AcademicSnapshotUsesDeviceGradeProjectionWithoutReturningItAsAnalysis(t *testing.T) {
	grades := json.RawMessage(`{
		"course_count":42,
		"earned_credits":84.25,
		"weighted_gpa":2.57,
		"failed_courses":[{"course_name":"信号与系统","grade":52,"credits":3}]
	}`)
	credits := academic.ContextResult{}
	erke := academic.ContextResult{}

	snapshot, warnings, err := buildHy3AcademicSnapshot(grades, credits, erke)
	require.NoError(t, err)
	require.Contains(t, warnings, "本次使用了手机返回的成绩风险摘要，未上传完整成绩明细。")
	require.Equal(t, 42, snapshot["course_count"])
	require.Equal(t, 2.57, snapshot["weighted_gpa"])
	require.Equal(t, 84.25, snapshot["earned_credits"])
	require.NotContains(t, snapshot, "source")
	require.NotContains(t, snapshot, "is_stale")

	courses, ok := snapshot["courses"].([]map[string]interface{})
	require.True(t, ok)
	require.Len(t, courses, 1)
	require.Equal(t, "信号与系统", courses[0]["course_name"])
}
