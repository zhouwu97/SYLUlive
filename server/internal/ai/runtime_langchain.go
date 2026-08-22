package ai

import (
	"context"
	"errors"
	"io"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"
)

const (
	policyHistoryMaxRounds          = 4
	policyHistoryMaxMessages        = policyHistoryMaxRounds * 2
	policyHistoryMaxGraphemes       = 2400
	policyHistoryMaxUserGraphemes   = 300
	policyHistoryMaxAnswerGraphemes = 600
)

func (r *Runtime) executeLangChain(ctx context.Context, run *models.AIRun, message string) {
	runID := run.ID
	startedAt := time.Now()
	history, err := r.loadPolicyHistory(ctx, *run)
	if err != nil {
		r.failBeforeGeneration(runID, "rag_unavailable", true)
		return
	}
	stream, err := r.langChainRAG.StreamPolicy(ctx, PolicyRAGInput{
		RequestID: runID, Question: message, History: history, MaxSources: defaultPolicyMaxSources,
	})
	if err != nil {
		r.failBeforeGeneration(runID, "rag_unavailable", true)
		return
	}
	defer stream.Close()

	answer := strings.Builder{}
	generated := false
	generatingState := false
	usage := ProviderEvent{}
	chainName, chainVersion := "", ""
	var lastPolicySeq int64

	startGenerating := func() bool {
		if generatingState {
			return true
		}
		_, _ = r.appendEvent(ctx, runID, "retrieval.completed", map[string]interface{}{
			"chain_name": chainName, "chain_version": chainVersion,
		}, true)
		if err := r.transition(ctx, run, models.AIRunStateRetrieving, models.AIRunStateGenerating); err != nil {
			return false
		}
		generatingState = true
		return true
	}
	markGenerated := func() {
		if generated {
			return
		}
		generated = true
		r.markQuotaConsumed(runID)
		now := time.Now()
		_ = r.db.Model(&models.AIRun{}).Where("id = ?", runID).Update("started_at", now).Error
	}

	for {
		event, nextErr := stream.Next(ctx)
		if nextErr != nil {
			if r.runIsCancelled(runID) || errors.Is(nextErr, context.Canceled) && r.runIsCancelled(runID) {
				if generated && usage.InputTokens+usage.OutputTokens == 0 {
					r.markQuotaConsumed(runID)
					r.settleReservedBudget(runID, time.Since(startedAt), ProviderErrorCancelled)
				} else {
					r.finalizeCancelled(runID, generated, usage, time.Since(startedAt))
				}
				return
			}
			if errors.Is(nextErr, io.EOF) {
				nextErr = errors.New("incomplete LangChain event stream")
			}
			r.failLangChainProtocol(runID, generated, providerErrorClass(nextErr), time.Since(startedAt))
			return
		}
		if err := event.validate(runID, lastPolicySeq); err != nil {
			r.failLangChainProtocol(runID, generated, "invalid_response", time.Since(startedAt))
			return
		}
		lastPolicySeq = event.Sequence
		if chainName != "" && (event.ChainName != chainName || event.ChainVersion != chainVersion) {
			r.failLangChainProtocol(runID, generated, "invalid_response", time.Since(startedAt))
			return
		}
		chainName, chainVersion = event.ChainName, event.ChainVersion
		switch event.Type {
		case "planning", "retrieving", "reranking":
			_, _ = r.appendEvent(ctx, runID, "rag.stage", map[string]interface{}{
				"stage": event.Type, "chain_name": chainName, "chain_version": chainVersion,
			}, true)
		case "generating":
			if !startGenerating() {
				return
			}
		case "token":
			if !startGenerating() {
				return
			}
			markGenerated()
			answer.WriteString(event.Delta)
			// 结构化答案必须通过 Go 发布状态复核后才能进入客户端事件或持久化。
		case "failed":
			code := normalizeLangChainErrorCode(event.ErrorCode)
			if generated {
				r.failLangChainProtocol(runID, true, code, time.Since(startedAt))
			} else {
				r.failBeforeGeneration(runID, code, code == "rag_unavailable" || code == "rag_timeout")
			}
			return
		case "completed":
			result := event.Result
			if result == nil {
				r.failLangChainProtocol(runID, generated, "invalid_response", time.Since(startedAt))
				return
			}
			if result.Status == "insufficient_sources" {
				if generated {
					r.failLangChainProtocol(runID, true, "invalid_response", time.Since(startedAt))
				} else {
					r.failBeforeGeneration(runID, "rag_insufficient_sources", false)
				}
				return
			}
			if result.Status != "completed" && result.Status != "general_completed" && result.Status != "citation_rejected" {
				r.failLangChainProtocol(runID, generated, "invalid_response", time.Since(startedAt))
				return
			}
			if !startGenerating() {
				return
			}
			if answer.Len() > 0 && answer.String() != result.Answer {
				r.failLangChainProtocol(runID, generated, "invalid_response", time.Since(startedAt))
				return
			}
			if answer.Len() == 0 {
				answer.WriteString(result.Answer)
			}
			markGenerated()
			usage = policyRAGUsageEvent(result.Usage)
			_ = r.db.Model(&models.AIRun{}).Where("id = ? AND state = ?", runID, models.AIRunStateGenerating).Updates(map[string]interface{}{
				"provider": result.Usage.Provider, "model": result.Usage.Model,
			}).Error
			_, _ = r.appendEvent(ctx, runID, "rag.completed", map[string]interface{}{
				"chain_name": result.ChainName, "chain_version": result.ChainVersion,
				"answer_mode": result.AnswerMode, "degraded_modes": result.DegradedModes,
			}, true)
			r.completeRun(
				runID,
				result.Answer,
				policyRAGSourcesToChunks(result.Sources),
				usage,
				time.Since(startedAt),
				result.Status == "completed",
			)
			return
		}
	}
}

