package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/sync/singleflight"
	"golang.org/x/time/rate"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// YunkaoSolveHandler 融智云考助手独立 AI 答题处理器
type YunkaoSolveHandler struct {
	db           *gorm.DB
	requestGroup singleflight.Group
	restyClient  *resty.Client
}

var yunkaoRateLimiters = sync.Map{}

var (
	reYWhitespace  = regexp.MustCompile(`\s+`)
	reYImgTag      = regexp.MustCompile(`<img[^>]+(?:src|data-src)=\\?["'](https?://[^"'\\]+)\\?["']`)
	reYDirectLink  = regexp.MustCompile(`https?://[^"'\\]+(?:storage\.yuketang\.cn|qn-storage)[^"'\\]+|https?://[^"'\\]+\.(?:png|jpg|jpeg|webp|gif|bmp)(?:\?[^"'\\]*)?`)
	reYIndexTarget = regexp.MustCompile(`"__originalIndex":\d+,?`)
)

func getYunkaoRateLimiter(uid uint) *rate.Limiter {
	limiter, _ := yunkaoRateLimiters.LoadOrStore(uid, rate.NewLimiter(rate.Every(time.Hour/10), 10))
	return limiter.(*rate.Limiter)
}

func NewYunkaoSolveHandler(db *gorm.DB) *YunkaoSolveHandler {
	return &YunkaoSolveHandler{
		db:          db,
		restyClient: resty.New(),
	}
}

// YunkaoSolveRequest 融智云考助手答题请求
type YunkaoSolveRequest struct {
	QuestionType string      `json:"question_type"`
	RawContent   interface{} `json:"raw_content"`
	ContentText  string      `json:"content_text"`
	ModelID      uint        `json:"model_id"`     // 指定模型 ID
	ExportJobID  string      `json:"export_job_id"` // 导出批次
	HasImage     bool        `json:"has_image"`     // 是否图片题
	ForceRefresh bool        `json:"force_refresh"` // 跳过缓存直接问 AI
}

type yunkaoCallResult struct {
	Answer           string
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
}

type yunkaoSolveResult struct {
	Answer           string
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
	Source           string // "cache" / "ai"
	ProviderKey      string
	ModelName        string
	ModelID          uint
	CacheRefTokens   int
}

func yCleanText(text string) string {
	text = strings.TrimSpace(text)
	text = strings.ReplaceAll(text, "\n", "")
	text = strings.ReplaceAll(text, "\r", "")
	text = reYWhitespace.ReplaceAllString(text, " ")
	return text
}

func yGenerateHash(qType, content string) string {
	hash := sha256.New()
	hash.Write([]byte(qType + "|" + content + "|yunkao_v2"))
	return hex.EncodeToString(hash.Sum(nil))
}

func yBuildHash(req YunkaoSolveRequest) (string, string) {
	cleaned := yCleanText(req.ContentText)
	hashText := reYIndexTarget.ReplaceAllString(cleaned, "")
	return cleaned, yGenerateHash(req.QuestionType, hashText)
}

func yEstimateTokens(text string) int {
	runeCount := len([]rune(strings.TrimSpace(text)))
	if runeCount == 0 {
		return 0
	}
	return int(math.Ceil(float64(runeCount) / 2.2))
}

// calculateBillingCents 三段式计费：缓存命中输入 / 实时输入 / 输出
func calculateBillingCents(model models.YunkaoAiModel, promptTokens, completionTokens int, cacheHit bool) int {
	if cacheHit {
		// 缓存命中：按 cache_hit_input_price_1m_cents 计费输入部分
		inputCost := int(math.Ceil(float64(promptTokens) * float64(model.CacheHitInputPrice1MCents) / 1_000_000.0))
		return inputCost
	}
	// 缓存未命中：按实时输入价 + 输出价
	inputCost := int(math.Ceil(float64(promptTokens) * float64(model.LiveInputPrice1MCents) / 1_000_000.0))
	outputCost := int(math.Ceil(float64(completionTokens) * float64(model.OutputPrice1MCents) / 1_000_000.0))
	return inputCost + outputCost
}

