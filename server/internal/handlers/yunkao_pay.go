package handlers

import (
	"crypto/subtle"
	"fmt"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/utils"
)

// YunkaoPayHandler 融智云考助手支付处理器
type YunkaoPayHandler struct {
	db *gorm.DB
}

func NewYunkaoPayHandler(db *gorm.DB) *YunkaoPayHandler {
	return &YunkaoPayHandler{db: db}
}

// resolvePayConfig 读取支付配置：环境变量 > 数据库 SystemConfig
func (h *YunkaoPayHandler) resolvePayConfig() map[string]string {
	configKeys := []string{
		models.YunkaoPayGatewayType,
		models.YunkaoPayAppID,
		models.YunkaoPayAppSecret,
		models.YunkaoPayApiURL,
		models.YunkaoPayVmqSecret,
		models.YunkaoPayVmqApiURL,
		models.YunkaoPayEnabled,
		models.YunkaoPayMinAmount,
		models.YunkaoPayNotifyBase,
	}
	var configs []models.SystemConfig
	h.db.Where("config_key IN ?", configKeys).Find(&configs)

	result := make(map[string]string)
	for _, c := range configs {
		result[c.ConfigKey] = c.ConfigValue
	}

	// 环境变量覆盖
	envMap := map[string]string{
		models.YunkaoPayAppID:     "YUNKAO_PAY_APP_ID",
		models.YunkaoPayAppSecret: "YUNKAO_PAY_APP_SECRET",
		models.YunkaoPayApiURL:    "YUNKAO_PAY_API_URL",
		models.YunkaoPayVmqSecret: "YUNKAO_PAY_VMQ_SECRET",
		models.YunkaoPayVmqApiURL: "YUNKAO_PAY_VMQ_API_URL",
		models.YunkaoPayNotifyBase: "YUNKAO_PAY_NOTIFY_BASE",
	}
	for key, env := range envMap {
		if v := os.Getenv(env); v != "" {
			result[key] = v
		}
	}
	return result
}

// getNotifyBase 获取回调基地址
func (h *YunkaoPayHandler) getNotifyBase(c *gin.Context) string {
	cfg := h.resolvePayConfig()
	if u := cfg[models.YunkaoPayNotifyBase]; u != "" {
		return strings.TrimRight(u, "/")
	}
	// Fallback: 从请求推断
	scheme := "http"
	if c.Request.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + c.Request.Host
}

