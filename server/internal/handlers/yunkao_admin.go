package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// YunkaoAdminHandler 融智云考助手管理员处理器
type YunkaoAdminHandler struct {
	db *gorm.DB
}

func NewYunkaoAdminHandler(db *gorm.DB) *YunkaoAdminHandler {
	return &YunkaoAdminHandler{db: db}
}

// ==================== 提供商管理 ====================

func (h *YunkaoAdminHandler) GetProviders(c *gin.Context) {
	var providers []models.YunkaoAiProvider
	h.db.Order("priority DESC, id ASC").Find(&providers)
	for i := range providers {
		if providers[i].APIKey != "" {
			providers[i].APIKey = "********"
		}
	}
	c.JSON(http.StatusOK, gin.H{"providers": providers})
}

func (h *YunkaoAdminHandler) CreateProvider(c *gin.Context) {
	var provider models.YunkaoAiProvider
	if err := c.ShouldBindJSON(&provider); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if provider.ProviderKey == "" || provider.Label == "" || provider.BaseURL == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "provider_key, label, base_url 为必填项"})
		return
	}
	if err := h.db.Create(&provider).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建提供商失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"success": true, "provider": provider})
}

func (h *YunkaoAdminHandler) UpdateProvider(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的提供商 ID"})
		return
	}

	var existing models.YunkaoAiProvider
	if err := h.db.First(&existing, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "提供商不存在"})
		return
	}

	var updates map[string]interface{}
	if err := c.ShouldBindJSON(&updates); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 保护 ID 字段不被修改
	delete(updates, "id")
	updates["updated_at"] = time.Now()

	h.db.Model(&existing).Updates(updates)
	c.JSON(http.StatusOK, gin.H{"success": true})
}

func (h *YunkaoAdminHandler) DeleteProvider(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	if err := h.db.Delete(&models.YunkaoAiProvider{}, id).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}
	// 同时删除关联的模型
	h.db.Where("provider_id = ?", id).Delete(&models.YunkaoAiModel{})
	c.JSON(http.StatusOK, gin.H{"success": true})
}

// FetchProviderModels 从提供商的 OpenAI 兼容 models 接口读取可用模型。
func (h *YunkaoAdminHandler) FetchProviderModels(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的提供商 ID"})
		return
	}

	var provider models.YunkaoAiProvider
	if err := h.db.First(&provider, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "提供商不存在"})
		return
	}
	if strings.TrimSpace(provider.APIKey) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该提供商尚未配置 API Key"})
		return
	}

	baseURL := strings.TrimRight(strings.TrimSpace(provider.BaseURL), "/")
	if _, err := url.ParseRequestURI(baseURL); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "提供商 Base URL 无效"})
		return
	}

	candidates := []string{baseURL + "/models"}
	if !strings.HasSuffix(strings.ToLower(baseURL), "/v1") {
		candidates = append(candidates, baseURL+"/v1/models")
	}

	client := &http.Client{Timeout: 15 * time.Second}
	var lastErr error
	for _, endpoint := range candidates {
		req, err := http.NewRequestWithContext(c.Request.Context(), http.MethodGet, endpoint, nil)
		if err != nil {
			lastErr = err
			continue
		}
		authHeader := strings.TrimSpace(provider.AuthHeader)
		if authHeader == "" {
			authHeader = "Authorization"
		}
		authPrefix := provider.AuthPrefix
		if authPrefix == "" {
			authPrefix = "Bearer "
		}
		req.Header.Set(authHeader, authPrefix+provider.APIKey)
		req.Header.Set("Accept", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		var payload struct {
			Data []struct {
				ID string `json:"id"`
			} `json:"data"`
			Models []interface{} `json:"models"`
			Error  interface{}   `json:"error"`
		}
		decodeErr := json.NewDecoder(resp.Body).Decode(&payload)
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			lastErr = fmt.Errorf("接口返回 HTTP %d", resp.StatusCode)
			continue
		}
		if decodeErr != nil {
			lastErr = fmt.Errorf("无法解析模型列表")
			continue
		}

		modelSet := make(map[string]struct{})
		for _, item := range payload.Data {
			if name := strings.TrimSpace(item.ID); name != "" {
				modelSet[name] = struct{}{}
			}
		}
		for _, item := range payload.Models {
			switch value := item.(type) {
			case string:
				if name := strings.TrimSpace(value); name != "" {
					modelSet[name] = struct{}{}
				}
			case map[string]interface{}:
				if raw, ok := value["id"].(string); ok {
					if name := strings.TrimSpace(raw); name != "" {
						modelSet[name] = struct{}{}
					}
				}
			}
		}

		modelNames := make([]string, 0, len(modelSet))
		for name := range modelSet {
			modelNames = append(modelNames, name)
		}
		sort.Strings(modelNames)
		c.JSON(http.StatusOK, gin.H{
			"provider_id":  provider.ID,
			"provider_key": provider.ProviderKey,
			"models":       modelNames,
		})
		return
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("未返回可用模型")
	}
	c.JSON(http.StatusBadGateway, gin.H{"error": "获取模型列表失败: " + lastErr.Error()})
}