func (h *YunkaoSolveHandler) callYunkaoAI(provider models.YunkaoAiProvider, model models.YunkaoAiModel, questionType, cleanedText string, hasImage bool) (yunkaoCallResult, error) {
	prompt := fmt.Sprintf(`你是一个专业的大学辅助答题助手。
【重点警告】如果是选择题，请输出正确选项的字母和【完整文字内容】。如果选项是纯图片，或者你无法用文字描述，请务必输出对应选项的字母（如 A、B、C、D）。
绝对不要包含任何解析或废话。
题型：%s
题目内容：%s`, questionType, cleanedText)

	imageUrls := extractYunkaoImageURLs(cleanedText)

	var reqBody map[string]interface{}

	if hasImage && len(imageUrls) > 0 {
		contentArray := []map[string]interface{}{
			{"type": "text", "text": prompt},
		}
		for _, url := range imageUrls {
			contentArray = append(contentArray, map[string]interface{}{
				"type":      "image_url",
				"image_url": map[string]string{"url": url},
			})
		}
		reqBody = map[string]interface{}{
			"model":       model.ModelName,
			"messages":    []map[string]interface{}{{"role": "user", "content": contentArray}},
			"temperature": 0.1,
		}
	} else {
		reqBody = map[string]interface{}{
			"model": model.ModelName,
			"messages": []map[string]string{
				{"role": "user", "content": prompt},
			},
			"temperature": 0.1,
		}
	}

	endpoint := strings.TrimRight(provider.BaseURL, "/") + "/chat/completions"
	authHeader := provider.AuthHeader
	if authHeader == "" {
		authHeader = "Authorization"
	}
	authPrefix := provider.AuthPrefix
	authValue := authPrefix + provider.APIKey

	resp, err := h.restyClient.R().
		SetHeader("Content-Type", "application/json").
		SetHeader(authHeader, authValue).
		SetBody(reqBody).
		Post(endpoint)

	if err != nil {
		return yunkaoCallResult{}, err
	}
	if resp.IsError() {
		return yunkaoCallResult{}, fmt.Errorf("API 错误: %s", resp.String())
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
	}

	if err := json.Unmarshal(resp.Body(), &result); err != nil {
		return yunkaoCallResult{}, fmt.Errorf("解析结果失败: %v", err)
	}
	if len(result.Choices) == 0 {
		return yunkaoCallResult{}, fmt.Errorf("AI 返回结果为空")
	}

	answer := strings.TrimSpace(result.Choices[0].Message.Content)
	promptTokens := result.Usage.PromptTokens
	completionTokens := result.Usage.CompletionTokens
	totalTokens := result.Usage.TotalTokens
	if promptTokens <= 0 {
		promptTokens = yEstimateTokens(cleanedText)
	}
	if completionTokens <= 0 {
		completionTokens = yEstimateTokens(answer)
	}
	if totalTokens <= 0 {
		totalTokens = promptTokens + completionTokens
	}

	return yunkaoCallResult{
		Answer:           answer,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		TotalTokens:      totalTokens,
	}, nil
}

func extractYunkaoImageURLs(text string) []string {
	seen := make(map[string]bool)
	var urls []string
	for _, m := range reYImgTag.FindAllStringSubmatch(text, -1) {
		if len(m) > 1 {
			if !seen[m[1]] {
				seen[m[1]] = true
				urls = append(urls, m[1])
			}
		}
	}
	for _, url := range reYDirectLink.FindAllString(text, -1) {
		url = strings.TrimRight(url, `\.,;"`)
		if !seen[url] {
			seen[url] = true
			urls = append(urls, url)
		}
	}
	return urls
}

