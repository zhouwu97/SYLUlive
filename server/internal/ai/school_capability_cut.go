package ai

import "strings"

// schoolPersonalToolNames 是 C3 后必须从 Go AI Runtime 中移除的个人学校能力。
// 这里维护稳定的内部名称，不依赖工具描述文本，避免改文案时意外重新开放能力。
var schoolPersonalToolNames = map[string]struct{}{
	"academic.resolve_context":       {},
	"academic.get_grade_summary":     {},
	"academic.get_credit_summary":    {},
	"academic.get_failure_risk":      {},
	"academic.get_risk_analysis":     {},
	"schedule.get_availability":      {},
	"erke.get_overview":              {},
	"physical.get_overview":          {},
	"profile.get_academic_identity":  {},
	"academic.summary":               {},
	"schedule.free_windows":          {},
	"schedule.validate_plan":         {},
	"academic.personal_read":         {},
	"academic.personal_refresh":      {},
	"hy3_decision.analyze_academic":  {},
	"hy3_decision.plan_student_week": {},
}

// IsSchoolPersonalToolName 判断一个工具是否读取或刷新个人学校数据。
// Device 命名空间全部属于已退役的设备桥；即使未来增加新工具，也会默认拒绝。
func IsSchoolPersonalToolName(name string) bool {
	name = strings.TrimSpace(name)
	if _, ok := schoolPersonalToolNames[name]; ok {
		return true
	}
	return strings.HasPrefix(name, "device.")
}

// FilterSchoolPersonalTools 返回可继续注册到 Server AI Runtime 的工具。
// 函数不修改输入切片或工具对象，便于启动装配和发布物扫描分别验证。
func FilterSchoolPersonalTools(tools []PureReadTool) []PureReadTool {
	filtered := make([]PureReadTool, 0, len(tools))
	for _, tool := range tools {
		if tool == nil || IsSchoolPersonalToolName(tool.Name()) {
			continue
		}
		filtered = append(filtered, tool)
	}
	return filtered
}
