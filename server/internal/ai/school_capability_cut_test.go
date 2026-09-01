package ai

import (
	"context"
	"encoding/json"
	"testing"
)

type schoolCutTestTool struct{ name string }

func (t schoolCutTestTool) Name() string  { return t.name }
func (schoolCutTestTool) Version() string { return "test" }
func (t schoolCutTestTool) Definition() ToolDefinition {
	return ToolDefinition{Name: t.name}
}
func (schoolCutTestTool) Execute(context.Context, uint, json.RawMessage) (interface{}, error) {
	return nil, nil
}

func TestFilterSchoolPersonalToolsRemovesLegacyAndDeviceTools(t *testing.T) {
	tools := FilterSchoolPersonalTools([]PureReadTool{
		schoolCutTestTool{name: "academic.get_risk_analysis"},
		schoolCutTestTool{name: "device.academic.ensure_fresh_bundle"},
		schoolCutTestTool{name: "hy3_decision.plan_student_week"},
		schoolCutTestTool{name: "campus.search_policy"},
	})
	if len(tools) != 1 || tools[0].Name() != "campus.search_policy" {
		t.Fatalf("unexpected filtered tools: %#v", tools)
	}
}

func TestIsSchoolPersonalToolNameDefaultsDeviceNamespaceToDeny(t *testing.T) {
	if !IsSchoolPersonalToolName("device.future_school_tool") {
		t.Fatal("new device tool must remain denied after capability cut")
	}
	if IsSchoolPersonalToolName("campus.search_policy") {
		t.Fatal("public campus tool must remain available")
	}
}
