package ai

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestAgentContextIsRecheckedAgainstCurrentCompetition(t *testing.T) {
	db, err := gorm.Open(
		sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"),
		&gorm.Config{},
	)
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.CompetitionEvent{}))

	event := models.CompetitionEvent{
		Title:   "蓝桥杯",
		Status:  "published",
		Version: 5,
	}
	require.NoError(t, db.Create(&event).Error)
	runtime := &Runtime{db: db}

	contextEnvelope, err := runtime.validateAgentContext(
		context.Background(),
		7,
		&AgentContextEnvelope{
			Entrypoint: "competition_detail",
			ContextRefs: []AgentContextRef{{
				Type: "competition_event",
				ID:   "1",
			}},
		},
	)
	require.NoError(t, err)
	require.Equal(t, "1", contextEnvelope.ContextRefs[0].ID)
	prompt := runtime.agentContextPrompt(
		context.Background(),
		7,
		[]byte(`{"entrypoint":"competition_detail","context_refs":[{"type":"competition_event","id":"1"}]}`),
	)
	require.Contains(t, prompt, "蓝桥杯")
	require.Contains(t, prompt, "id=1")

	require.NoError(t, db.Delete(&event).Error)
	_, err = runtime.validateAgentContext(
		context.Background(),
		7,
		contextEnvelope,
	)
	var runtimeErr *RuntimeError
	require.True(t, errors.As(err, &runtimeErr))
	require.Equal(t, "invalid_agent_context", runtimeErr.Code)
	require.True(t, strings.Contains(runtimeErr.Message, "不存在"))
}

func TestAgentContextPreflightPlansApplicationDataReads(t *testing.T) {
	context := AgentContextEnvelope{
		Entrypoint:      "competition_detail",
		SuggestedIntent: "评估当前赛事是否适合我",
		ContextRefs:     []AgentContextRef{{Type: "competition_event", ID: "18"}},
	}
	competitionCalls := agentContextPreflightCalls(context)
	require.Len(t, competitionCalls, 2)
	require.Equal(t, "competition.get_details", competitionCalls[0].name)
	require.Equal(t, "competition.get_my_plan", competitionCalls[1].name)
	require.JSONEq(t, `{"event_id":18}`, string(competitionCalls[0].arguments))

	calendarCalls := agentContextPreflightCalls(AgentContextEnvelope{
		Entrypoint:  "calendar",
		ContextRefs: []AgentContextRef{{Type: "date", ID: "2026-08-23"}},
	})
	require.Len(t, calendarCalls, 2)
	require.Equal(t, "calendar.get_day", calendarCalls[0].name)
	require.Equal(t, "personal_calendar.get_day", calendarCalls[1].name)
}

func TestAgentContextPreflightReadsBeforeReturningModelMessages(t *testing.T) {
	db, err := gorm.Open(
		sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"),
		&gorm.Config{},
	)
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIRun{}, &models.AIEvent{}, &models.AIToolCall{}))

	tools := []*preflightReadTool{
		{name: "competition.get_details"},
		{name: "competition.get_my_plan"},
	}
	registry, err := NewToolRegistry(db, tools[0], tools[1])
	require.NoError(t, err)
	runtime := &Runtime{db: db, tools: registry, broker: NewEventBroker()}
	run := &models.AIRun{
		ID:           "run-preflight",
		UserID:       7,
		State:        models.AIRunStateRetrieving,
		AgentContext: datatypes.JSON([]byte(`{"entrypoint":"competition_detail","suggested_intent":"适合我","context_refs":[{"type":"competition_event","id":"18"}]}`)),
		LastEventSeq: 0,
	}
	require.NoError(t, db.Create(run).Error)

	messages, err := runtime.agentContextPreflight(context.Background(), run)
	require.NoError(t, err)
	require.Len(t, messages, 4)
	for _, tool := range tools {
		require.Equal(t, 1, tool.calls, tool.name)
	}
	var calls []models.AIToolCall
	require.NoError(t, db.Order("created_at ASC").Find(&calls).Error)
	require.Len(t, calls, 2)
	require.Equal(t, "competition.get_details", calls[0].ToolName)
	require.Equal(t, "completed", calls[0].Status)
}

type preflightReadTool struct {
	name  string
	calls int
}

func (tool *preflightReadTool) Name() string    { return tool.name }
func (tool *preflightReadTool) Version() string { return "test" }
func (tool *preflightReadTool) Definition() ToolDefinition {
	return ToolDefinition{
		Name:        tool.name,
		Description: "test preflight read",
		Parameters:  map[string]interface{}{"type": "object"},
	}
}
func (tool *preflightReadTool) Execute(_ context.Context, _ uint, _ json.RawMessage) (interface{}, error) {
	tool.calls++
	return map[string]interface{}{"status": "ok", "source": "test"}, nil
}