// ==================== 模型管理 ====================

func (h *YunkaoAdminHandler) GetModels(c *gin.Context) {
	providerKey := c.Query("provider_key")
	var models []models.YunkaoAiModel
	query := h.db.Order("priority DESC, id ASC")
	if providerKey != "" {
		query = query.Where("provider_key = ?", providerKey)
	}
	query.Find(&models)
	c.JSON(http.StatusOK, gin.H{"models": models})
}

func (h *YunkaoAdminHandler) CreateModel(c *gin.Context) {
	var model models.YunkaoAiModel
	if err := c.ShouldBindJSON(&model); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if model.ModelName == "" || model.ProviderKey == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "model_name, provider_key 为必填项"})
		return
	}

	// 查找 provider_id
	var provider models.YunkaoAiProvider
	if err := h.db.Where("provider_key = ?", model.ProviderKey).First(&provider).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "指定的提供商不存在"})
		return
	}
	model.ProviderID = provider.ID

	if err := h.db.Create(&model).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建模型失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"success": true, "model": model})
}

func (h *YunkaoAdminHandler) UpdateModel(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的模型 ID"})
		return
	}

	var existing models.YunkaoAiModel
	if err := h.db.First(&existing, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "模型不存在"})
		return
	}

	var updates map[string]interface{}
	if err := c.ShouldBindJSON(&updates); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	delete(updates, "id")
	updates["updated_at"] = time.Now()

	h.db.Model(&existing).Updates(updates)
	c.JSON(http.StatusOK, gin.H{"success": true})
}

func (h *YunkaoAdminHandler) DeleteModel(c *gin.Context) {
	id, _ := strconv.Atoi(c.Param("id"))
	h.db.Delete(&models.YunkaoAiModel{}, id)
	c.JSON(http.StatusOK, gin.H{"success": true})
}

// ==================== 钱包管理 ====================