type policyHistoryRound struct {
	user      PolicyRAGHistoryMessage
	assistant PolicyRAGHistoryMessage
}

// loadPolicyHistory 只读取当前 Run 所属账号和会话中已完成的完整轮次。
// Python 仅接收该有限副本，不参与会话归属判断或历史持久化。
func (r *Runtime) loadPolicyHistory(ctx context.Context, current models.AIRun) ([]PolicyRAGHistoryMessage, error) {
	var conversationCount int64
	if err := r.db.WithContext(ctx).Model(&models.AIConversation{}).
		Where("id = ? AND user_id = ?", current.ConversationID, current.UserID).
		Count(&conversationCount).Error; err != nil {
		return nil, err
	}
	if conversationCount != 1 {
		return nil, gorm.ErrRecordNotFound
	}

	var completedRuns []models.AIRun
	if err := r.db.WithContext(ctx).
		Select("id", "user_id", "conversation_id", "created_at", "completed_at").
		Where(
			"user_id = ? AND conversation_id = ? AND id <> ? AND state = ? AND completed_at IS NOT NULL",
			current.UserID, current.ConversationID, current.ID, models.AIRunStateCompleted,
		).
		Where(
			"EXISTS (SELECT 1 FROM ai_conversation_messages AS m WHERE m.run_id = ai_runs.id AND m.conversation_id = ai_runs.conversation_id AND m.role = ? AND TRIM(m.content) <> '')",
			"user",
		).
		Where(
			"EXISTS (SELECT 1 FROM ai_conversation_messages AS m WHERE m.run_id = ai_runs.id AND m.conversation_id = ai_runs.conversation_id AND m.role = ? AND TRIM(m.content) <> '')",
			"assistant",
		).
		Order("completed_at DESC, created_at DESC, id DESC").
		Limit(policyHistoryMaxRounds).
		Find(&completedRuns).Error; err != nil {
		return nil, err
	}

	rounds := make([]policyHistoryRound, 0, len(completedRuns))
	totalGraphemes := 0
	for _, completedRun := range completedRuns {
		var messages []models.AIConversationMessage
		err := r.db.WithContext(ctx).
			Table("ai_conversation_messages AS m").
			Select("m.id", "m.conversation_id", "m.run_id", "m.role", "m.content", "m.created_at").
			Joins("JOIN ai_runs AS r ON r.id = m.run_id").
			Joins("JOIN ai_conversations AS c ON c.id = m.conversation_id AND c.deleted_at IS NULL").
			Where(
				"c.id = ? AND c.user_id = ? AND r.id = ? AND r.user_id = ? AND r.conversation_id = ? AND r.state = ? AND m.role IN ?",
				current.ConversationID, current.UserID, completedRun.ID, current.UserID,
				current.ConversationID, models.AIRunStateCompleted, []string{"user", "assistant"},
			).
			Order("m.created_at ASC, m.id ASC").
			Limit(4).
			Find(&messages).Error
		if err != nil {
			return nil, err
		}

		var userContent, assistantContent string
		for _, item := range messages {
			content := strings.TrimSpace(item.Content)
			if content == "" {
				continue
			}
			switch item.Role {
			case "user":
				if userContent == "" {
					userContent = truncatePolicyHistoryContent(content, policyHistoryMaxUserGraphemes)
				}
			case "assistant":
				if assistantContent == "" {
					assistantContent = truncatePolicyHistoryContent(content, policyHistoryMaxAnswerGraphemes)
				}
			}
		}
		if userContent == "" || assistantContent == "" {
			continue
		}
		roundGraphemes := utils.CountGraphemes(userContent) + utils.CountGraphemes(assistantContent)
		if totalGraphemes+roundGraphemes > policyHistoryMaxGraphemes {
			break
		}
		rounds = append(rounds, policyHistoryRound{
			user:      PolicyRAGHistoryMessage{Role: "user", Content: userContent},
			assistant: PolicyRAGHistoryMessage{Role: "assistant", Content: assistantContent},
		})
		totalGraphemes += roundGraphemes
	}

	history := make([]PolicyRAGHistoryMessage, 0, min(len(rounds)*2, policyHistoryMaxMessages))
	for index := len(rounds) - 1; index >= 0; index-- {
		history = append(history, rounds[index].user, rounds[index].assistant)
	}
	return history, nil
}