// Solve 融智云考助手 AI 答题（多模型 + 三段式计费 + 缓存状态机）
func (h *YunkaoSolveHandler) Solve(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
		return
	}
	uid := userID.(uint)

	limiter := getYunkaoRateLimiter(uid)
	if !limiter.Allow() {
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "接口调用频率过高，每小时最多允许 10 次调用"})
		return
	}

	var req YunkaoSolveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 获取用户钱包
	var wallet models.YunkaoWallet
	if err := h.db.Where("user_id = ?", uid).First(&wallet).Error; err != nil {
		// 自动创建钱包
		wallet = models.YunkaoWallet{UserID: uid, BalanceCents: 0}
		h.db.Create(&wallet)
	}

	// 获取指定模型配置
	var model models.YunkaoAiModel
	if req.ModelID > 0 {
		if err := h.db.Where("id = ? AND enabled = ?", req.ModelID, true).First(&model).Error; err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "指定的模型不存在或未启用"})
			return
		}
	} else {
		// 取默认推荐模型
		if err := h.db.Where("is_default = ? AND enabled = ?", true, true).First(&model).Error; err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "暂无可用模型，请联系管理员配置"})
			return
		}
	}

	// 获取提供商配置
	var provider models.YunkaoAiProvider
	if err := h.db.Where("provider_key = ? AND enabled = ?", model.ProviderKey, true).First(&provider).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "模型关联的提供商未启用"})
		return
	}

	// 检查是否有管理员权限（免费用）
	role, _ := c.Get("role")
	isFreeUser := role == "admin" || role == "super_admin"

	cleanedText, questionHash := yBuildHash(req)

	// === 第一步：查缓存（ForceRefresh 跳过） ===
	var cached models.YunkaoQuestionCache
	if !req.ForceRefresh && h.db.Where("question_hash = ? AND status IN ?", questionHash, []string{"draft", "verified"}).First(&cached).Error == nil {
		log.Printf("[Yunkao Solve] ⚡ 缓存命中！Hash: %s, Status: %s", questionHash, cached.Status)

		billedCents := 0
		if !isFreeUser {
			billedCents = calculateBillingCents(model, cached.PromptTokens, cached.CompletionTokens, true)
			if billedCents > 0 && wallet.BalanceCents < billedCents {
				c.JSON(http.StatusForbidden, gin.H{"error": fmt.Sprintf("余额不足，缓存命中需 ¥%.2f，当前余额 ¥%.2f", float64(billedCents)/100.0, float64(wallet.BalanceCents)/100.0)})
				return
			}
			if billedCents > 0 {
				wallet.BalanceCents -= billedCents
				wallet.TotalSpentCents += billedCents
				h.db.Save(&wallet)
			}
		}

		// 记录使用日志
		usageLog := models.YunkaoUsageLog{
			UserID:           uid,
			QuestionHash:     questionHash,
			ExportJobID:      req.ExportJobID,
			ProviderKey:      model.ProviderKey,
			ModelName:        model.ModelName,
			ModelID:          model.ID,
			PromptTokens:     cached.PromptTokens,
			CompletionTokens: cached.CompletionTokens,
			TotalTokens:      cached.TotalTokens,
			BilledAmountCents: billedCents,
			CacheHit:         true,
			HasImage:         req.HasImage,
			SourceType:       "cache",
		}
		h.db.Create(&usageLog)

		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"source":  "cache",
			"answer":  cached.AiAnswer,
			"usage": gin.H{
				"prompt_tokens":          0,
				"completion_tokens":      0,
				"total_tokens":           0,
				"cache_reference_tokens": cached.TotalTokens,
			},
			"billing": gin.H{
				"billed_amount_cents": billedCents,
				"balance_after_cents": wallet.BalanceCents,
				"cache_hit":           true,
				"cache_status":        cached.Status,
			},
			"model": gin.H{
				"id":           model.ID,
				"model_name":   model.ModelName,
				"provider_key": model.ProviderKey,
			},
		})
		return
	}

	log.Printf("[Yunkao Solve] 未命中缓存，调用 AI: provider=%s model=%s", model.ProviderKey, model.ModelName)

	// === 第二步：预扣 ===
	estimatedInput := yEstimateTokens(cleanedText)
	estimatedBilled := calculateBillingCents(model, estimatedInput, 96, false)
	if !isFreeUser && estimatedBilled > 0 && wallet.BalanceCents < estimatedBilled {
		c.JSON(http.StatusForbidden, gin.H{"error": fmt.Sprintf("余额不足，本次预估需 ¥%.2f，当前余额 ¥%.2f", float64(estimatedBilled)/100.0, float64(wallet.BalanceCents)/100.0)})
		return
	}

	// === 第三步：并发控制 + 双重检查 ===
	val, err, _ := h.requestGroup.Do(questionHash, func() (interface{}, error) {
		var doubleCheck models.YunkaoQuestionCache
		if h.db.Where("question_hash = ? AND status IN ?", questionHash, []string{"draft", "verified"}).First(&doubleCheck).Error == nil {
			return yunkaoSolveResult{
				Answer:         doubleCheck.AiAnswer,
				Source:         "cache",
				ProviderKey:    doubleCheck.ProviderKey,
				ModelName:      doubleCheck.ModelName,
				CacheRefTokens: doubleCheck.TotalTokens,
			}, nil
		}

		callResult, err := h.callYunkaoAI(provider, model, req.QuestionType, cleanedText, req.HasImage)
		if err != nil {
			return nil, err
		}

		// 写入缓存（draft 状态）
		rawJSONBytes, _ := json.Marshal(req.RawContent)
		newCache := models.YunkaoQuestionCache{
			QuestionHash:     questionHash,
			QuestionType:     req.QuestionType,
			RawContent:       string(rawJSONBytes),
			AiAnswer:         callResult.Answer,
			ModelID:          model.ID,
			ModelName:        model.ModelName,
			ProviderKey:      model.ProviderKey,
			PromptTokens:     callResult.PromptTokens,
			CompletionTokens: callResult.CompletionTokens,
			TotalTokens:      callResult.TotalTokens,
			Status:           "draft",
		}

		var existing models.YunkaoQuestionCache
		if h.db.Where("question_hash = ?", questionHash).First(&existing).Error == nil {
			h.db.Model(&existing).Updates(map[string]interface{}{
				"ai_answer":         callResult.Answer,
				"model_id":          model.ID,
				"model_name":        model.ModelName,
				"provider_key":      model.ProviderKey,
				"prompt_tokens":     callResult.PromptTokens,
				"completion_tokens": callResult.CompletionTokens,
				"total_tokens":      callResult.TotalTokens,
				"status":            "draft",
				"updated_at":        time.Now(),
			})
		} else {
			h.db.Create(&newCache)
		}

		return yunkaoSolveResult{
			Answer:           callResult.Answer,
			PromptTokens:     callResult.PromptTokens,
			CompletionTokens: callResult.CompletionTokens,
			TotalTokens:      callResult.TotalTokens,
			Source:           "ai",
			ProviderKey:      model.ProviderKey,
			ModelName:        model.ModelName,
			ModelID:          model.ID,
		}, nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "AI处理失败: " + err.Error()})
		return
	}

	result := val.(yunkaoSolveResult)

	// === 第四步：实扣结算 ===
	billedCents := 0
	if !isFreeUser {
		billedCents = calculateBillingCents(model, result.PromptTokens, result.CompletionTokens, result.Source == "cache")
		if req.HasImage && model.ImageSurchargeCents > 0 && result.Source != "cache" {
			billedCents += model.ImageSurchargeCents
		}
		if billedCents > 0 {
			if wallet.BalanceCents < billedCents {
				c.JSON(http.StatusForbidden, gin.H{"error": fmt.Sprintf("余额不足，实际需 ¥%.2f", float64(billedCents)/100.0)})
				return
			}
			wallet.BalanceCents -= billedCents
			wallet.TotalSpentCents += billedCents
			h.db.Save(&wallet)
		}
	}

	// 记录使用日志
	usageLog := models.YunkaoUsageLog{
		UserID:            uid,
		QuestionHash:      questionHash,
		ExportJobID:       req.ExportJobID,
		ProviderKey:       model.ProviderKey,
		ModelName:         model.ModelName,
		ModelID:           model.ID,
		PromptTokens:      result.PromptTokens,
		CompletionTokens:  result.CompletionTokens,
		TotalTokens:       result.TotalTokens,
		BilledAmountCents: billedCents,
		CacheHit:          result.Source == "cache",
		HasImage:          req.HasImage,
		SourceType:        result.Source,
	}
	h.db.Create(&usageLog)

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"source":  result.Source,
		"answer":  result.Answer,
		"usage": gin.H{
			"prompt_tokens":          result.PromptTokens,
			"completion_tokens":      result.CompletionTokens,
			"total_tokens":           result.TotalTokens,
			"cache_reference_tokens": result.CacheRefTokens,
		},
		"billing": gin.H{
			"billed_amount_cents": billedCents,
			"balance_after_cents": wallet.BalanceCents,
			"cache_hit":           result.Source == "cache",
		},
		"model": gin.H{
			"id":           model.ID,
			"model_name":   model.ModelName,
			"provider_key": model.ProviderKey,
		},
	})
}

