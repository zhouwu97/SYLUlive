package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/tasks"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type LotteryHandler struct {
	db *gorm.DB
}

func NewLotteryHandler(db *gorm.DB) *LotteryHandler {
	return &LotteryHandler{db: db}
}

// LotteryEventResponse 统一对外输出的抽奖活动结构，中奖者仅携带公开资料，禁止透出学号与教务字段。
type LotteryEventResponse struct {
	ID               uint                       `json:"id"`
	CreatedAt        time.Time                  `json:"created_at"`
	UpdatedAt        time.Time                  `json:"updated_at"`
	Title            string                     `json:"title"`
	Description      string                     `json:"description"`
	PrizeName        string                     `json:"prize_name"`
	DrawTime         time.Time                  `json:"draw_time"`
	Status           int                        `json:"status"`
	WinnerID         *uint                      `json:"winner_id"`
	DrawnAt          *time.Time                 `json:"drawn_at,omitempty"`
	DrawMode         string                     `json:"draw_mode,omitempty"`
	Winner           *models.PublicUserResponse `json:"winner,omitempty"`
	ParticipantCount int64                      `json:"participant_count"`
	Joined           bool                       `json:"joined,omitempty"`
}

// LotteryParticipantUserResponse 抽奖管理端参与者最小资料视图，不包含学号、邮箱、风控或教务详情。
type LotteryParticipantUserResponse struct {
	ID       uint   `json:"id"`
	Nickname string `json:"nickname"`
	Avatar   string `json:"avatar"`
	Exp      int    `json:"exp"`
	Level    int    `json:"level"`
}

// LotteryParticipantResponse 管理端参与者列表项，同时给出报名时权重与按当前等级实时计算的权重。
type LotteryParticipantResponse struct {
	ID            uint                           `json:"id"`
	CreatedAt     time.Time                      `json:"created_at"`
	LotteryID     uint                           `json:"lottery_id"`
	UserID        uint                           `json:"user_id"`
	Weight        int                            `json:"weight"`
	CurrentWeight int                            `json:"current_weight"`
	User          LotteryParticipantUserResponse `json:"user"`
}

func toLotteryEventResponse(event models.LotteryEvent, participantCount int64, joined bool) LotteryEventResponse {
	resp := LotteryEventResponse{
		ID:               event.ID,
		CreatedAt:        event.CreatedAt,
		UpdatedAt:        event.UpdatedAt,
		Title:            event.Title,
		Description:      event.Description,
		PrizeName:        event.PrizeName,
		DrawTime:         event.DrawTime,
		Status:           event.Status,
		WinnerID:         event.WinnerID,
		DrawnAt:          event.DrawnAt,
		DrawMode:         event.DrawMode,
		ParticipantCount: participantCount,
		Joined:           joined,
	}
	if event.Winner != nil && event.Winner.ID != 0 {
		pub := models.PublicUser(*event.Winner)
		resp.Winner = &pub
	}
	return resp
}

func findCurrentLotteryEvent(db *gorm.DB, preloadWinner bool) (models.LotteryEvent, error) {
	query := func() *gorm.DB {
		q := db.Model(&models.LotteryEvent{})
		if preloadWinner {
			q = q.Preload("Winner")
		}
		return q
	}

	var event models.LotteryEvent
	if err := query().Where("status = ?", models.LotteryStatusOngoing).
		Order("created_at DESC, id DESC").
		First(&event).Error; err == nil {
		return event, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return event, err
	}

	if err := query().Where("status IN ?", []int{models.LotteryStatusDrawn, models.LotteryStatusNoWinner}).
		Order("COALESCE(drawn_at, draw_time) DESC, id DESC").
		First(&event).Error; err == nil {
		return event, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return event, err
	}

	err := query().Order("created_at DESC, id DESC").First(&event).Error
	return event, err
}

func countParticipantsByLotteryIDs(db *gorm.DB, eventIDs []uint) (map[uint]int64, error) {
	counts := make(map[uint]int64, len(eventIDs))
	if len(eventIDs) == 0 {
		return counts, nil
	}
	var rows []struct {
		LotteryID uint
		Total     int64
	}
	if err := db.Model(&models.LotteryParticipant{}).
		Select("lottery_id, COUNT(*) AS total").
		Where("lottery_id IN ?", eventIDs).
		Group("lottery_id").
		Scan(&rows).Error; err != nil {
		return nil, err
	}
	for _, r := range rows {
		counts[r.LotteryID] = r.Total
	}
	return counts, nil
}

