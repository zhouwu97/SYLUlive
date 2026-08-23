package ai

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
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
	competitionCalls := agentContextPreflightCalls(AgentContextEnvelope{
		Entrypoint:  "competition_detail",
		ContextRefs: []AgentContextRef{{Type: "competition_event", ID: "18"}},
	})
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