func (h *YunkaoAdminHandler) GetUserWallets(c *gin.Context) {
	search := c.Query("search")
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	type WalletWithUser struct {
		models.YunkaoWallet
		StudentID string `json:"student_id"`
		Nickname  string `json:"nickname"`
	}

	var total int64
	query := h.db.Table("yunkao_wallets").
		Joins("JOIN users ON users.id = yunkao_wallets.user_id")
	if search != "" {
		query = query.Where("users.student_id LIKE ? OR users.nickname LIKE ?", "%"+search+"%", "%"+search+"%")
	}
	query.Count(&total)

	var results []WalletWithUser
	query.Select("yunkao_wallets.*, users.student_id, users.nickname").
		Order("yunkao_wallets.balance_cents DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Scan(&results)

	c.JSON(http.StatusOK, gin.H{
		"wallets":   results,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

func (h *YunkaoAdminHandler) RechargeWallet(c *gin.Context) {
	var req struct {
		UserID      uint   `json:"user_id" binding:"required"`
		AmountCents int    `json:"amount_cents" binding:"required"`
		Remark      string `json:"remark"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.AmountCents <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "充值金额必须大于 0"})
		return
	}

	operatorID, _ := c.Get("user_id")

	// 查找或创建钱包
	var wallet models.YunkaoWallet
	if err := h.db.Where("user_id = ?", req.UserID).First(&wallet).Error; err != nil {
		wallet = models.YunkaoWallet{UserID: req.UserID, BalanceCents: 0}
		h.db.Create(&wallet)
	}

	wallet.BalanceCents += req.AmountCents
	wallet.TotalRechargedCents += req.AmountCents
	h.db.Save(&wallet)

	// 创建充值订单
	order := models.YunkaoRechargeOrder{
		UserID:      req.UserID,
		AmountCents: req.AmountCents,
		Type:        "manual",
		Status:      "completed",
		OperatorID:  operatorID.(uint),
		Remark:      req.Remark,
	}
	h.db.Create(&order)

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"wallet":  wallet,
		"order":   order,
	})
}

func (h *YunkaoAdminHandler) DeductWallet(c *gin.Context) {
	var req struct {
		UserID      uint   `json:"user_id" binding:"required"`
		AmountCents int    `json:"amount_cents" binding:"required"`
		Remark      string `json:"remark"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.AmountCents <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "扣减金额必须大于 0"})
		return
	}

	var wallet models.YunkaoWallet
	if err := h.db.Where("user_id = ?", req.UserID).First(&wallet).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户钱包不存在"})
		return
	}

	wallet.BalanceCents -= req.AmountCents
	if wallet.BalanceCents < 0 {
		wallet.BalanceCents = 0
	}
	wallet.TotalSpentCents += req.AmountCents
	h.db.Save(&wallet)

	c.JSON(http.StatusOK, gin.H{"success": true, "wallet": wallet})
}

// ==================== 错题审核 ====================

func (h *YunkaoAdminHandler) GetWrongReports(c *gin.Context) {
	status := c.DefaultQuery("status", "pending")
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	var total int64
	query := h.db.Model(&models.YunkaoWrongReport{})
	if status != "" && status != "all" {
		query = query.Where("status = ?", status)
	}
	query.Count(&total)

	var reports []models.YunkaoWrongReport
	query.Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&reports)

	c.JSON(http.StatusOK, gin.H{
		"reports":   reports,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

func (h *YunkaoAdminHandler) ReviewWrongReport(c *gin.Context) {
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的报告 ID"})
		return
	}

	var req struct {
		Action      string `json:"action" binding:"required"` // approve / reject
		FinalAnswer string `json:"final_answer"`              // 人工修正后的最终答案
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	reviewerID, _ := c.Get("user_id")

	var report models.YunkaoWrongReport
	if err := h.db.First(&report, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "报告不存在"})
		return
	}

	now := time.Now()

	if req.Action == "approve" {
		report.Status = "approved"
		if req.FinalAnswer != "" {
			report.FinalAnswer = req.FinalAnswer
		} else {
			report.FinalAnswer = report.RewriteAnswer
		}
		report.ReviewedBy = reviewerID.(uint)
		report.ReviewedAt = &now
		h.db.Save(&report)

		// 确认写入缓存（verified 状态）
		finalAnswer := report.FinalAnswer
		if finalAnswer == "" {
			finalAnswer = report.CurrentAnswer
		}
		if finalAnswer != "" {
			h.db.Model(&models.YunkaoQuestionCache{}).
				Where("question_hash = ?", report.QuestionHash).
				Updates(map[string]interface{}{
					"ai_answer":   finalAnswer,
					"status":      "verified",
					"verified_by": reviewerID.(uint),
					"verified_at": now,
					"updated_at":  now,
				})
		}
	} else if req.Action == "reject" {
		report.Status = "rejected"
		report.ReviewedBy = reviewerID.(uint)
		report.ReviewedAt = &now
		h.db.Save(&report)

		// 恢复缓存为 disabled
		h.db.Model(&models.YunkaoQuestionCache{}).
			Where("question_hash = ?", report.QuestionHash).
			Updates(map[string]interface{}{
				"status":     "disabled",
				"updated_at": now,
			})
	} else {
		c.JSON(http.StatusBadRequest, gin.H{"error": "action 必须是 approve 或 reject"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"success": true, "report": report})
}

// ==================== 使用日志 ====================

func (h *YunkaoAdminHandler) GetUsageLogs(c *gin.Context) {
	search := c.Query("search")
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	type UsageLogWithUser struct {
		models.YunkaoUsageLog
		StudentID string `json:"student_id"`
		Nickname  string `json:"nickname"`
	}

	var total int64
	query := h.db.Table("yunkao_usage_logs").
		Joins("JOIN users ON users.id = yunkao_usage_logs.user_id")
	if search != "" {
		query = query.Where("users.student_id LIKE ? OR users.nickname LIKE ? OR yunkao_usage_logs.question_hash LIKE ?",
			"%"+search+"%", "%"+search+"%", "%"+search+"%")
	}
	query.Count(&total)

	var results []UsageLogWithUser
	query.Select("yunkao_usage_logs.*, users.student_id, users.nickname").
		Order("yunkao_usage_logs.created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Scan(&results)

	c.JSON(http.StatusOK, gin.H{
		"logs":      results,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// GetAdminStats 管理员统计概览
func (h *YunkaoAdminHandler) GetAdminStats(c *gin.Context) {
	var totalUsers int64
	h.db.Model(&models.User{}).Count(&totalUsers)

	var totalBalanceCents int64
	h.db.Model(&models.YunkaoWallet{}).Select("COALESCE(SUM(balance_cents), 0)").Scan(&totalBalanceCents)

	var totalUsage int64
	h.db.Model(&models.YunkaoUsageLog{}).Count(&totalUsage)

	var pendingReports int64
	h.db.Model(&models.YunkaoWrongReport{}).Where("status = ?", "pending").Count(&pendingReports)

	var totalBilledCents int64
	h.db.Model(&models.YunkaoUsageLog{}).Select("COALESCE(SUM(billed_amount_cents), 0)").Scan(&totalBilledCents)

	var cacheCount int64
	h.db.Model(&models.YunkaoQuestionCache{}).Count(&cacheCount)

	c.JSON(http.StatusOK, gin.H{
		"total_users":         totalUsers,
		"total_balance_cents": totalBalanceCents,
		"total_balance_yuan":  float64(totalBalanceCents) / 100.0,
		"total_usage":         totalUsage,
		"pending_reports":     pendingReports,
		"total_billed_cents":  totalBilledCents,
		"total_billed_yuan":   float64(totalBilledCents) / 100.0,
		"cache_count":         cacheCount,
	})
}

// seedDefaultProviders 初始化默认提供商和模型数据
func (h *YunkaoAdminHandler) SeedDefaultProviders() {
	var count int64
	h.db.Model(&models.YunkaoAiProvider{}).Count(&count)
	if count > 0 {
		return // 已有数据，跳过
	}

	providers := []models.YunkaoAiProvider{
		{ProviderKey: "deepseek", Label: "DeepSeek", BaseURL: "https://api.deepseek.com", AuthHeader: "Authorization", AuthPrefix: "Bearer ", Enabled: true, Priority: 10},
		{ProviderKey: "openai", Label: "OpenAI / GPT", BaseURL: "https://api.openai.com/v1", AuthHeader: "Authorization", AuthPrefix: "Bearer ", Enabled: true, Priority: 5},
		{ProviderKey: "kimi", Label: "Kimi / Moonshot", BaseURL: "https://api.moonshot.cn/v1", AuthHeader: "Authorization", AuthPrefix: "Bearer ", Enabled: true, Priority: 4},
		{ProviderKey: "qwen", Label: "千问 / Qwen", BaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", AuthHeader: "Authorization", AuthPrefix: "Bearer ", Enabled: true, Priority: 3},
		{ProviderKey: "glm", Label: "智谱 / GLM", BaseURL: "https://open.bigmodel.cn/api/paas/v4", AuthHeader: "Authorization", AuthPrefix: "Bearer ", Enabled: true, Priority: 2},
		{ProviderKey: "mimo", Label: "小米 MiMo", BaseURL: "https://api.xiaomimimo.com/v1", AuthHeader: "api-key", AuthPrefix: "", Enabled: true, Priority: 1},
	}

	for _, p := range providers {
		h.db.Create(&p)

		// 为每个提供商创建默认模型
		defaultModel := getDefaultModelForProvider(p.ProviderKey)
		if defaultModel != nil {
			defaultModel.ProviderID = p.ID
			defaultModel.ProviderKey = p.ProviderKey
			h.db.Create(defaultModel)
		}
	}

	log.Printf("[Yunkao] 已初始化 %d 个默认提供商及模型", len(providers))
}

func getDefaultModelForProvider(providerKey string) *models.YunkaoAiModel {
	switch providerKey {
	case "deepseek":
		return &models.YunkaoAiModel{
			ModelName:                 "deepseek-v4-flash",
			Label:                     "DeepSeek V4 Flash (推荐)",
			SupportsVision:            false,
			CacheHitInputPrice1MCents: 10,  // ¥0.10 / 百万 tokens
			LiveInputPrice1MCents:     200, // ¥2.00 / 百万 tokens
			OutputPrice1MCents:        600, // ¥6.00 / 百万 tokens
			IsDefault:                 true,
			Enabled:                   true,
			Priority:                  10,
		}
	case "openai":
		return &models.YunkaoAiModel{
			ModelName:                 "gpt-4o-mini",
			Label:                     "GPT-4o Mini",
			SupportsVision:            true,
			CacheHitInputPrice1MCents: 20,
			LiveInputPrice1MCents:     600,
			OutputPrice1MCents:        2400,
			IsDefault:                 false,
			Enabled:                   true,
			Priority:                  5,
		}
	case "kimi":
		return &models.YunkaoAiModel{
			ModelName:                 "kimi-k2.6",
			Label:                     "Kimi K2.6",
			SupportsVision:            true,
			CacheHitInputPrice1MCents: 10,
			LiveInputPrice1MCents:     200,
			OutputPrice1MCents:        600,
			Enabled:                   true,
			Priority:                  4,
		}
	case "qwen":
		return &models.YunkaoAiModel{
			ModelName:                 "qwen-vl-plus",
			Label:                     "通义千问 VL Plus",
			SupportsVision:            true,
			CacheHitInputPrice1MCents: 10,
			LiveInputPrice1MCents:     200,
			OutputPrice1MCents:        600,
			Enabled:                   true,
			Priority:                  3,
		}
	case "glm":
		return &models.YunkaoAiModel{
			ModelName:                 "glm-5.1",
			Label:                     "智谱 GLM-5.1",
			SupportsVision:            true,
			CacheHitInputPrice1MCents: 10,
			LiveInputPrice1MCents:     200,
			OutputPrice1MCents:        600,
			Enabled:                   true,
			Priority:                  2,
		}
	case "mimo":
		return &models.YunkaoAiModel{
			ModelName:                 "mimo-v2.5-pro",
			Label:                     "小米 MiMo V2.5 Pro",
			SupportsVision:            true,
			CacheHitInputPrice1MCents: 10,
			LiveInputPrice1MCents:     200,
			OutputPrice1MCents:        600,
			Enabled:                   true,
			Priority:                  1,
		}
	}
	return nil
}