// CreatePayOrder 创建充值支付订单，返回支付跳转链接
func (h *YunkaoPayHandler) CreatePayOrder(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var req struct {
		AmountCents int    `json:"amount_cents" binding:"required"`
		PayType     string `json:"pay_type"` // alipay / wechat
		Gateway     string `json:"gateway"`  // epay / vmq，不传使用默认
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.AmountCents <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "充值金额必须大于 0"})
		return
	}

	cfg := h.resolvePayConfig()
	gateway := req.Gateway
	if gateway == "" {
		gateway = cfg[models.YunkaoPayGatewayType]
		if gateway == "" {
			gateway = "epay"
		}
	}
	payType := req.PayType
	if payType != "alipay" && payType != "wechat" {
		payType = "alipay"
	}

	// 生成订单号：YK + 用户ID + 时间戳 + 随机数
	orderNo := fmt.Sprintf("YK%d%d%d", uid, time.Now().UnixMilli(), time.Now().Nanosecond()%10000)

	order := models.YunkaoPayOrder{
		OrderNo:     orderNo,
		UserID:      uid,
		AmountCents: req.AmountCents,
		Gateway:     gateway,
		PayType:     payType,
		Status:      "pending",
	}
	if err := h.db.Create(&order).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建订单失败"})
		return
	}

	money := fmt.Sprintf("%.2f", float64(req.AmountCents)/100.0)
	notifyBase := h.getNotifyBase(c)
	if notifyBase == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "站点地址未配置"})
		return
	}

	var payURL string

	if gateway == "vmq" {
		// V免签模式
		vmqSecret := cfg[models.YunkaoPayVmqSecret]
		vmqApiURL := cfg[models.YunkaoPayVmqApiURL]
		if vmqSecret == "" || vmqApiURL == "" {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "V免签支付未配置"})
			return
		}

		vType := "1" // 微信
		if payType == "alipay" {
			vType = "2"
		}
		param := "yunkao"
		price := money
		sign := utils.GenerateVmqSign(orderNo, param, vType, price, vmqSecret)

		query := url.Values{}
		query.Set("payId", orderNo)
		query.Set("param", param)
		query.Set("type", vType)
		query.Set("price", price)
		query.Set("sign", sign)
		query.Set("isHtml", "1")
		query.Set("notifyUrl", notifyBase+"/api/yunkao/pay/vmq_notify")
		query.Set("returnUrl", notifyBase)

		payURL = strings.TrimRight(vmqApiURL, "/") + "/createOrder?" + query.Encode()
	} else {
		// 易支付模式
		payAppID := cfg[models.YunkaoPayAppID]
		payAppSecret := cfg[models.YunkaoPayAppSecret]
		payApiURL := cfg[models.YunkaoPayApiURL]
		if payAppID == "" || payAppSecret == "" || payApiURL == "" {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "易支付网关未配置"})
			return
		}

		params := map[string]string{
			"pid":          payAppID,
			"type":         payType,
			"out_trade_no": orderNo,
			"notify_url":   notifyBase + "/api/yunkao/pay/notify",
			"return_url":   notifyBase,
			"name":         "融智云考助手 - 账户充值",
			"money":        money,
		}
		sign := utils.GenerateEpaySign(params, payAppSecret)
		params["sign"] = sign
		params["sign_type"] = "MD5"

		query := url.Values{}
		for k, v := range params {
			query.Set(k, v)
		}
		payURL = strings.TrimRight(payApiURL, "/")
		if !strings.HasSuffix(payURL, ".php") {
			payURL += "/submit.php"
		}
		if strings.Contains(payURL, "?") {
			payURL += "&" + query.Encode()
		} else {
			payURL += "?" + query.Encode()
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"order":   order,
		"pay_url": payURL,
	})
}