func parseLotteryPagination(c *gin.Context, defaultSize, maxSize int) (int, int) {
	page, err := strconv.Atoi(c.DefaultQuery("page", "1"))
	if err != nil || page < 1 {
		page = 1
	}
	pageSize, err := strconv.Atoi(c.DefaultQuery("page_size", strconv.Itoa(defaultSize)))
	if err != nil || pageSize < 1 {
		pageSize = defaultSize
	}
	if pageSize > maxSize {
		pageSize = maxSize
	}
	return page, pageSize
}

func recordLotteryAdminLog(db *gorm.DB, c *gin.Context, action, target, detail string) {
	operatorID := c.GetUint("user_id")
	if operatorID == 0 || !db.Migrator().HasTable(&models.AdminLog{}) {
		return
	}
	var operator models.User
	if err := db.Select("nickname").First(&operator, operatorID).Error; err != nil || operator.Nickname == "" {
		operator.Nickname = "Super Admin"
	}
	_ = db.Create(&models.AdminLog{
		AdminID:   operatorID,
		AdminName: operator.Nickname,
		Action:    action,
		Target:    target,
		Detail:    detail,
	}).Error
}

// GetCurrent 获取当前正在进行或最近开奖的活动
func (h *LotteryHandler) GetCurrent(c *gin.Context) {
	event, err := findCurrentLotteryEvent(h.db, true)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			middleware.WriteAPIError(c, http.StatusNotFound, "lottery_not_found", "暂无抽奖活动", nil)
			return
		}
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_load_failed", "加载抽奖活动失败", nil)
		return
	}

	var participantCount int64
	if err := h.db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&participantCount).Error; err != nil {
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_load_failed", "加载抽奖活动失败", nil)
		return
	}

	var joined bool
	var myWeight int
	var academicConfigured bool
	if userID := c.GetUint("user_id"); userID != 0 {
		var user models.User
		if err := h.db.Select("id", "exp").First(&user, userID).Error; err == nil {
			var p models.LotteryParticipant
			if err := h.db.Where("lottery_id = ? AND user_id = ?", event.ID, userID).First(&p).Error; err == nil {
				joined = true
				if event.Status == models.LotteryStatusOngoing {
					myWeight = services.CalculateLotteryWeightByLevel(user.Exp)
				} else {
					myWeight = p.Weight
				}
			}
		}
		if h.db.Migrator().HasTable(&models.AcademicAccountConfig{}) {
			if configured, err := models.HasAcademicConfig(h.db, userID); err == nil {
				academicConfigured = configured
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"event":               toLotteryEventResponse(event, participantCount, joined),
		"participant_count":   participantCount,
		"joined":              joined,
		"my_weight":           myWeight,
		"academic_configured": academicConfigured,
		"server_time":         time.Now().UTC().Format(time.RFC3339),
	})
}

