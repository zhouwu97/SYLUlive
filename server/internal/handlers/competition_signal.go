package handlers

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

const (
	competitionSignalMaxBatch     = 50
	competitionSignalMaxPosition  = 200
	competitionSignalMaxSession   = 64
	competitionSignalMaxEventText = 64
)

// competitionSignalKinds 是允许写入的信号类型白名单。
// 埋点是长期侵蚀型的表：没有白名单，任何拼错的 kind 都会静静写进去，
// 等到要看指标时才发现一半数据口径不明。
var competitionSignalKinds = map[string]struct{}{
	models.CompetitionSignalFitTabExposure: {},
	models.CompetitionSignalImpression:     {},
	models.CompetitionSignalMatchReason:    {},
	models.CompetitionSignalClick:          {},
	models.CompetitionSignalCalendarAdd:    {},
}

type competitionSignalItem struct {
	EventID       uint   `json:"event_id"`
	CompetitionID string `json:"competition_id"`
	Kind          string `json:"kind"`
	Position      int    `json:"position"`
	MatchTier     string `json:"match_tier"`
	MatchBasis    string `json:"match_basis"`
}

type competitionSignalInput struct {
	SessionKey       string                  `json:"session_key"`
	AlgorithmVersion string                  `json:"algorithm_version"`
	Signals          []competitionSignalItem `json:"signals"`
}

// SubmitCompetitionCandidateSignals 接收一次「适合我」浏览产生的曝光与交互信号。
//
// 设计要点：
//   - 单请求最多 50 条，字段全部过白名单或范围校验，避免把这张表变成任意写入点；
//   - 曝光按 (用户, 会话, 赛事) 去重，同一会话滚动反复进入视口只记一次；
//   - 写失败不返回错误码给客户端（埋点不该影响用户操作），但必须记入响应的 accepted 数。
func (h *CompetitionHandler) SubmitCompetitionCandidateSignals(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input competitionSignalInput
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 32<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "埋点请求格式无效"})
		return
	}
	input.SessionKey = strings.TrimSpace(input.SessionKey)
	input.AlgorithmVersion = strings.TrimSpace(input.AlgorithmVersion)
	if len(input.SessionKey) > competitionSignalMaxSession {
		c.JSON(http.StatusBadRequest, gin.H{"error": "会话标识过长"})
		return
	}
	if len(input.Signals) < 1 || len(input.Signals) > competitionSignalMaxBatch {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次埋点数量必须在 1 到 50 之间"})
		return
	}
	if len(input.AlgorithmVersion) > 32 {
		input.AlgorithmVersion = input.AlgorithmVersion[:32]
	}
	eventIDs := make([]uint, 0, len(input.Signals))
	seenEventIDs := make(map[uint]struct{}, len(input.Signals))
	for _, signal := range input.Signals {
		if signal.EventID == 0 {
			continue
		}
		if _, exists := seenEventIDs[signal.EventID]; exists {
			continue
		}
		seenEventIDs[signal.EventID] = struct{}{}
		eventIDs = append(eventIDs, signal.EventID)
	}
	var events []models.CompetitionEvent
	if err := h.db.Select("id", "competition_id").Where("id IN ?", eventIDs).Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "校验赛事埋点失败"})
		return
	}
	canonicalCompetitionIDs := make(map[uint]string, len(events))
	for _, event := range events {
		canonicalCompetitionIDs[event.ID] = strings.TrimSpace(event.CompetitionID)
	}

	rows := make([]models.CompetitionCandidateSignals, 0, len(input.Signals))
	seen := make(map[string]struct{}, len(input.Signals))
	for _, signal := range input.Signals {
		kind := strings.TrimSpace(signal.Kind)
		if _, allowed := competitionSignalKinds[kind]; !allowed {
			c.JSON(http.StatusBadRequest, gin.H{"error": "未知的埋点类型"})
			return
		}
		if signal.Position < 0 || signal.Position > competitionSignalMaxPosition {
			c.JSON(http.StatusBadRequest, gin.H{"error": "展示位次超出范围"})
			return
		}
		competitionID := strings.TrimSpace(signal.CompetitionID)
		if len(competitionID) > competitionSignalMaxEventText {
			c.JSON(http.StatusBadRequest, gin.H{"error": "赛事编号过长"})
			return
		}
		if kind == models.CompetitionSignalFitTabExposure {
			// Tab 曝光表示用户进入「适合我」页，本身没有对应赛事，允许 event_id 为 0。
			if signal.EventID != 0 || competitionID != "" {
				c.JSON(http.StatusBadRequest, gin.H{"error": "适合我页曝光不应携带赛事"})
				return
			}
		} else {
			if signal.EventID == 0 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "埋点缺少赛事"})
				return
			}
			canonicalCompetitionID, exists := canonicalCompetitionIDs[signal.EventID]
			if !exists {
				c.JSON(http.StatusBadRequest, gin.H{"error": "埋点赛事不存在"})
				return
			}
			if competitionID != "" && competitionID != canonicalCompetitionID {
				c.JSON(http.StatusBadRequest, gin.H{"error": "埋点赛事编号与事件不匹配"})
				return
			}
			if competitionID == "" {
				competitionID = canonicalCompetitionID
			}
		}
		// 同一请求内的重复直接合并，避免一次上报里出现两条相同的曝光。
		dedupeKey := kind + "|" + input.SessionKey + "|" + competitionID
		if _, exists := seen[dedupeKey]; exists && kind == models.CompetitionSignalImpression {
			continue
		}
		seen[dedupeKey] = struct{}{}
		rows = append(rows, models.CompetitionCandidateSignals{
			UserID: userID, Kind: kind, SessionKey: input.SessionKey,
			EventID: signal.EventID, CompetitionID: competitionID,
			AlgorithmVersion: input.AlgorithmVersion,
			MatchTier:        trimTo(strings.TrimSpace(signal.MatchTier), 16),
			MatchBasis:       trimTo(strings.TrimSpace(signal.MatchBasis), 24),
			Position:         signal.Position,
		})
	}
	if len(rows) == 0 {
		c.JSON(http.StatusOK, gin.H{"accepted": 0})
		return
	}
	result := h.db.Clauses(clause.OnConflict{DoNothing: true}).Create(&rows)
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "埋点写入失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"accepted": result.RowsAffected})
}

func trimTo(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit]
}