// truncatePolicyHistoryContent 将省略号计入历史消息的字符预算。
func truncatePolicyHistoryContent(content string, limit int) string {
	if limit <= 0 {
		return ""
	}
	if utils.CountGraphemes(content) <= limit {
		return content
	}
	if limit <= 3 {
		return strings.Repeat(".", limit)
	}
	return utils.TruncateGraphemes(content, limit-3)
}

func normalizeLangChainErrorCode(code string) string {
	switch strings.TrimSpace(code) {
	case "rag_timeout":
		return "rag_timeout"
	case "rag_chain_failed", "rag_stream_incomplete":
		return "rag_unavailable"
	default:
		return "rag_unavailable"
	}
}

// failLangChainProtocol 在已经向用户输出内容后按预留上限结算，
// 防止 usage 缺失或流协议损坏形成零成本成功路径。
func (r *Runtime) failLangChainProtocol(runID string, generated bool, code string, latency time.Duration) {
	if !generated {
		r.releaseQuotaAndBudget(runID)
		r.failRun(runID, code, true)
		return
	}
	r.markQuotaConsumed(runID)
	r.settleReservedBudget(runID, latency, code)
	r.failRun(runID, code, true)
}

func (r *Runtime) settleReservedBudget(runID string, latency time.Duration, errorClass string) int64 {
	now := time.Now()
	actual := int64(0)
	_ = r.db.Transaction(func(tx *gorm.DB) error {
		var reservation models.AIBudgetReservation
		if err := tx.Where("run_id = ? AND status = ?", runID, "reserved").First(&reservation).Error; err != nil {
			return err
		}
		actual = reservation.ReservedMicroYuan
		if err := tx.Model(&models.AIUserBudget{}).Where("user_id = ?", reservation.UserID).Updates(map[string]interface{}{
			"reserved_micro_yuan": gorm.Expr("CASE WHEN reserved_micro_yuan >= ? THEN reserved_micro_yuan - ? ELSE 0 END", reservation.ReservedMicroYuan, reservation.ReservedMicroYuan),
			"used_micro_yuan":     gorm.Expr("used_micro_yuan + ?", actual),
			"updated_at":          now,
		}).Error; err != nil {
			return err
		}
		if err := tx.Model(&reservation).Updates(map[string]interface{}{
			"status": "settled", "actual_micro_yuan": actual, "settled_at": now,
		}).Error; err != nil {
			return err
		}
		var run models.AIRun
		if err := tx.First(&run, "id = ?", runID).Error; err != nil {
			return err
		}
		return tx.Create(&models.AIUsageRecord{
			RunID: runID, UserHash: r.hashUserID(run.UserID), Provider: run.Provider, Model: run.Model, Purpose: "campus_agent",
			CostMicroYuan: actual, LatencyMilliseconds: latency.Milliseconds(), ErrorClass: errorClass,
		}).Error
	})
	return actual
}