// GetModels 获取可用模型列表
func (h *YunkaoSolveHandler) GetModels(c *gin.Context) {
	var models []models.YunkaoAiModel
	h.db.Where("enabled = ?", true).Order("priority DESC, id ASC").Find(&models)
	c.JSON(http.StatusOK, gin.H{"models": models})
}

// ReportWrong 用户标错
func (h *YunkaoSolveHandler) ReportWrong(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var req struct {
		QuestionHash     string `json:"question_hash" binding:"required"`
		UsageLogID       uint   `json:"usage_log_id"`
		ExportJobID      string `json:"export_job_id"`
		QuestionSnapshot string `json:"question_snapshot"`
		CurrentAnswer    string `json:"current_answer"`
		ReportReason     string `json:"report_reason"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 验证：该题必须是该用户本人通过官方 AI 导出的
	if req.UsageLogID > 0 {
		var log models.YunkaoUsageLog
		if err := h.db.Where("id = ? AND user_id = ? AND source_type IN ?", req.UsageLogID, uid, []string{"official", "cache"}).First(&log).Error; err != nil {
			c.JSON(http.StatusForbidden, gin.H{"error": "只能对自己使用官方接口导出的题目标错"})
			return
		}
	}

	// 创建错题报告
	report := models.YunkaoWrongReport{
		UserID:           uid,
		QuestionHash:     req.QuestionHash,
		UsageLogID:       req.UsageLogID,
		ExportJobID:      req.ExportJobID,
		QuestionSnapshot: req.QuestionSnapshot,
		CurrentAnswer:    req.CurrentAnswer,
		ReportReason:     req.ReportReason,
		Status:           "pending",
	}
	if err := h.db.Create(&report).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交标错失败"})
		return
	}

	// 同时把缓存标记为 flagged
	h.db.Model(&models.YunkaoQuestionCache{}).
		Where("question_hash = ?", req.QuestionHash).
		Updates(map[string]interface{}{
			"status":       "flagged",
			"report_count": gorm.Expr("report_count + 1"),
			"updated_at":   time.Now(),
		})

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"message": "已提交错题报告，管理员审核后将更新缓存",
		"id":      report.ID,
	})
}

// Rewrite 请求重新 AI 作答（官方接口，强制跳过缓存）
func (h *YunkaoSolveHandler) Rewrite(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var req struct {
		QuestionHash string      `json:"question_hash" binding:"required"`
		QuestionType string      `json:"question_type" binding:"required"`
		RawContent   interface{} `json:"raw_content" binding:"required"`
		ContentText  string      `json:"content_text" binding:"required"`
		ModelID      uint        `json:"model_id"`
		ExportJobID  string      `json:"export_job_id"`
		HasImage     bool        `json:"has_image"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 检查该用户是否有此题的官方使用记录
	var usageCount int64
	h.db.Model(&models.YunkaoUsageLog{}).
		Where("user_id = ? AND question_hash = ? AND source_type IN ?", uid, req.QuestionHash, []string{"official", "cache"}).
		Count(&usageCount)
	if usageCount == 0 {
		c.JSON(http.StatusForbidden, gin.H{"error": "只能对自己使用官方接口答过的题发起重答"})
		return
	}

	// 重建请求 body 并强制刷新
	c.Request.Body = nil // 清除旧 body，让 ShouldBindJSON 重新读取
	c.Set("yunkao_force_refresh", true)

	// 构造新的 Solve 请求并直接处理
	solveReq := YunkaoSolveRequest{
		QuestionType: req.QuestionType,
		RawContent:   req.RawContent,
		ContentText:  req.ContentText,
		ModelID:      req.ModelID,
		ExportJobID:  req.ExportJobID,
		HasImage:     req.HasImage,
		ForceRefresh: true,
	}
	_ = solveReq
	// 直接走 Solve 逻辑
	h.Solve(c)
}