// GetHistory 分页获取往期已开奖/已流拍抽奖历史
func (h *LotteryHandler) GetHistory(c *gin.Context) {
	page, pageSize := parseLotteryPagination(c, 10, 50)
	statuses := []int{models.LotteryStatusDrawn, models.LotteryStatusNoWinner}

	var total int64
	if err := h.db.Model(&models.LotteryEvent{}).Where("status IN ?", statuses).Count(&total).Error; err != nil {
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_history_failed", "加载往期抽奖失败", nil)
		return
	}

	var events []models.LotteryEvent
	if err := h.db.Where("status IN ?", statuses).
		Preload("Winner").
		Order("COALESCE(drawn_at, draw_time) DESC, id DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&events).Error; err != nil {
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_history_failed", "加载往期抽奖失败", nil)
		return
	}

	eventIDs := make([]uint, len(events))
	for i, ev := range events {
		eventIDs[i] = ev.ID
	}
	counts, err := countParticipantsByLotteryIDs(h.db, eventIDs)
	if err != nil {
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_history_failed", "加载往期抽奖失败", nil)
		return
	}

	joinedSet := make(map[uint]bool)
	if userID := c.GetUint("user_id"); userID != 0 && len(eventIDs) > 0 {
		var joinedIDs []uint
		if err := h.db.Model(&models.LotteryParticipant{}).
			Where("user_id = ? AND lottery_id IN ?", userID, eventIDs).
			Pluck("lottery_id", &joinedIDs).Error; err == nil {
			for _, id := range joinedIDs {
				joinedSet[id] = true
			}
		}
	}

	items := make([]LotteryEventResponse, len(events))
	for i, ev := range events {
		items[i] = toLotteryEventResponse(ev, counts[ev.ID], joinedSet[ev.ID])
	}

	c.JSON(http.StatusOK, gin.H{
		"items":     items,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// Join 参与抽奖（要求已登记教务配置，不区分普通用户或管理员）
func (h *LotteryHandler) Join(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		middleware.WriteAPIError(c, http.StatusUnauthorized, "authentication_required", "请先登录后再参与抽奖", nil)
		return
	}

	eventID, err := strconv.ParseUint(c.Param("id"), 10, strconv.IntSize)
	if err != nil || eventID == 0 {
		middleware.WriteAPIError(c, http.StatusBadRequest, "lottery_id_invalid", "抽奖活动 ID 无效", nil)
		return
	}

	status, code, message := http.StatusInternalServerError, "lottery_join_failed", "参与抽奖失败，请稍后重试"
	reject := func(httpStatus int, errorCode, text string) error {
		status, code, message = httpStatus, errorCode, text
		return errors.New(errorCode)
	}
	var weight int
	err = h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		var event models.LotteryEvent
		// 与取消、删除及开奖共用活动行锁，状态检查与报名写入必须共同提交。
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&event, uint(eventID)).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return reject(http.StatusNotFound, "lottery_not_found", "抽奖活动不存在")
			}
			return err
		}
		if event.Status != models.LotteryStatusOngoing {
			return reject(http.StatusBadRequest, "lottery_already_drawn", "该抽奖已经结束")
		}
		if !event.DrawTime.After(time.Now()) {
			return reject(http.StatusBadRequest, "lottery_join_closed", "该抽奖已停止参与")
		}
		configured, err := models.HasAcademicConfig(tx, userID)
		if err != nil {
			return reject(http.StatusServiceUnavailable, "academic_config_unavailable", "教务配置暂时无法读取，请稍后重试")
		}
		if !configured {
			return reject(http.StatusForbidden, "edu_binding_required", "请先完成教务连接并同步课表配置后再参与抽奖")
		}
		var user models.User
		if err := tx.Select("id", "exp", "account_status").First(&user, userID).Error; err != nil {
			return reject(http.StatusUnauthorized, "authentication_required", "用户不存在")
		}
		if user.AccountStatus != "" && user.AccountStatus != "active" {
			return reject(http.StatusUnauthorized, "account_unavailable", "账号当前不可用")
		}
		weight = services.CalculateLotteryWeightByLevel(user.Exp)
		participant := models.LotteryParticipant{LotteryID: event.ID, UserID: user.ID, Weight: weight}
		if err := tx.Create(&participant).Error; err != nil {
			if isUniqueConstraintError(err) {
				return reject(http.StatusConflict, "lottery_already_joined", "你已经参与过该抽奖活动了")
			}
			return err
		}
		return nil
	})
	if err != nil {
		middleware.WriteAPIError(c, status, code, message, nil)
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "参与成功",
		"weight":  weight,
	})
}

// Draw 超级管理员兜底手动补开（仅允许到点后对未开奖活动补开）
func (h *LotteryHandler) Draw(c *gin.Context) {
	eventIDStr := c.Param("id")
	eventID, err := strconv.ParseUint(eventIDStr, 10, strconv.IntSize)
	if err != nil || eventID == 0 {
		middleware.WriteAPIError(c, http.StatusBadRequest, "lottery_id_invalid", "抽奖活动 ID 无效", nil)
		return
	}

	var event models.LotteryEvent
	if err := h.db.First(&event, uint(eventID)).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			middleware.WriteAPIError(c, http.StatusNotFound, "lottery_not_found", "抽奖活动不存在", nil)
			return
		}
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_draw_failed", "查询抽奖活动失败", nil)
		return
	}
	if event.Status != models.LotteryStatusOngoing {
		middleware.WriteAPIError(c, http.StatusBadRequest, "lottery_already_drawn", "该抽奖已经结束", nil)
		return
	}
	if event.DrawTime.After(time.Now()) {
		middleware.WriteAPIError(c, http.StatusBadRequest, "lottery_not_ready", "还未到开奖时间", nil)
		return
	}

	err = tasks.ExecuteDrawWithMode(h.db, uint(eventID), models.LotteryDrawModeManual)
	if err != nil {
		if errors.Is(err, tasks.ErrLotteryNotReady) {
			middleware.WriteAPIError(c, http.StatusBadRequest, "lottery_not_ready", "还未到开奖时间", nil)
			return
		}
		if errors.Is(err, tasks.ErrLotteryAlreadyDrawn) {
			middleware.WriteAPIError(c, http.StatusBadRequest, "lottery_already_drawn", "该抽奖已经结束", nil)
			return
		}
		middleware.WriteAPIError(c, http.StatusInternalServerError, "lottery_draw_failed", "抽奖开奖失败", nil)
		return
	}

	recordLotteryAdminLog(
		h.db,
		c,
		"手动补开抽奖",
		fmt.Sprintf("抽奖 #%d（%s）", event.ID, event.Title),
		fmt.Sprintf("到点兜底补开奖品：%s", event.PrizeName),
	)

	c.JSON(http.StatusOK, gin.H{"message": "开奖成功"})
}
