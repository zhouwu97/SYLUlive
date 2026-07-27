package ai

import (
	"context"
	"errors"
	"io"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func (r *Runtime) executeLangChain(ctx context.Context, run *models.AIRun, message string) {
	runID := run.ID
	startedAt := time.Now()
	stream, err := r.langChainRAG.StreamPolicy(ctx, PolicyRAGInput{
		RequestID: runID, Question: message, MaxSources: defaultPolicyMaxSources,
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
	lastCheckpointAt := time.Now()
	checkpointLength := 0
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
			_, _ = r.appendEvent(ctx, runID, "answer.delta", map[string]interface{}{"text": event.Delta}, false)
			if answer.Len()-checkpointLength >= 512 || time.Since(lastCheckpointAt) >= time.Second {
				r.persistCheckpoint(ctx, runID, answer.String())
				checkpointLength, lastCheckpointAt = answer.Len(), time.Now()
			}
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
			if !startGenerating() {
				return
			}
			if answer.Len() > 0 && answer.String() != result.Answer {
				r.failLangChainProtocol(runID, generated, "invalid_response", time.Since(startedAt))
				return
			}
			if answer.Len() == 0 {
				answer.WriteString(result.Answer)
				_, _ = r.appendEvent(ctx, runID, "answer.delta", map[string]interface{}{"text": result.Answer}, false)
			}
			markGenerated()
			usage = policyRAGUsageEvent(result.Usage)
			_ = r.db.Model(&models.AIRun{}).Where("id = ? AND state = ?", runID, models.AIRunStateGenerating).Updates(map[string]interface{}{
				"provider": result.Usage.Provider, "model": result.Usage.Model,
			}).Error
			_, _ = r.appendEvent(ctx, runID, "rag.completed", map[string]interface{}{
				"chain_name": result.ChainName, "chain_version": result.ChainVersion,
				"degraded_modes": result.DegradedModes,
			}, true)
			r.completeRun(runID, result.Answer, policyRAGSourcesToChunks(result.Sources), usage, time.Since(startedAt))
			return
		}
	}
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
			RunID: runID, UserHash: r.hashUserID(run.UserID), Provider: run.Provider, Model: run.Model,
			CostMicroYuan: actual, LatencyMilliseconds: latency.Milliseconds(), ErrorClass: errorClass,
		}).Error
	})
	return actual
}
