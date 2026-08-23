package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

// InternalMCPV5Handler 是纯能力层的事实网关。
// 这里不接收 user_id/JWT/Cookie；subject 只从 Run Scoped Grant 解析。
type InternalMCPV5Handler struct {
	db  *gorm.DB
	now func() time.Time
}

func NewInternalMCPV5Handler(db *gorm.DB) *InternalMCPV5Handler {
	return &InternalMCPV5Handler{db: db, now: time.Now}
}

type internalMCPEnvelope struct {
	OK         bool        `json:"ok"`
	Data       interface{} `json:"data,omitempty"`
	AsOf       time.Time   `json:"as_of"`
	Freshness  string      `json:"freshness"`
	SourceRefs []string    `json:"source_refs,omitempty"`
	Warnings   []string    `json:"warnings,omitempty"`
	NextHints  []string    `json:"next_hints,omitempty"`
	Error      interface{} `json:"error,omitempty"`
}

func (h *InternalMCPV5Handler) SystemStatus(c *gin.Context) {
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: true, Data: gin.H{"contract_version": ai.AgentContractVersion, "capability_plane": "pure", "llm": false, "identity_storage": false}, AsOf: h.now(), Freshness: "static"})
}

type policySearchInput struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
}

func (h *InternalMCPV5Handler) PolicySearch(c *gin.Context) {
	var input policySearchInput
	if !decodeInternalMCPJSON(c, &input) {
		return
	}
	input.Query = strings.TrimSpace(input.Query)
	if input.Query == "" || len([]rune(input.Query)) > 200 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "query 无效"})
		return
	}
	if input.Limit <= 0 || input.Limit > 20 {
		input.Limit = 8
	}
	if h.db == nil {
		writeMCPFailure(c, "mcp_not_configured", false)
		return
	}
	pattern := "%" + strings.ToLower(input.Query) + "%"
	var rows []struct {
		ChunkID uint64 `json:"chunk_id"`
		Title   string `json:"title"`
		Section string `json:"section"`
		Content string `json:"content"`
		Locator string `json:"locator"`
	}
	err := h.db.WithContext(c.Request.Context()).Table("ai_knowledge_chunks AS c").
		Select("c.id AS chunk_id, d.title, c.section_title AS section, c.content, c.source_locator AS locator").
		Joins("JOIN ai_knowledge_documents AS d ON d.id = c.document_id AND d.deleted_at IS NULL").
		Where("d.status = ? AND (LOWER(d.title) LIKE ? OR LOWER(c.content) LIKE ?)", models.KnowledgeStatusPublished, pattern, pattern).
		Order("d.published_at DESC, c.id ASC").Limit(input.Limit).Find(&rows).Error
	if err != nil {
		writeMCPFailure(c, "policy_search_failed", true)
		return
	}
	items := make([]gin.H, 0, len(rows))
	refs := make([]string, 0, len(rows))
	for _, row := range rows {
		items = append(items, gin.H{"chunk_id": row.ChunkID, "title": row.Title, "section": row.Section, "snippet": compactSnippet(row.Content, 500), "locator": row.Locator})
		refs = append(refs, "policy_chunk:"+formatUint(row.ChunkID))
	}
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: true, Data: gin.H{"items": items}, AsOf: h.now(), Freshness: "live", SourceRefs: refs})
}

type policySourcesInput struct {
	ChunkIDs []uint64 `json:"chunk_ids"`
}

func (h *InternalMCPV5Handler) PolicySources(c *gin.Context) {
	var input policySourcesInput
	if !decodeInternalMCPJSON(c, &input) || len(input.ChunkIDs) < 1 || len(input.ChunkIDs) > 20 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "chunk_ids 数量无效"})
		return
	}
	if h.db == nil {
		writeMCPFailure(c, "mcp_not_configured", false)
		return
	}
	var rows []struct {
		ChunkID    uint64 `json:"chunk_id"`
		DocumentID uint   `json:"document_id"`
		Title      string `json:"title"`
		Content    string `json:"content"`
		Section    string `json:"section"`
		Locator    string `json:"locator"`
	}
	err := h.db.WithContext(c.Request.Context()).Table("ai_knowledge_chunks AS c").
		Select("c.id AS chunk_id, c.document_id, d.title, c.content, c.section_title AS section, c.source_locator AS locator").
		Joins("JOIN ai_knowledge_documents AS d ON d.id = c.document_id AND d.deleted_at IS NULL").
		Where("d.status = ? AND c.id IN ?", models.KnowledgeStatusPublished, input.ChunkIDs).Find(&rows).Error
	if err != nil {
		writeMCPFailure(c, "policy_sources_failed", true)
		return
	}
	items := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		items = append(items, gin.H{"chunk_id": row.ChunkID, "document_id": row.DocumentID, "title": row.Title, "content": row.Content, "section": row.Section, "locator": row.Locator})
	}
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: true, Data: gin.H{"items": items}, AsOf: h.now(), Freshness: "live"})
}