// PayNotify 处理易支付异步回调通知
func (h *YunkaoPayHandler) PayNotify(c *gin.Context) {
	params := make(map[string]string)
	for k, v := range c.Request.URL.Query() {
		if len(v) > 0 && v[0] != "" {
			params[k] = v[0]
		}
	}
	if c.Request.Method == "POST" {
		c.Request.ParseForm()
		for k, v := range c.Request.PostForm {
			if _, exists := params[k]; !exists && len(v) > 0 && v[0] != "" {
				params[k] = v[0]
			}
		}
	}

	clientSign := params["sign"]
	delete(params, "sign")
	delete(params, "sign_type")

	cfg := h.resolvePayConfig()
	secret := cfg[models.YunkaoPayAppSecret]
	if s := os.Getenv("YUNKAO_PAY_APP_SECRET"); s != "" {
		secret = s
	}
	if secret == "" {
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	expectedSign := utils.GenerateEpaySign(params, secret)
	if clientSign == "" || subtle.ConstantTimeCompare([]byte(expectedSign), []byte(clientSign)) != 1 {
		c.String(http.StatusBadRequest, "fail")
		return
	}

	tradeStatus := params["trade_status"]
	if tradeStatus != "TRADE_SUCCESS" {
		c.String(http.StatusOK, "success")
		return
	}

	outTradeNo := params["out_trade_no"]
	tradeNo := params["trade_no"]
	moneyStr := params["money"]

	money, err := strconv.ParseFloat(moneyStr, 64)
	if err != nil {
		c.String(http.StatusBadRequest, "fail")
		return
	}

	var order models.YunkaoPayOrder
	if err := h.db.Where("order_no = ?", outTradeNo).First(&order).Error; err != nil {
		c.String(http.StatusNotFound, "fail")
		return
	}

	expectedCents := order.AmountCents
	paidCents := int(math.Round(money * 100))
	if expectedCents != paidCents {
		c.String(http.StatusBadRequest, "fail")
		return
	}

	if order.Status != "pending" {
		c.String(http.StatusOK, "success")
		return
	}

	// 事务：更新订单 + 加余额
	err = h.db.Transaction(func(tx *gorm.DB) error {
		now := time.Now()
		order.Status = "completed"
		order.TradeNo = tradeNo
		order.PaidAt = &now
		if err := tx.Save(&order).Error; err != nil {
			return err
		}

		// 给用户钱包加余额
		var wallet models.YunkaoWallet
		if err := tx.Where("user_id = ?", order.UserID).First(&wallet).Error; err != nil {
			wallet = models.YunkaoWallet{UserID: order.UserID, BalanceCents: 0}
			tx.Create(&wallet)
		}
		wallet.BalanceCents += order.AmountCents
		wallet.TotalRechargedCents += order.AmountCents
		if err := tx.Save(&wallet).Error; err != nil {
			return err
		}

		// 同时写入充值订单记录
		rechargeOrder := models.YunkaoRechargeOrder{
			UserID:      order.UserID,
			AmountCents: order.AmountCents,
			Type:        "online",
			Status:      "completed",
			Remark:      fmt.Sprintf("在线支付 %s, 交易号: %s", order.Gateway, tradeNo),
		}
		return tx.Create(&rechargeOrder).Error
	})

	if err != nil {
		log.Printf("[Yunkao Pay] 回调处理失败: order=%s err=%v", outTradeNo, err)
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	log.Printf("[Yunkao Pay] 支付成功: order=%s user=%d amount=%d", outTradeNo, order.UserID, order.AmountCents)
	c.String(http.StatusOK, "success")
}

// VmqNotify 处理 V免签 异步回调通知
func (h *YunkaoPayHandler) VmqNotify(c *gin.Context) {
	payId := c.Query("payId")
	param := c.Query("param")
	typ := c.Query("type")
	price := c.Query("price")
	reallyPrice := c.Query("reallyPrice")
	clientSign := c.Query("sign")

	log.Printf("[Yunkao Vmq] 收到回调: payId=%s price=%s reallyPrice=%s", payId, price, reallyPrice)

	cfg := h.resolvePayConfig()
	vmqSecret := cfg[models.YunkaoPayVmqSecret]
	if s := os.Getenv("YUNKAO_PAY_VMQ_SECRET"); s != "" {
		vmqSecret = s
	}

	expectedSign := utils.GenerateVmqSign(payId, param, typ, price, vmqSecret)
	if subtle.ConstantTimeCompare([]byte(expectedSign), []byte(clientSign)) != 1 {
		log.Printf("[Yunkao Vmq] 签名校验失败: expected=%s got=%s", expectedSign, clientSign)
		c.String(http.StatusForbidden, "fail")
		return
	}

	var order models.YunkaoPayOrder
	if err := h.db.Where("order_no = ?", payId).First(&order).Error; err != nil {
		log.Printf("[Yunkao Vmq] 订单未找到: %s", payId)
		c.String(http.StatusNotFound, "fail")
		return
	}

	priceFloat, _ := strconv.ParseFloat(price, 64)
	expectedCents := order.AmountCents
	callbackCents := int(math.Round(priceFloat * 100))
	if expectedCents != callbackCents {
		log.Printf("[Yunkao Vmq] 金额不匹配: order=%d callback=%d", expectedCents, callbackCents)
		c.String(http.StatusBadRequest, "fail")
		return
	}

	if order.Status != "pending" {
		c.String(http.StatusOK, "success")
		return
	}

	reallyFloat, _ := strconv.ParseFloat(reallyPrice, 64)

	err := h.db.Transaction(func(tx *gorm.DB) error {
		now := time.Now()
		order.Status = "completed"
		order.PaidAt = &now
		order.RealAmountCents = int(math.Round(reallyFloat * 100))
		if err := tx.Save(&order).Error; err != nil {
			return err
		}

		var wallet models.YunkaoWallet
		if err := tx.Where("user_id = ?", order.UserID).First(&wallet).Error; err != nil {
			wallet = models.YunkaoWallet{UserID: order.UserID, BalanceCents: 0}
			tx.Create(&wallet)
		}
		wallet.BalanceCents += order.AmountCents
		wallet.TotalRechargedCents += order.AmountCents
		if err := tx.Save(&wallet).Error; err != nil {
			return err
		}

		rechargeOrder := models.YunkaoRechargeOrder{
			UserID:      order.UserID,
			AmountCents: order.AmountCents,
			Type:        "online",
			Status:      "completed",
			Remark:      fmt.Sprintf("V免签支付, 实收: ¥%.2f", reallyFloat),
		}
		return tx.Create(&rechargeOrder).Error
	})

	if err != nil {
		log.Printf("[Yunkao Vmq] 回调处理失败: %v", err)
		c.String(http.StatusInternalServerError, "fail")
		return
	}

	log.Printf("[Yunkao Vmq] 支付成功: order=%s user=%d amount=%d", payId, order.UserID, order.AmountCents)
	c.String(http.StatusOK, "success")
}

// GetPayOrders 获取当前用户的支付订单列表
func (h *YunkaoPayHandler) GetPayOrders(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}

	var total int64
	h.db.Model(&models.YunkaoPayOrder{}).Where("user_id = ?", uid).Count(&total)

	var orders []models.YunkaoPayOrder
	h.db.Where("user_id = ?", uid).
		Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&orders)

	c.JSON(http.StatusOK, gin.H{
		"orders":    orders,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// AdminGetPayOrders 管理员查看所有支付订单
func (h *YunkaoPayHandler) AdminGetPayOrders(c *gin.Context) {
	status := c.DefaultQuery("status", "")
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	query := h.db.Model(&models.YunkaoPayOrder{})
	if status != "" {
		query = query.Where("status = ?", status)
	}

	var total int64
	query.Count(&total)

	var orders []models.YunkaoPayOrder
	query.Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&orders)

	c.JSON(http.StatusOK, gin.H{
		"orders":    orders,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// GetPayConfig 管理员获取支付配置（脱敏）
func (h *YunkaoPayHandler) GetPayConfig(c *gin.Context) {
	cfg := h.resolvePayConfig()
	c.JSON(http.StatusOK, gin.H{
		"gateway_type": cfg[models.YunkaoPayGatewayType],
		"enabled":      cfg[models.YunkaoPayEnabled],
		"min_amount":   cfg[models.YunkaoPayMinAmount],
		"app_id":       maskString(cfg[models.YunkaoPayAppID], 4),
		"api_url":      cfg[models.YunkaoPayApiURL],
	})
}

// UpdatePayConfig 管理员更新支付配置
func (h *YunkaoPayHandler) UpdatePayConfig(c *gin.Context) {
	var req map[string]string
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	keyMap := map[string]string{
		"gateway_type": models.YunkaoPayGatewayType,
		"app_id":       models.YunkaoPayAppID,
		"app_secret":   models.YunkaoPayAppSecret,
		"api_url":      models.YunkaoPayApiURL,
		"vmq_secret":   models.YunkaoPayVmqSecret,
		"vmq_api_url":  models.YunkaoPayVmqApiURL,
		"enabled":      models.YunkaoPayEnabled,
		"min_amount":   models.YunkaoPayMinAmount,
		"notify_base":  models.YunkaoPayNotifyBase,
	}

	for reqKey, configKey := range keyMap {
		if val, ok := req[reqKey]; ok {
			var cfg models.SystemConfig
			if err := h.db.Where("config_key = ?", configKey).First(&cfg).Error; err != nil {
				h.db.Create(&models.SystemConfig{
					ConfigKey:   configKey,
					ConfigValue: val,
					Description: "融智云考助手支付配置",
				})
			} else {
				cfg.ConfigValue = val
				h.db.Save(&cfg)
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{"success": true})
}

func maskString(s string, showLast int) string {
	if len(s) <= showLast {
		return s
	}
	return strings.Repeat("*", len(s)-showLast) + s[len(s)-showLast:]
}