type scopedSnapshotInput struct {
	Datasets []string `json:"datasets"`
}

func (h *InternalMCPV5Handler) AcademicSummary(c *gin.Context) {
	grant, ok := ai.ScopedGrantFromContext(c.Request.Context())
	if !ok || !containsMCPString(grant.Scopes, "academic:summary") {
		writeMCPFailure(c, "permission_denied", false)
		return
	}
	var input scopedSnapshotInput
	if !decodeInternalMCPJSON(c, &input) {
		return
	}
	datasets := input.Datasets
	if len(datasets) == 0 {
		datasets = []string{"grades", "credits", "schedule"}
	}
	if len(datasets) > 4 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "datasets 数量无效"})
		return
	}
	if h.db == nil {
		writeMCPFailure(c, "mcp_not_configured", false)
		return
	}
	data := make(map[string]json.RawMessage, len(datasets))
	warnings := make([]string, 0)
	for _, dataset := range datasets {
		if !allowedSnapshotDataset(dataset) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "dataset 不受支持"})
			return
		}
		var snapshot models.AcademicSnapshot
		err := h.db.WithContext(c.Request.Context()).Where("user_id = ? AND dataset_type = ?", grant.UserID, dataset).Order("fetched_at DESC, id DESC").First(&snapshot).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			warnings = append(warnings, "缺少 "+dataset+" 快照")
			continue
		}
		if err != nil {
			writeMCPFailure(c, "academic_summary_failed", true)
			return
		}
		if !json.Valid(snapshot.PayloadJSON) {
			warnings = append(warnings, dataset+" 快照损坏")
			continue
		}
		data[dataset] = append(json.RawMessage(nil), snapshot.PayloadJSON...)
		if !snapshot.ExpiresAt.After(h.now()) {
			warnings = append(warnings, dataset+" 快照已过期")
		}
	}
	freshness := "live"
	if len(warnings) > 0 {
		freshness = "stale"
	}
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: true, Data: data, AsOf: h.now(), Freshness: freshness, Warnings: warnings, NextHints: []string{"refresh_academic_if_needed"}})
}

type scheduleWindowInput struct {
	From            string `json:"from"`
	To              string `json:"to"`
	DurationMinutes int    `json:"duration_minutes"`
}

type scheduleBlock struct {
	Start  time.Time
	End    time.Time
	Source string
}

func (h *InternalMCPV5Handler) ScheduleFreeWindows(c *gin.Context) {
	grant, ok := ai.ScopedGrantFromContext(c.Request.Context())
	if !ok || !containsMCPString(grant.Scopes, "schedule:read") {
		writeMCPFailure(c, "permission_denied", false)
		return
	}
	var input scheduleWindowInput
	if !decodeInternalMCPJSON(c, &input) || input.DurationMinutes < 15 || input.DurationMinutes > 720 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "时间窗口参数无效"})
		return
	}
	from, to, err := parseScheduleRange(input.From, input.To)
	if err != nil || !to.After(from) || to.Sub(from) > 31*24*time.Hour {
		c.JSON(http.StatusBadRequest, gin.H{"error": "时间范围无效"})
		return
	}
	blocks, err := h.loadScheduleBlocks(c, grant.UserID, from, to)
	if err != nil {
		writeMCPFailure(c, "schedule_read_failed", true)
		return
	}
	windows := freeScheduleWindows(from, to, input.DurationMinutes, blocks)
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: true, Data: gin.H{"from": from, "to": to, "duration_minutes": input.DurationMinutes, "available_windows": windows}, AsOf: h.now(), Freshness: "live"})
}

type scheduleValidateInput struct {
	Blocks []struct {
		Start string `json:"start"`
		End   string `json:"end"`
	} `json:"blocks"`
}

func (h *InternalMCPV5Handler) ScheduleValidatePlan(c *gin.Context) {
	grant, ok := ai.ScopedGrantFromContext(c.Request.Context())
	if !ok || !containsMCPString(grant.Scopes, "schedule:read") {
		writeMCPFailure(c, "permission_denied", false)
		return
	}
	var input scheduleValidateInput
	if !decodeInternalMCPJSON(c, &input) || len(input.Blocks) == 0 || len(input.Blocks) > 32 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "blocks 数量无效"})
		return
	}
	blocks := make([]scheduleBlock, 0, len(input.Blocks))
	var rangeStart, rangeEnd time.Time
	for _, item := range input.Blocks {
		start, err1 := time.Parse(time.RFC3339, item.Start)
		end, err2 := time.Parse(time.RFC3339, item.End)
		if err1 != nil || err2 != nil || !end.After(start) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "计划时间无效"})
			return
		}
		blocks = append(blocks, scheduleBlock{Start: start, End: end, Source: "proposed"})
		if rangeStart.IsZero() || start.Before(rangeStart) {
			rangeStart = start
		}
		if rangeEnd.IsZero() || end.After(rangeEnd) {
			rangeEnd = end
		}
	}
	busy, err := h.loadScheduleBlocks(c, grant.UserID, rangeStart, rangeEnd)
	if err != nil {
		writeMCPFailure(c, "schedule_read_failed", true)
		return
	}
	conflicts := make([]gin.H, 0)
	for _, proposed := range blocks {
		for _, existing := range busy {
			if proposed.Start.Before(existing.End) && existing.Start.Before(proposed.End) {
				conflicts = append(conflicts, gin.H{"start": proposed.Start, "end": proposed.End, "source": existing.Source})
			}
		}
	}
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: len(conflicts) == 0, Data: gin.H{"valid": len(conflicts) == 0, "conflicts": conflicts}, AsOf: h.now(), Freshness: "live"})
}

func (h *InternalMCPV5Handler) loadScheduleBlocks(c *gin.Context, userID uint, from, to time.Time) ([]scheduleBlock, error) {
	var events []models.UserCalendarEvent
	if err := h.db.WithContext(c.Request.Context()).Where("user_id = ? AND start_at < ? AND end_at > ?", userID, to.UTC(), from.UTC()).Find(&events).Error; err != nil {
		return nil, err
	}
	blocks := make([]scheduleBlock, 0, len(events))
	for _, event := range events {
		blocks = append(blocks, scheduleBlock{Start: event.StartAt, End: event.EndAt, Source: "personal_calendar"})
	}
	return blocks, nil
}

func freeScheduleWindows(from, to time.Time, duration int, busy []scheduleBlock) []gin.H {
	sort.Slice(busy, func(i, j int) bool { return busy[i].Start.Before(busy[j].Start) })
	result := make([]gin.H, 0)
	cursor := from
	for _, block := range busy {
		if block.Start.After(cursor) && block.Start.Sub(cursor) >= time.Duration(duration)*time.Minute {
			result = append(result, gin.H{"start": cursor, "end": block.Start})
		}
		if block.End.After(cursor) {
			cursor = block.End
		}
	}
	if to.After(cursor) && to.Sub(cursor) >= time.Duration(duration)*time.Minute {
		result = append(result, gin.H{"start": cursor, "end": to})
	}
	return result
}

func parseScheduleRange(from, to string) (time.Time, time.Time, error) {
	if strings.TrimSpace(from) == "" || strings.TrimSpace(to) == "" {
		return time.Time{}, time.Time{}, errors.New("range_required")
	}
	start, err := time.Parse(time.RFC3339, from)
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	end, err := time.Parse(time.RFC3339, to)
	return start, end, err
}

func allowedSnapshotDataset(value string) bool {
	switch value {
	case "grades", "credits", "schedule":
		return true
	default:
		return false
	}
}

func writeMCPFailure(c *gin.Context, code string, retryable bool) {
	c.JSON(http.StatusOK, internalMCPEnvelope{OK: false, AsOf: time.Now(), Freshness: "live", Error: gin.H{"code": code, "retryable": retryable}})
}

func compactSnippet(value string, limit int) string {
	value = strings.Join(strings.Fields(value), " ")
	if len([]rune(value)) <= limit {
		return value
	}
	return string([]rune(value)[:limit]) + "…"
}

func formatUint(value uint64) string {
	return fmt.Sprintf("%d", value)
}

func containsMCPString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
